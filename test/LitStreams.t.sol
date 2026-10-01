// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LitStreams} from "../contracts/LitStreams.sol";
import {RejectingReceiver, ReentrantRecipient, ReentrantSender, RejectingSender} from "./utils/Mocks.sol";

abstract contract LitStreamsBase is Test {
    LitStreams internal streams;

    address internal sender = makeAddr("sender");
    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant T0 = 1_700_000_000;
    uint40 internal constant HOUR = 1 hours;

    function setUp() public virtual {
        vm.warp(T0);
        streams = new LitStreams();
        vm.deal(sender, 1_000_000 ether);
        vm.deal(stranger, 1 ether);
    }

    function _create(uint128 deposit, uint40 startTime, uint40 duration, bool cancelable)
        internal
        returns (uint256 id)
    {
        vm.prank(sender);
        id = streams.createStream{value: deposit}(recipient, startTime, duration, cancelable);
    }

    function _createNow(uint128 deposit, uint40 duration) internal returns (uint256) {
        return _create(deposit, 0, duration, true);
    }
}

contract LitStreamsUnitTest is LitStreamsBase {
    /*//////////////////////////////////////////////////////////////
                                CREATE
    //////////////////////////////////////////////////////////////*/

    function test_Create_StartNow() public {
        vm.expectEmit(true, true, true, true, address(streams));
        emit LitStreams.StreamCreated(1, sender, recipient, 1 ether, uint40(T0), uint40(T0) + HOUR, true);
        uint256 id = _create(1 ether, 0, HOUR, true);

        assertEq(id, 1);
        assertEq(streams.nextStreamId(), 2);
        assertEq(address(streams).balance, 1 ether);

        LitStreams.Stream memory s = streams.getStream(id);
        assertEq(s.sender, sender);
        assertEq(s.recipient, recipient);
        assertEq(s.startTime, T0);
        assertEq(s.endTime, T0 + HOUR);
        assertEq(s.deposit, 1 ether);
        assertEq(s.withdrawn, 0);
        assertEq(s.refunded, 0);
        assertTrue(s.cancelable);
        assertFalse(s.canceled);
        assertEq(uint8(streams.statusOf(id)), uint8(LitStreams.Status.Streaming));
    }

    function test_Create_Scheduled() public {
        uint40 start = uint40(T0 + 1 days);
        uint256 id = _create(1 ether, start, HOUR, false);
        LitStreams.Stream memory s = streams.getStream(id);
        assertEq(s.startTime, start);
        assertEq(s.endTime, start + HOUR);
        assertFalse(s.cancelable);
        assertEq(uint8(streams.statusOf(id)), uint8(LitStreams.Status.Pending));
    }

    function test_Create_StartExactlyNowAndAtMaxDelay() public {
        uint256 a = _create(1, uint40(T0), 60, true);
        assertEq(streams.getStream(a).startTime, T0);
        uint256 b = _create(1, uint40(T0) + streams.MAX_START_DELAY(), 60, true);
        assertEq(streams.getStream(b).startTime, T0 + 365 days);
    }

    function test_Create_DurationBounds() public {
        uint256 a = _create(1, 0, streams.MIN_DURATION(), true);
        assertEq(streams.getStream(a).endTime, T0 + 60);
        uint256 b = _create(1, 0, streams.MAX_DURATION(), true);
        assertEq(streams.getStream(b).endTime, T0 + 3650 days);
    }

    function test_Create_IdsIncrement() public {
        assertEq(_createNow(1, HOUR), 1);
        assertEq(_createNow(1, HOUR), 2);
        assertEq(_createNow(1, HOUR), 3);
        assertEq(streams.nextStreamId(), 4);
    }

    function test_RevertWhen_Create_ZeroRecipient() public {
        vm.prank(sender);
        vm.expectRevert(LitStreams.ZeroRecipient.selector);
        streams.createStream{value: 1}(address(0), 0, HOUR, true);
    }

    function test_RevertWhen_Create_SelfStream() public {
        vm.prank(sender);
        vm.expectRevert(LitStreams.SelfStream.selector);
        streams.createStream{value: 1}(sender, 0, HOUR, true);
    }

    function test_RevertWhen_Create_ContractRecipient() public {
        vm.prank(sender);
        vm.expectRevert(LitStreams.InvalidRecipient.selector);
        streams.createStream{value: 1}(address(streams), 0, HOUR, true);
    }

    function test_RevertWhen_Create_ZeroDeposit() public {
        vm.prank(sender);
        vm.expectRevert(LitStreams.ZeroDeposit.selector);
        streams.createStream{value: 0}(recipient, 0, HOUR, true);
    }

    function test_RevertWhen_Create_DepositTooLarge() public {
        uint256 tooMuch = uint256(type(uint128).max) + 1;
        vm.deal(sender, tooMuch);
        vm.prank(sender);
        vm.expectRevert(LitStreams.DepositTooLarge.selector);
        streams.createStream{value: tooMuch}(recipient, 0, HOUR, true);
    }

    function test_RevertWhen_Create_StartInPast() public {
        vm.prank(sender);
        vm.expectRevert(LitStreams.StartInPast.selector);
        streams.createStream{value: 1}(recipient, uint40(T0 - 1), HOUR, true);
    }

    function test_RevertWhen_Create_StartTooFar() public {
        uint40 tooFar = uint40(T0) + streams.MAX_START_DELAY() + 1;
        vm.prank(sender);
        vm.expectRevert(LitStreams.StartTooFar.selector);
        streams.createStream{value: 1}(recipient, tooFar, HOUR, true);
    }

    function test_RevertWhen_Create_DurationBelowMin() public {
        vm.startPrank(sender);
        vm.expectRevert(LitStreams.DurationOutOfRange.selector);
        streams.createStream{value: 1}(recipient, 0, 59, true);
        vm.expectRevert(LitStreams.DurationOutOfRange.selector);
        streams.createStream{value: 1}(recipient, 0, 0, true);
        vm.stopPrank();
    }

    function test_RevertWhen_Create_DurationAboveMax() public {
        uint40 tooLong = streams.MAX_DURATION() + 1;
        vm.prank(sender);
        vm.expectRevert(LitStreams.DurationOutOfRange.selector);
        streams.createStream{value: 1}(recipient, 0, tooLong, true);
    }

    /*//////////////////////////////////////////////////////////////
                                 MATH
    //////////////////////////////////////////////////////////////*/

    function test_Streamed_ZeroBeforeAndAtStart() public {
        uint40 start = uint40(T0 + 100);
        uint256 id = _create(1 ether, start, 1000, true);
        assertEq(streams.streamedAmountOf(id), 0);
        vm.warp(start - 1);
        assertEq(streams.streamedAmountOf(id), 0);
        vm.warp(start);
        assertEq(streams.streamedAmountOf(id), 0);
        assertEq(streams.withdrawableAmountOf(id), 0);
        assertEq(streams.refundableAmountOf(id), 1 ether);
    }

    function test_Streamed_ExactMidStream() public {
        uint256 id = _createNow(1 ether, 1000);
        vm.warp(T0 + 250);
        assertEq(streams.streamedAmountOf(id), 0.25 ether);
        assertEq(streams.withdrawableAmountOf(id), 0.25 ether);
        assertEq(streams.refundableAmountOf(id), 0.75 ether);
    }

    function test_Streamed_RoundsDownInFavorOfSender() public {
        uint256 id = _createNow(10, 60);
        vm.warp(T0 + 7); // 10 * 7 / 60 = 1.166..
        assertEq(streams.streamedAmountOf(id), 1);
        assertEq(streams.refundableAmountOf(id), 9);
        vm.warp(T0 + 59); // 10 * 59 / 60 = 9.83..
        assertEq(streams.streamedAmountOf(id), 9);
        assertEq(streams.refundableAmountOf(id), 1);
    }

    function test_Streamed_FullDepositAtAndAfterEnd() public {
        uint256 id = _createNow(1 ether, HOUR);
        vm.warp(T0 + HOUR);
        assertEq(streams.streamedAmountOf(id), 1 ether);
        assertEq(streams.refundableAmountOf(id), 0);
        vm.warp(T0 + 100 days);
        assertEq(streams.streamedAmountOf(id), 1 ether);
    }

    function test_Streamed_Monotonic() public {
        uint256 id = _createNow(7 ether + 13, 997);
        uint128 last;
        for (uint256 t = 0; t <= 1100; t += 7) {
            vm.warp(T0 + t);
            uint128 cur = streams.streamedAmountOf(id);
            assertGe(cur, last);
            last = cur;
        }
        assertEq(last, 7 ether + 13);
    }

    function test_Streamed_TinyDepositLongDuration() public {
        uint40 maxDur = streams.MAX_DURATION();
        uint256 id = _createNow(1, maxDur);
        vm.warp(T0 + maxDur - 1);
        assertEq(streams.streamedAmountOf(id), 0);
        assertEq(streams.refundableAmountOf(id), 1);
        vm.warp(T0 + maxDur);
        assertEq(streams.streamedAmountOf(id), 1);
    }

    function test_Streamed_HugeDeposit() public {
        uint128 dep = type(uint128).max;
        uint40 maxDur = streams.MAX_DURATION();
        vm.deal(sender, dep);
        uint256 id = _create(dep, 0, maxDur, true);
        vm.warp(T0 + maxDur / 2);
        assertEq(streams.streamedAmountOf(id), uint128((uint256(dep) * (maxDur / 2)) / maxDur));
        vm.warp(T0 + maxDur - 1);
        assertEq(streams.streamedAmountOf(id), uint128((uint256(dep) * (maxDur - 1)) / maxDur));
        vm.warp(T0 + maxDur);
        assertEq(streams.streamedAmountOf(id), dep);
        vm.prank(stranger);
        streams.withdrawMax(id);
        assertEq(recipient.balance, dep);
    }

    function test_Refundable_ZeroWhenNotCancelable() public {
        uint256 id = _create(1 ether, 0, HOUR, false);
        vm.warp(T0 + 10);
        assertEq(streams.refundableAmountOf(id), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function _withdrawAs(address caller) internal {
        uint256 id = _createNow(1 ether, 1000);
        vm.warp(T0 + 500);
        uint256 callerBefore = caller.balance;
        uint256 recipientBefore = recipient.balance;

        vm.expectEmit(true, true, false, true, address(streams));
        emit LitStreams.Withdrawn(id, recipient, caller, 0.3 ether);
        vm.prank(caller);
        streams.withdraw(id, 0.3 ether);

        assertEq(recipient.balance, recipientBefore + 0.3 ether);
        if (caller != recipient) assertEq(caller.balance, callerBefore);
        assertEq(streams.getStream(id).withdrawn, 0.3 ether);
        assertEq(streams.withdrawableAmountOf(id), 0.2 ether);
        assertEq(address(streams).balance, 0.7 ether);
    }

    function test_Withdraw_ByRecipient() public {
        _withdrawAs(recipient);
    }

    function test_Withdraw_BySender() public {
        _withdrawAs(sender);
    }

    function test_Withdraw_ByStranger() public {
        _withdrawAs(stranger);
    }

    function test_Withdraw_PartialThenMax() public {
        uint256 id = _createNow(1 ether, 1000);
        vm.warp(T0 + 400);
        vm.prank(recipient);
        streams.withdraw(id, 0.1 ether);
        vm.prank(stranger);
        uint128 paid = streams.withdrawMax(id);
        assertEq(paid, 0.3 ether);
        assertEq(recipient.balance, 0.4 ether);
        assertEq(streams.withdrawableAmountOf(id), 0);

        vm.warp(T0 + 1000);
        vm.prank(sender);
        paid = streams.withdrawMax(id);
        assertEq(paid, 0.6 ether);
        assertEq(recipient.balance, 1 ether);
        assertEq(address(streams).balance, 0);
        assertEq(uint8(streams.statusOf(id)), uint8(LitStreams.Status.Depleted));
    }

    function test_RevertWhen_Withdraw_OverWithdrawable() public {
        uint256 id = _createNow(1 ether, 1000);
        vm.warp(T0 + 500);
        vm.prank(recipient);
        vm.expectRevert(LitStreams.AmountExceedsWithdrawable.selector);
        streams.withdraw(id, 0.5 ether + 1);
    }

    function test_RevertWhen_Withdraw_ZeroAmount() public {
        uint256 id = _createNow(1 ether, 1000);
        vm.warp(T0 + 500);
        vm.prank(recipient);
        vm.expectRevert(LitStreams.ZeroAmount.selector);
        streams.withdraw(id, 0);
    }

    function test_RevertWhen_WithdrawMax_NothingAccrued() public {
        uint256 id = _create(1 ether, uint40(T0 + 100), 1000, true);
        vm.expectRevert(LitStreams.ZeroAmount.selector);
        streams.withdrawMax(id);

        vm.warp(T0 + 600);
        streams.withdrawMax(id);
        vm.expectRevert(LitStreams.ZeroAmount.selector);
        streams.withdrawMax(id);
    }

    function test_RevertWhen_StreamNotFound() public {
        _createNow(1 ether, HOUR);
        uint256[2] memory bad = [uint256(0), uint256(2)];
        for (uint256 i; i < 2; ++i) {
            uint256 id = bad[i];
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.withdraw(id, 1);
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.withdrawMax(id);
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.cancel(id);
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.renounce(id);
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.getStream(id);
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.statusOf(id);
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.streamedAmountOf(id);
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.withdrawableAmountOf(id);
            vm.expectRevert(LitStreams.StreamNotFound.selector);
            streams.refundableAmountOf(id);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                CANCEL
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_Cancel_NotSender() public {
        uint256 id = _createNow(1 ether, HOUR);
        vm.prank(recipient);
        vm.expectRevert(LitStreams.NotSender.selector);
        streams.cancel(id);
        vm.prank(stranger);
        vm.expectRevert(LitStreams.NotSender.selector);
        streams.cancel(id);
    }

    function test_RevertWhen_Cancel_NotCancelable() public {
        uint256 id = _create(1 ether, 0, HOUR, false);
        vm.prank(sender);
        vm.expectRevert(LitStreams.NotCancelable.selector);
        streams.cancel(id);
    }

    function test_RevertWhen_Cancel_AtOrAfterEnd() public {
        uint256 id = _createNow(1 ether, HOUR);
        vm.warp(T0 + HOUR);
        vm.prank(sender);
        vm.expectRevert(LitStreams.StreamEnded.selector);
        streams.cancel(id);
        vm.warp(T0 + 2 * HOUR);
        vm.prank(sender);
        vm.expectRevert(LitStreams.StreamEnded.selector);
        streams.cancel(id);
    }

    function test_RevertWhen_Cancel_Twice() public {
        uint256 id = _createNow(1 ether, HOUR);
        vm.startPrank(sender);
        streams.cancel(id);
        vm.expectRevert(LitStreams.AlreadyCanceled.selector);
        streams.cancel(id);
        vm.stopPrank();
    }

    function test_Cancel_BeforeStart_FullRefund() public {
        uint256 id = _create(1 ether, uint40(T0 + 600), HOUR, true);
        uint256 senderBefore = sender.balance;

        vm.expectEmit(true, true, true, true, address(streams));
        emit LitStreams.Canceled(id, sender, recipient, 1 ether, 0);
        vm.prank(sender);
        streams.cancel(id);

        assertEq(sender.balance, senderBefore + 1 ether);
        assertEq(address(streams).balance, 0);
        assertEq(streams.streamedAmountOf(id), 0);
        assertEq(streams.withdrawableAmountOf(id), 0);
        assertEq(streams.refundableAmountOf(id), 0);
        assertEq(uint8(streams.statusOf(id)), uint8(LitStreams.Status.Depleted));
        vm.expectRevert(LitStreams.ZeroAmount.selector);
        streams.withdrawMax(id);
    }

    function test_Cancel_MidStream() public {
        uint256 id = _createNow(1 ether, 1000);
        vm.warp(T0 + 300);
        uint256 senderBefore = sender.balance;

        vm.expectEmit(true, true, true, true, address(streams));
        emit LitStreams.Canceled(id, sender, recipient, 0.7 ether, 0.3 ether);
        vm.prank(sender);
        streams.cancel(id);

        assertEq(sender.balance, senderBefore + 0.7 ether);
        assertEq(recipient.balance, 0, "cancel must not push funds to the recipient");
        assertEq(address(streams).balance, 0.3 ether);
        LitStreams.Stream memory s = streams.getStream(id);
        assertEq(uint256(s.refunded) + streams.streamedAmountOf(id), s.deposit);
        assertTrue(s.canceled);
        assertEq(uint8(streams.statusOf(id)), uint8(LitStreams.Status.Canceled));

        // Streamed amount is frozen after cancel.
        vm.warp(T0 + 5000);
        assertEq(streams.streamedAmountOf(id), 0.3 ether);
        assertEq(streams.withdrawableAmountOf(id), 0.3 ether);

        vm.prank(recipient);
        streams.withdrawMax(id);
        assertEq(recipient.balance, 0.3 ether);
        assertEq(address(streams).balance, 0);
        assertEq(uint8(streams.statusOf(id)), uint8(LitStreams.Status.Depleted));
    }

    function test_Cancel_AfterPartialWithdraw() public {
        uint256 id = _createNow(1 ether, 1000);
        vm.warp(T0 + 200);
        vm.prank(recipient);
        streams.withdrawMax(id); // 0.2
        vm.warp(T0 + 500);
        vm.prank(sender);
        streams.cancel(id); // refund 0.5
        assertEq(streams.getStream(id).refunded, 0.5 ether);
        assertEq(streams.withdrawableAmountOf(id), 0.3 ether);
        vm.prank(stranger);
        streams.withdrawMax(id);
        assertEq(recipient.balance, 0.5 ether);
        assertEq(address(streams).balance, 0);
    }

    function test_Cancel_OneSecondBeforeEnd() public {
        uint256 id = _createNow(1000, 1000);
        vm.warp(T0 + 999);
        vm.prank(sender);
        streams.cancel(id);
        assertEq(streams.getStream(id).refunded, 1);
        assertEq(streams.withdrawableAmountOf(id), 999);
    }

    /*//////////////////////////////////////////////////////////////
                                RENOUNCE
    //////////////////////////////////////////////////////////////*/

    function test_Renounce() public {
        uint256 id = _createNow(1 ether, HOUR);
        vm.expectEmit(true, false, false, false, address(streams));
        emit LitStreams.Renounced(id);
        vm.prank(sender);
        streams.renounce(id);

        assertFalse(streams.getStream(id).cancelable);
        assertEq(streams.refundableAmountOf(id), 0);

        vm.prank(sender);
        vm.expectRevert(LitStreams.NotCancelable.selector);
        streams.cancel(id);
    }

    function test_RevertWhen_Renounce_NotSender() public {
        uint256 id = _createNow(1 ether, HOUR);
        vm.prank(recipient);
        vm.expectRevert(LitStreams.NotSender.selector);
        streams.renounce(id);
        vm.prank(stranger);
        vm.expectRevert(LitStreams.NotSender.selector);
        streams.renounce(id);
    }

    function test_RevertWhen_Renounce_Twice() public {
        uint256 id = _createNow(1 ether, HOUR);
        vm.startPrank(sender);
        streams.renounce(id);
        vm.expectRevert(LitStreams.NotCancelable.selector);
        streams.renounce(id);
        vm.stopPrank();
    }

    function test_RevertWhen_Renounce_NonCancelable() public {
        uint256 id = _create(1 ether, 0, HOUR, false);
        vm.prank(sender);
        vm.expectRevert(LitStreams.NotCancelable.selector);
        streams.renounce(id);
    }

    function test_RevertWhen_Renounce_Canceled() public {
        uint256 id = _createNow(1 ether, HOUR);
        vm.startPrank(sender);
        streams.cancel(id);
        vm.expectRevert(LitStreams.AlreadyCanceled.selector);
        streams.renounce(id);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 STATUS
    //////////////////////////////////////////////////////////////*/

    function _status(uint256 id) internal view returns (LitStreams.Status) {
        return streams.statusOf(id);
    }

    function test_Status_PendingStreamingSettledDepleted() public {
        uint256 id = _create(1 ether, uint40(T0 + 100), 1000, true);
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Pending));
        vm.warp(T0 + 100);
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Streaming));
        vm.warp(T0 + 600);
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Streaming));
        streams.withdrawMax(id);
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Streaming));
        vm.warp(T0 + 1100);
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Settled));
        streams.withdrawMax(id);
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Depleted));
    }

    function test_Status_CanceledThenDepleted() public {
        uint256 id = _createNow(1 ether, 1000);
        vm.warp(T0 + 500);
        vm.prank(sender);
        streams.cancel(id);
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Canceled));
        vm.warp(T0 + 2000); // stays Canceled, not Settled
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Canceled));
        streams.withdrawMax(id);
        assertEq(uint8(_status(id)), uint8(LitStreams.Status.Depleted));
    }

    /*//////////////////////////////////////////////////////////////
                               REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function _streamTo(address to, uint128 deposit, uint40 duration) internal returns (uint256 id) {
        vm.prank(sender);
        id = streams.createStream{value: deposit}(to, 0, duration, true);
    }

    function test_Reentrancy_RecipientCannotDoubleWithdraw() public {
        ReentrantRecipient attacker = new ReentrantRecipient(streams);
        uint256 id = _streamTo(address(attacker), 1 ether, 1000);
        vm.warp(T0 + 500);

        for (uint8 mode = 1; mode <= 2; ++mode) {
            attacker.arm(id, mode);
            uint256 before = address(attacker).balance;
            uint128 expected = streams.withdrawableAmountOf(id);
            streams.withdrawMax(id);
            assertTrue(attacker.reentryBlocked());
            assertEq(address(attacker).balance - before, expected);
            assertEq(streams.withdrawableAmountOf(id), 0);
            vm.warp(block.timestamp + 100);
        }
        assertEq(attacker.timesPaid(), 2);
        assertEq(address(streams).balance + address(attacker).balance, 1 ether);
    }

    function test_Reentrancy_RecipientCannotCancelDuringPayout() public {
        // The recipient is not the sender, so cancel would fail anyway; the guard must also hold.
        ReentrantRecipient attacker = new ReentrantRecipient(streams);
        uint256 id = _streamTo(address(attacker), 1 ether, 1000);
        vm.warp(T0 + 500);
        attacker.arm(id, 3);
        streams.withdrawMax(id);
        assertTrue(attacker.reentryBlocked());
        assertFalse(streams.getStream(id).canceled);
    }

    function test_Reentrancy_SenderCannotDoubleRefund() public {
        ReentrantSender attacker = new ReentrantSender{value: 10 ether}(streams);
        uint256 id = attacker.create(recipient, 1 ether, 1000);
        vm.warp(T0 + 400);

        attacker.arm(id, 1); // re-enter cancel
        uint256 before = address(attacker).balance;
        attacker.cancel(id);
        assertTrue(attacker.reentryBlocked());
        assertEq(attacker.timesRefunded(), 1);
        assertEq(address(attacker).balance - before, 0.6 ether);
        assertEq(address(streams).balance, 0.4 ether);
    }

    function test_Reentrancy_SenderCannotWithdrawDuringRefund() public {
        ReentrantSender attacker = new ReentrantSender{value: 10 ether}(streams);
        uint256 id = attacker.create(recipient, 1 ether, 1000);
        vm.warp(T0 + 400);

        attacker.arm(id, 2); // re-enter withdrawMax
        attacker.cancel(id);
        assertTrue(attacker.reentryBlocked());
        assertEq(recipient.balance, 0);
        assertEq(streams.withdrawableAmountOf(id), 0.4 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         REJECTING COUNTERPARTIES
    //////////////////////////////////////////////////////////////*/

    function test_RejectingRecipient_CannotBlockCancel() public {
        RejectingReceiver bad = new RejectingReceiver();
        uint256 id = _streamTo(address(bad), 1 ether, 1000);
        vm.warp(T0 + 250);

        uint256 senderBefore = sender.balance;
        vm.prank(sender);
        streams.cancel(id);
        assertEq(sender.balance, senderBefore + 0.75 ether);

        // The recipient's own withdrawal fails and changes nothing.
        vm.expectRevert(LitStreams.TransferFailed.selector);
        streams.withdrawMax(id);
        assertEq(streams.withdrawableAmountOf(id), 0.25 ether);
        assertEq(address(streams).balance, 0.25 ether);
    }

    function test_RejectingSender_CancelReverts() public {
        RejectingSender bad = new RejectingSender{value: 1 ether}(streams);
        uint256 id = bad.create(recipient, 1 ether, 1000);
        vm.warp(T0 + 100);
        vm.expectRevert(LitStreams.TransferFailed.selector);
        bad.cancel(id);
        assertFalse(streams.getStream(id).canceled);
        // The recipient is unaffected.
        streams.withdrawMax(id);
        assertEq(recipient.balance, 0.1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            DIRECT TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_DirectTransfer() public {
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(streams).call{value: 1}("");
        assertFalse(ok);
        assertEq(bytes4(ret), LitStreams.DirectTransferNotAllowed.selector);

        vm.prank(stranger);
        (ok, ret) = address(streams).call{value: 1}(hex"deadbeef");
        assertFalse(ok);
        assertEq(bytes4(ret), LitStreams.DirectTransferNotAllowed.selector);

        assertEq(address(streams).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               PAGINATION
    //////////////////////////////////////////////////////////////*/

    function test_Pagination() public {
        address other = makeAddr("other");
        for (uint256 i; i < 5; ++i) {
            _createNow(1, HOUR); // ids 1..5 -> recipient
        }
        vm.prank(sender);
        streams.createStream{value: 1}(other, 0, HOUR, true); // id 6 -> other
        vm.deal(other, 1);
        vm.prank(other);
        streams.createStream{value: 1}(recipient, 0, HOUR, true); // id 7 -> recipient

        assertEq(streams.sentCount(sender), 6);
        assertEq(streams.sentCount(other), 1);
        assertEq(streams.receivedCount(recipient), 6);
        assertEq(streams.receivedCount(other), 1);
        assertEq(streams.sentCount(stranger), 0);

        uint256[] memory page = streams.sentIds(sender, 0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], 1);
        assertEq(page[1], 2);

        page = streams.sentIds(sender, 4, 10); // clipped
        assertEq(page.length, 2);
        assertEq(page[0], 5);
        assertEq(page[1], 6);

        page = streams.sentIds(sender, 0, type(uint256).max); // no overflow
        assertEq(page.length, 6);
        assertEq(page[5], 6);

        assertEq(streams.sentIds(sender, 6, 1).length, 0); // offset == length
        assertEq(streams.sentIds(sender, 100, 5).length, 0); // far out of range
        assertEq(streams.sentIds(sender, 0, 0).length, 0); // zero limit
        assertEq(streams.sentIds(stranger, 0, 10).length, 0); // nobody

        page = streams.receivedIds(recipient, 3, 3);
        assertEq(page.length, 3);
        assertEq(page[0], 4);
        assertEq(page[1], 5);
        assertEq(page[2], 7);

        page = streams.receivedIds(other, 0, 10);
        assertEq(page.length, 1);
        assertEq(page[0], 6);
        assertEq(streams.receivedIds(other, 1, 10).length, 0);
    }
}

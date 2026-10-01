// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LitStreams} from "../contracts/LitStreams.sol";
import {LitStreamsBase} from "./LitStreams.t.sol";

contract LitStreamsFuzzTest is LitStreamsBase {
    uint128 internal constant MAX_DEPOSIT = type(uint128).max;

    function setUp() public override {
        super.setUp();
        vm.deal(sender, type(uint256).max / 2);
    }

    function _bounded(uint128 deposit, uint40 startDelay, uint40 duration)
        internal
        view
        returns (uint128, uint40, uint40)
    {
        deposit = uint128(bound(deposit, 1, MAX_DEPOSIT));
        startDelay = uint40(bound(startDelay, 0, streams.MAX_START_DELAY()));
        duration = uint40(bound(duration, streams.MIN_DURATION(), streams.MAX_DURATION()));
        return (deposit, startDelay, duration);
    }

    function _expectedStreamed(LitStreams.Stream memory s, uint256 t) internal pure returns (uint256) {
        if (t <= s.startTime) return 0;
        if (t >= s.endTime) return s.deposit;
        return (uint256(s.deposit) * (t - s.startTime)) / (s.endTime - s.startTime);
    }

    /// Create stores exactly what was asked for, for any valid input.
    function testFuzz_Create(uint128 deposit, uint40 startDelay, uint40 duration, bool cancelable, bool startNow)
        public
    {
        (deposit, startDelay, duration) = _bounded(deposit, startDelay, duration);
        uint40 start = startNow ? 0 : uint40(T0) + startDelay;
        uint256 id = _create(deposit, start, duration, cancelable);

        LitStreams.Stream memory s = streams.getStream(id);
        uint40 expectedStart = startNow ? uint40(T0) : start;
        assertEq(s.startTime, expectedStart);
        assertEq(s.endTime, expectedStart + duration);
        assertEq(s.deposit, deposit);
        assertEq(s.cancelable, cancelable);
        assertEq(address(streams).balance, deposit);
    }

    /// Streamed amount matches the formula, never exceeds the deposit, and never decreases.
    function testFuzz_StreamedMath(uint128 deposit, uint40 startDelay, uint40 duration, uint256 t1, uint256 t2)
        public
    {
        (deposit, startDelay, duration) = _bounded(deposit, startDelay, duration);
        uint256 id = _create(deposit, uint40(T0) + startDelay, duration, true);
        LitStreams.Stream memory s = streams.getStream(id);

        t1 = bound(t1, T0, uint256(s.endTime) + 10 days);
        t2 = bound(t2, t1, uint256(s.endTime) + 20 days);

        vm.warp(t1);
        uint128 a = streams.streamedAmountOf(id);
        assertEq(a, _expectedStreamed(s, t1));
        assertLe(a, deposit);
        assertEq(uint256(a) + streams.refundableAmountOf(id), t1 < s.endTime ? deposit : a);

        vm.warp(t2);
        uint128 b = streams.streamedAmountOf(id);
        assertEq(b, _expectedStreamed(s, t2));
        assertGe(b, a);
    }

    /// Anyone can withdraw; funds land at the recipient and the caller's balance does not change.
    function testFuzz_WithdrawByAnyone(address caller, uint128 deposit, uint40 duration, uint256 elapsed, uint128 amount)
        public
    {
        vm.assume(caller != recipient && caller != address(streams));
        assumeNotPrecompile(caller);
        assumeNotForgeAddress(caller);
        (deposit,, duration) = _bounded(deposit, 0, duration);
        uint256 id = _createNow(deposit, duration);
        vm.warp(T0 + bound(elapsed, 1, uint256(duration) * 2));

        uint128 available = streams.withdrawableAmountOf(id);
        vm.assume(available > 0);
        amount = uint128(bound(amount, 1, available));

        uint256 callerBefore = caller.balance;
        vm.prank(caller);
        streams.withdraw(id, amount);

        assertEq(recipient.balance, amount);
        assertEq(caller.balance, callerBefore);
        assertEq(streams.withdrawableAmountOf(id), available - amount);
        assertEq(address(streams).balance, uint256(deposit) - amount);
    }

    /// Over-withdrawing always reverts.
    function testFuzz_RevertWhen_OverWithdraw(uint128 deposit, uint40 duration, uint256 elapsed, uint128 extra)
        public
    {
        (deposit,, duration) = _bounded(deposit, 0, duration);
        uint256 id = _createNow(deposit, duration);
        vm.warp(T0 + bound(elapsed, 0, uint256(duration) * 2));
        uint128 available = streams.withdrawableAmountOf(id);
        vm.assume(available < type(uint128).max);
        extra = uint128(bound(extra, 1, type(uint128).max - available));
        vm.expectRevert(LitStreams.AmountExceedsWithdrawable.selector);
        streams.withdraw(id, available + extra);
    }

    /// A random sequence of warps and withdrawals pays out exactly the deposit after the end.
    function testFuzz_WithdrawSequence(uint128 deposit, uint40 duration, uint32[8] memory steps, uint128[8] memory amounts)
        public
    {
        (deposit,, duration) = _bounded(deposit, 0, duration);
        uint256 id = _createNow(deposit, duration);
        uint256 paid;

        for (uint256 i; i < steps.length; ++i) {
            vm.warp(block.timestamp + bound(steps[i], 0, duration / 4 + 1));
            uint128 available = streams.withdrawableAmountOf(id);
            assertEq(uint256(available) + paid, streams.streamedAmountOf(id));
            if (available == 0) continue;
            uint128 amt = uint128(bound(amounts[i], 1, available));
            streams.withdraw(id, amt);
            paid += amt;
            assertEq(recipient.balance, paid);
        }

        vm.warp(T0 + duration);
        uint128 rest = streams.withdrawableAmountOf(id);
        if (rest > 0) streams.withdrawMax(id);
        assertEq(recipient.balance, deposit);
        assertEq(address(streams).balance, 0);
        assertEq(uint8(streams.statusOf(id)), uint8(LitStreams.Status.Depleted));
    }

    /// Cancel at any time before the end splits the deposit exactly, with or without prior withdrawals.
    function testFuzz_Cancel(
        uint128 deposit,
        uint40 startDelay,
        uint40 duration,
        uint256 withdrawAt,
        uint256 cancelAt,
        bool withdrawFirst
    ) public {
        (deposit, startDelay, duration) = _bounded(deposit, startDelay, duration);
        uint256 id = _create(deposit, uint40(T0) + startDelay, duration, true);
        LitStreams.Stream memory s = streams.getStream(id);

        cancelAt = bound(cancelAt, T0, uint256(s.endTime) - 1);
        withdrawAt = bound(withdrawAt, T0, cancelAt);

        uint256 paidBefore;
        if (withdrawFirst) {
            vm.warp(withdrawAt);
            uint128 w = streams.withdrawableAmountOf(id);
            if (w > 0) {
                streams.withdrawMax(id);
                paidBefore = w;
            }
        }

        vm.warp(cancelAt);
        uint256 expectedStreamed = _expectedStreamed(s, cancelAt);
        uint256 expectedRefund = deposit - expectedStreamed;
        assertEq(streams.refundableAmountOf(id), expectedRefund);

        uint256 senderBefore = sender.balance;
        vm.prank(sender);
        streams.cancel(id);

        assertGt(expectedRefund, 0);
        assertEq(sender.balance - senderBefore, expectedRefund);
        assertEq(streams.streamedAmountOf(id), expectedStreamed);
        assertEq(streams.withdrawableAmountOf(id), expectedStreamed - paidBefore);

        // Time passing does not change a canceled stream.
        vm.warp(uint256(s.endTime) + 1 days);
        assertEq(streams.streamedAmountOf(id), expectedStreamed);
        assertEq(streams.refundableAmountOf(id), 0);

        if (expectedStreamed > paidBefore) streams.withdrawMax(id);
        assertEq(recipient.balance, expectedStreamed);
        assertEq(recipient.balance + (sender.balance - senderBefore), deposit);
        assertEq(address(streams).balance, 0);
        assertEq(uint8(streams.statusOf(id)), uint8(LitStreams.Status.Depleted));
    }

    /// Only the sender can cancel or renounce.
    function testFuzz_RevertWhen_NotSender(address caller) public {
        vm.assume(caller != sender);
        uint256 id = _createNow(1 ether, HOUR);
        vm.startPrank(caller);
        vm.expectRevert(LitStreams.NotSender.selector);
        streams.cancel(id);
        vm.expectRevert(LitStreams.NotSender.selector);
        streams.renounce(id);
        vm.stopPrank();
    }

    /// Invalid start times and durations always revert.
    function testFuzz_RevertWhen_BadSchedule(uint40 pastStart, uint40 farStart, uint40 badDuration) public {
        pastStart = uint40(bound(pastStart, 1, T0 - 1));
        vm.prank(sender);
        vm.expectRevert(LitStreams.StartInPast.selector);
        streams.createStream{value: 1}(recipient, pastStart, HOUR, true);

        farStart = uint40(bound(farStart, T0 + streams.MAX_START_DELAY() + 1, type(uint40).max));
        vm.prank(sender);
        vm.expectRevert(LitStreams.StartTooFar.selector);
        streams.createStream{value: 1}(recipient, farStart, HOUR, true);

        vm.assume(badDuration < streams.MIN_DURATION() || badDuration > streams.MAX_DURATION());
        vm.prank(sender);
        vm.expectRevert(LitStreams.DurationOutOfRange.selector);
        streams.createStream{value: 1}(recipient, 0, badDuration, true);
    }
}

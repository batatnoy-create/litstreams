// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LitStreams} from "../contracts/LitStreams.sol";

/// @dev Drives LitStreams with random but valid actions and tracks ghost totals.
///      Every action filters its own preconditions, so with `fail_on_revert = true` any revert from the
///      contract fails the suite. Withdraw and cancel pick a stream where the action has an effect, so
///      few calls are no-ops.
contract Handler is Test {
    LitStreams public immutable streams;

    address[] internal senders;
    address[] internal recipients;
    address internal helper;

    uint256[] public ids;
    mapping(uint256 => uint128) public lastStreamed;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostRefunded; // measured: what actually arrived at the senders
    uint256 public ghostExpectedRefunded; // computed from the formula, independently of the contract
    uint256 public ghostForceSent;
    bool public monotonicViolated;

    uint256 internal constant MAX_STREAMS = 40;

    constructor(LitStreams streams_) {
        streams = streams_;
        for (uint256 i; i < 3; ++i) {
            senders.push(makeAddr(string.concat("sender", vm.toString(i))));
            recipients.push(makeAddr(string.concat("recipient", vm.toString(i))));
        }
        helper = makeAddr("helper");
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function senderCount() external view returns (uint256) {
        return senders.length;
    }

    function senderAt(uint256 i) external view returns (address) {
        return senders[i];
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function recipientAt(uint256 i) external view returns (address) {
        return recipients[i];
    }

    /// @dev Streamed amount of a non-canceled stream at the current time, from the stored schedule only.
    function expectedStreamed(LitStreams.Stream memory s) public view returns (uint256) {
        if (block.timestamp <= s.startTime) return 0;
        if (block.timestamp >= s.endTime) return s.deposit;
        return (uint256(s.deposit) * (block.timestamp - s.startTime)) / (s.endTime - s.startTime);
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    function createStream(
        uint256 senderSeed,
        uint256 recipientSeed,
        uint128 deposit,
        uint40 startDelay,
        uint40 duration,
        bool cancelable,
        bool startNow
    ) external checkMonotonic {
        if (ids.length >= MAX_STREAMS) return;
        address from = senders[senderSeed % senders.length];
        address to = recipients[recipientSeed % recipients.length];
        deposit = uint128(bound(deposit, 1, 1_000 ether));
        duration = uint40(bound(duration, streams.MIN_DURATION(), 30 days));
        uint40 start = startNow ? 0 : uint40(block.timestamp + bound(startDelay, 0, 7 days));

        vm.deal(from, from.balance + deposit);
        vm.prank(from);
        uint256 id = streams.createStream{value: deposit}(to, start, duration, cancelable);
        ids.push(id);
        ghostDeposited += deposit;
    }

    function withdraw(uint256 idSeed, uint256 callerSeed, uint128 amount) external checkMonotonic {
        (uint256 id, uint128 available) = _pickWithdrawable(idSeed);
        if (available == 0) return;
        amount = uint128(bound(amount, 1, available));
        vm.prank(_anyCaller(callerSeed, id));
        streams.withdraw(id, amount);
        ghostWithdrawn += amount;
    }

    function withdrawMax(uint256 idSeed, uint256 callerSeed) external checkMonotonic {
        (uint256 id, uint128 available) = _pickWithdrawable(idSeed);
        if (available == 0) return;
        vm.prank(_anyCaller(callerSeed, id));
        ghostWithdrawn += streams.withdrawMax(id);
    }

    /// Cancels the first still-cancelable stream from a random index. With `warpIntoStream`, it first
    /// moves time to a random point before the stream's end, so mid-stream cancels are common.
    function cancel(uint256 idSeed, uint256 warpSeed, bool warpIntoStream) external checkMonotonic {
        uint256 n = ids.length;
        for (uint256 k; k < n; ++k) {
            uint256 id = ids[(idSeed % n + k) % n];
            LitStreams.Stream memory s = streams.getStream(id);
            uint256 nowTs = vm.getBlockTimestamp();
            if (!s.cancelable || s.canceled || nowTs >= s.endTime) continue;

            if (warpIntoStream) {
                uint256 from = nowTs > s.startTime ? nowTs : s.startTime;
                vm.warp(bound(warpSeed, from, uint256(s.endTime) - 1));
            }

            uint256 expectedRefund = s.deposit - expectedStreamed(s);
            uint256 before = s.sender.balance;
            vm.prank(s.sender);
            streams.cancel(id);
            ghostRefunded += s.sender.balance - before;
            ghostExpectedRefunded += expectedRefund;
            return;
        }
    }

    function renounce(uint256 idSeed) external checkMonotonic {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        LitStreams.Stream memory s = streams.getStream(id);
        if (!s.cancelable || s.canceled) return;
        vm.prank(s.sender);
        streams.renounce(id);
    }

    function warp(uint256 secs) external checkMonotonic {
        vm.warp(block.timestamp + bound(secs, 0, 5 days));
    }

    /// Simulates zkLTC force-sent to the contract (selfdestruct, bridge credit).
    function forceSend(uint96 amount) external checkMonotonic {
        amount = uint96(bound(amount, 1, 10 ether));
        vm.deal(address(streams), address(streams).balance + amount);
        ghostForceSent += amount;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev First stream with something to withdraw, scanning from a random index. (0, 0) if none.
    function _pickWithdrawable(uint256 seed) internal view returns (uint256, uint128) {
        uint256 n = ids.length;
        for (uint256 k; k < n; ++k) {
            uint256 id = ids[(seed % n + k) % n];
            uint128 available = streams.withdrawableAmountOf(id);
            if (available > 0) return (id, available);
        }
        return (0, 0);
    }

    function _anyCaller(uint256 seed, uint256 id) internal view returns (address) {
        uint256 pick = seed % 3;
        if (pick == 0) return streams.getStream(id).recipient;
        if (pick == 1) return streams.getStream(id).sender;
        return helper;
    }

    /// After every action: no stream's streamed amount may go down.
    modifier checkMonotonic() {
        _;
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint128 cur = streams.streamedAmountOf(id);
            if (cur < lastStreamed[id]) monotonicViolated = true;
            lastStreamed[id] = cur;
        }
    }
}

contract LitStreamsInvariantTest is Test {
    LitStreams internal streams;
    Handler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        streams = new LitStreams();
        handler = new Handler(streams);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = Handler.createStream.selector;
        selectors[1] = Handler.withdraw.selector;
        selectors[2] = Handler.withdrawMax.selector;
        selectors[3] = Handler.cancel.selector;
        selectors[4] = Handler.renounce.selector;
        selectors[5] = Handler.warp.selector;
        selectors[6] = Handler.forceSend.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _outstanding() internal view returns (uint256 total) {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            LitStreams.Stream memory s = streams.getStream(handler.ids(i));
            total += uint256(s.deposit) - s.withdrawn - s.refunded;
        }
    }

    /// The contract always holds at least what it owes (>= because of force-sent funds).
    function invariant_Solvency() public view {
        assertGe(address(streams).balance, _outstanding());
    }

    /// Exact accounting: balance = what is owed + what was force-sent.
    function invariant_ExactBalance() public view {
        assertEq(address(streams).balance, _outstanding() + handler.ghostForceSent());
        assertEq(
            handler.ghostDeposited(),
            handler.ghostWithdrawn() + handler.ghostRefunded() + _outstanding()
        );
    }

    /// Per stream: withdrawn + refunded <= deposit, and withdrawn <= streamed.
    function invariant_PerStreamBounds() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            LitStreams.Stream memory s = streams.getStream(id);
            assertLe(uint256(s.withdrawn) + s.refunded, s.deposit);
            assertLe(s.withdrawn, streams.streamedAmountOf(id));
            if (s.canceled) assertEq(streams.streamedAmountOf(id), s.deposit - s.refunded);
            else assertEq(s.refunded, 0);
        }
    }

    /// Streamed amounts never decrease as time advances.
    function invariant_StreamedMonotonic() public view {
        assertFalse(handler.monotonicViolated());
    }

    /// The contract's streamed amount matches the formula recomputed from each stream's stored schedule.
    function invariant_StreamedMatchesFormula() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            LitStreams.Stream memory s = streams.getStream(id);
            if (s.canceled) continue;
            assertEq(streams.streamedAmountOf(id), handler.expectedStreamed(s));
        }
    }

    /// Recipients only ever receive what was withdrawn for them.
    function invariant_RecipientsGetWithdrawals() public view {
        uint256 total;
        uint256 n = handler.recipientCount();
        for (uint256 i; i < n; ++i) {
            total += handler.recipientAt(i).balance;
        }
        assertEq(total, handler.ghostWithdrawn());
    }

    /// Refunds arrive at the senders, and equal the refunds computed independently from the formula.
    function invariant_RefundsReachSenders() public view {
        uint256 total;
        uint256 n = handler.senderCount();
        for (uint256 i; i < n; ++i) {
            total += handler.senderAt(i).balance;
        }
        assertEq(total, handler.ghostRefunded());
        assertEq(handler.ghostRefunded(), handler.ghostExpectedRefunded());
    }

    /// Every created stream got a sequential id.
    function invariant_IdsSequential() public view {
        assertEq(streams.nextStreamId(), handler.idCount() + 1);
    }
}

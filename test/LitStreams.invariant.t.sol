// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LitStreams} from "../contracts/LitStreams.sol";

/// @dev Drives LitStreams with random but valid actions and tracks ghost totals.
contract Handler is Test {
    LitStreams public immutable streams;

    address[] internal senders;
    address[] internal recipients;
    address internal helper;

    uint256[] public ids;
    mapping(uint256 => uint128) public lastStreamed;

    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostRefunded;
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

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function recipientAt(uint256 i) external view returns (address) {
        return recipients[i];
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
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        uint128 available = streams.withdrawableAmountOf(id);
        if (available == 0) return;
        amount = uint128(bound(amount, 1, available));
        vm.prank(_anyCaller(callerSeed, id));
        streams.withdraw(id, amount);
        ghostWithdrawn += amount;
    }

    function withdrawMax(uint256 idSeed, uint256 callerSeed) external checkMonotonic {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        if (streams.withdrawableAmountOf(id) == 0) return;
        vm.prank(_anyCaller(callerSeed, id));
        ghostWithdrawn += streams.withdrawMax(id);
    }

    function cancel(uint256 idSeed) external checkMonotonic {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        LitStreams.Stream memory s = streams.getStream(id);
        if (!s.cancelable || s.canceled || block.timestamp >= s.endTime) return;
        uint128 refund = streams.refundableAmountOf(id);
        vm.prank(s.sender);
        streams.cancel(id);
        ghostRefunded += refund;
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

    /// Recipients only ever receive what was withdrawn for them.
    function invariant_RecipientsGetWithdrawals() public view {
        uint256 total;
        uint256 n = handler.recipientCount();
        for (uint256 i; i < n; ++i) {
            total += handler.recipientAt(i).balance;
        }
        assertEq(total, handler.ghostWithdrawn());
    }

    /// Every created stream got a sequential id.
    function invariant_IdsSequential() public view {
        assertEq(streams.nextStreamId(), handler.idCount() + 1);
    }
}

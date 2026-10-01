// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LitStreams} from "../../contracts/LitStreams.sol";

/// @dev A recipient that rejects every zkLTC transfer.
contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev A counterparty (sender or recipient) that runs one scripted call back into LitStreams while it is
///      being paid. It records how that call ended (success, or the revert selector) and snapshots a stream
///      as seen from inside the payment, so tests can check both the guard and checks-effects-interactions.
contract ReentrantActor {
    enum Action {
        None,
        WithdrawMax,
        WithdrawOneWei,
        Cancel,
        Renounce,
        CreateStream
    }

    LitStreams public immutable streams;

    Action public action;
    uint256 public targetId; // stream the reentrant call acts on
    address public createRecipient; // recipient for Action.CreateStream
    uint256 public observeId; // stream snapshotted during the payment (0 = none)

    uint256 public timesPaid;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes4 public reentryError;
    uint256 public createdId;

    LitStreams.Stream internal _seen;
    uint128 public seenWithdrawable;

    constructor(LitStreams streams_) payable {
        streams = streams_;
    }

    function create(address recipient, uint128 amount, uint40 duration) external returns (uint256 id) {
        id = streams.createStream{value: amount}(recipient, 0, duration, true);
    }

    function cancel(uint256 id) external {
        streams.cancel(id);
    }

    /// @dev Arms one reentrant call for the next payment this contract receives.
    function arm(Action action_, uint256 targetId_) external {
        action = action_;
        targetId = targetId_;
    }

    function armCreate(address recipient) external {
        action = Action.CreateStream;
        createRecipient = recipient;
    }

    function observe(uint256 id) external {
        observeId = id;
    }

    function seen() external view returns (LitStreams.Stream memory) {
        return _seen;
    }

    receive() external payable {
        timesPaid++;
        if (observeId != 0) {
            _seen = streams.getStream(observeId);
            seenWithdrawable = streams.withdrawableAmountOf(observeId);
        }

        Action a = action;
        if (a == Action.None) return;
        action = Action.None; // only once

        bytes memory data;
        uint256 value;
        if (a == Action.WithdrawMax) {
            data = abi.encodeCall(LitStreams.withdrawMax, (targetId));
        } else if (a == Action.WithdrawOneWei) {
            data = abi.encodeCall(LitStreams.withdraw, (targetId, 1));
        } else if (a == Action.Cancel) {
            data = abi.encodeCall(LitStreams.cancel, (targetId));
        } else if (a == Action.Renounce) {
            data = abi.encodeCall(LitStreams.renounce, (targetId));
        } else {
            // Re-stream the payment just received.
            data = abi.encodeCall(LitStreams.createStream, (createRecipient, 0, 60, true));
            value = msg.value;
        }

        reentryAttempted = true;
        (bool ok, bytes memory ret) = address(streams).call{value: value}(data);
        reentrySucceeded = ok;
        if (ok) {
            if (a == Action.CreateStream) createdId = abi.decode(ret, (uint256));
        } else {
            reentryError = bytes4(ret);
        }
    }
}

/// @dev A sender contract that cannot receive its refund.
contract RejectingSender {
    LitStreams public immutable streams;

    constructor(LitStreams streams_) payable {
        streams = streams_;
    }

    function create(address recipient, uint128 amount, uint40 duration) external returns (uint256 id) {
        id = streams.createStream{value: amount}(recipient, 0, duration, true);
    }

    function cancel(uint256 id) external {
        streams.cancel(id);
    }

    receive() external payable {
        revert("no refunds");
    }
}

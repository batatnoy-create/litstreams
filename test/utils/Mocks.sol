// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LitStreams} from "../../contracts/LitStreams.sol";

/// @dev A recipient that rejects every zkLTC transfer.
contract RejectingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev A recipient that tries to re-enter LitStreams while being paid.
///      It swallows the reentrant revert, so the outer call can still succeed and we can check
///      that the second payout never happened.
contract ReentrantRecipient {
    LitStreams public immutable streams;
    uint256 public targetId;
    uint8 public mode; // 0 = off, 1 = withdrawMax, 2 = withdraw(1 wei), 3 = cancel
    bool public reentryBlocked;
    uint256 public timesPaid;

    constructor(LitStreams streams_) {
        streams = streams_;
    }

    function arm(uint256 id, uint8 mode_) external {
        targetId = id;
        mode = mode_;
    }

    receive() external payable {
        timesPaid++;
        uint8 m = mode;
        if (m == 0) return;
        mode = 0; // try only once
        if (m == 1) {
            try streams.withdrawMax(targetId) {} catch { reentryBlocked = true; }
        } else if (m == 2) {
            try streams.withdraw(targetId, 1) {} catch { reentryBlocked = true; }
        } else if (m == 3) {
            try streams.cancel(targetId) {} catch { reentryBlocked = true; }
        }
    }
}

/// @dev A sender contract that tries to re-enter LitStreams while receiving its cancel refund.
contract ReentrantSender {
    LitStreams public immutable streams;
    uint256 public targetId;
    uint8 public mode; // 0 = off, 1 = cancel again, 2 = withdrawMax
    bool public reentryBlocked;
    uint256 public timesRefunded;

    constructor(LitStreams streams_) payable {
        streams = streams_;
    }

    function create(address recipient, uint128 amount, uint40 duration) external returns (uint256 id) {
        id = streams.createStream{value: amount}(recipient, 0, duration, true);
    }

    function cancel(uint256 id) external {
        streams.cancel(id);
    }

    function arm(uint256 id, uint8 mode_) external {
        targetId = id;
        mode = mode_;
    }

    receive() external payable {
        timesRefunded++;
        uint8 m = mode;
        if (m == 0) return;
        mode = 0;
        if (m == 1) {
            try streams.cancel(targetId) {} catch { reentryBlocked = true; }
        } else if (m == 2) {
            try streams.withdrawMax(targetId) {} catch { reentryBlocked = true; }
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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LitStreams
/// @notice Per-second payment streaming of native zkLTC on LitVM.
/// @dev A sender locks native zkLTC for one recipient. The streamed amount grows linearly from 0 at
///      `startTime` to the full deposit at `endTime`. Anyone can trigger a withdrawal, but funds always go
///      to the recipient. Cancelable streams can be canceled by the sender before they end: the unstreamed
///      part is refunded to the sender and the streamed part stays withdrawable by the recipient.
///      No owner, no admin, no fees, no upgrades. Testnet only, unaudited.
///      Time is read from `block.timestamp` only; `block.number` is never used (it is approximate on LitVM).
contract LitStreams is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Lifecycle status of a stream, as returned by {statusOf}.
    enum Status {
        Pending, // now < startTime
        Streaming, // startTime <= now < endTime, not canceled
        Settled, // now >= endTime, not canceled, not fully withdrawn
        Canceled, // canceled, recipient has not withdrawn everything yet
        Depleted // withdrawn + refunded == deposit
    }

    /// @notice A single stream. Packed into four storage slots.
    struct Stream {
        address sender; // slot 0
        uint40 startTime;
        uint40 endTime;
        bool cancelable;
        bool canceled;
        address recipient; // slot 1
        uint128 deposit; // slot 2
        uint128 withdrawn;
        uint128 refunded; // slot 3
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Shortest allowed stream duration.
    uint40 public constant MIN_DURATION = 60 seconds;
    /// @notice Longest allowed stream duration.
    uint40 public constant MAX_DURATION = 3650 days;
    /// @notice How far in the future a scheduled start may be.
    uint40 public constant MAX_START_DELAY = 365 days;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => Stream) private _streams;
    mapping(address => uint256[]) private _sentIds; // append-only
    mapping(address => uint256[]) private _receivedIds; // append-only

    /// @notice Id that the next created stream will get. Ids start at 1; 0 never exists.
    uint256 public nextStreamId = 1;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a stream is created.
    event StreamCreated(
        uint256 indexed id,
        address indexed sender,
        address indexed recipient,
        uint128 deposit,
        uint40 startTime,
        uint40 endTime,
        bool cancelable
    );

    /// @notice Emitted when streamed funds are paid out to the recipient.
    event Withdrawn(uint256 indexed id, address indexed recipient, address caller, uint128 amount);

    /// @notice Emitted when the sender cancels a stream.
    event Canceled(
        uint256 indexed id,
        address indexed sender,
        address indexed recipient,
        uint128 senderRefund,
        uint128 recipientStreamed
    );

    /// @notice Emitted when the sender permanently gives up the right to cancel.
    event Renounced(uint256 indexed id);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroRecipient();
    error SelfStream();
    error InvalidRecipient();
    error ZeroDeposit();
    error DepositTooLarge();
    error StartInPast();
    error StartTooFar();
    error DurationOutOfRange();
    error StreamNotFound();
    error NotSender();
    error NotCancelable();
    error AlreadyCanceled();
    error StreamEnded();
    error ZeroAmount();
    error AmountExceedsWithdrawable();
    error TransferFailed();
    error DirectTransferNotAllowed();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier exists(uint256 id) {
        if (_streams[id].sender == address(0)) revert StreamNotFound();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Plain zkLTC transfers are rejected. Use {createStream}.
    receive() external payable {
        revert DirectTransferNotAllowed();
    }

    /// @notice Unknown calls are rejected.
    fallback() external payable {
        revert DirectTransferNotAllowed();
    }

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a stream funded with `msg.value` zkLTC.
    /// @param recipient Who receives the streamed zkLTC. Cannot be zero, the caller, or this contract.
    /// @param startTime Unix time the stream starts. 0 means "now" (the current block timestamp).
    ///        Otherwise it must be >= now and <= now + MAX_START_DELAY.
    /// @param duration Stream length in seconds, within [MIN_DURATION, MAX_DURATION].
    /// @param cancelable Whether the sender may cancel the stream before it ends.
    /// @return id The new stream id.
    function createStream(address recipient, uint40 startTime, uint40 duration, bool cancelable)
        external
        payable
        returns (uint256 id)
    {
        if (recipient == address(0)) revert ZeroRecipient();
        if (recipient == msg.sender) revert SelfStream();
        if (recipient == address(this)) revert InvalidRecipient();
        if (msg.value == 0) revert ZeroDeposit();
        if (msg.value > type(uint128).max) revert DepositTooLarge();

        uint40 start;
        if (startTime == 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            start = uint40(block.timestamp); // uint40 holds unix time for ~35,000 years
        } else {
            if (startTime < block.timestamp) revert StartInPast();
            if (startTime > block.timestamp + MAX_START_DELAY) revert StartTooFar();
            start = startTime;
        }
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert DurationOutOfRange();

        id = nextStreamId++;
        uint40 end = start + duration;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint128 deposit = uint128(msg.value); // checked above: msg.value <= type(uint128).max

        _streams[id] = Stream({
            sender: msg.sender,
            startTime: start,
            endTime: end,
            cancelable: cancelable,
            canceled: false,
            recipient: recipient,
            deposit: deposit,
            withdrawn: 0,
            refunded: 0
        });
        _sentIds[msg.sender].push(id);
        _receivedIds[recipient].push(id);

        emit StreamCreated(id, msg.sender, recipient, deposit, start, end, cancelable);
    }

    /// @notice Pays `amount` of the streamed, not yet withdrawn zkLTC to the stream's recipient.
    /// @dev Callable by anyone. Funds always go to the recipient, never to the caller.
    /// @param id The stream id.
    /// @param amount Amount in wei. Must be > 0 and <= {withdrawableAmountOf}.
    function withdraw(uint256 id, uint128 amount) external nonReentrant exists(id) {
        if (amount == 0) revert ZeroAmount();
        if (amount > withdrawableAmountOf(id)) revert AmountExceedsWithdrawable();
        _withdraw(id, amount);
    }

    /// @notice Pays the full withdrawable amount to the stream's recipient.
    /// @dev Callable by anyone. Funds always go to the recipient, never to the caller.
    /// @param id The stream id.
    /// @return amount The amount paid out.
    function withdrawMax(uint256 id) external nonReentrant exists(id) returns (uint128 amount) {
        amount = withdrawableAmountOf(id);
        if (amount == 0) revert ZeroAmount();
        _withdraw(id, amount);
    }

    /// @notice Cancels a cancelable stream before it ends and refunds the unstreamed part to the sender.
    /// @dev Only the sender. The streamed part is not pushed to the recipient; it stays withdrawable
    ///      (pull pattern), so a recipient that rejects zkLTC cannot block the cancel.
    /// @param id The stream id.
    function cancel(uint256 id) external nonReentrant exists(id) {
        Stream storage s = _streams[id];
        if (msg.sender != s.sender) revert NotSender();
        if (s.canceled) revert AlreadyCanceled();
        if (!s.cancelable) revert NotCancelable();
        if (block.timestamp >= s.endTime) revert StreamEnded();

        uint128 streamed = streamedAmountOf(id);
        uint128 refund = s.deposit - streamed; // > 0, because now < endTime

        s.canceled = true;
        s.refunded = refund;

        emit Canceled(id, s.sender, s.recipient, refund, streamed);

        _send(s.sender, refund);
    }

    /// @notice Permanently gives up the right to cancel this stream.
    /// @dev Only the sender. One-way.
    /// @param id The stream id.
    function renounce(uint256 id) external exists(id) {
        Stream storage s = _streams[id];
        if (msg.sender != s.sender) revert NotSender();
        if (s.canceled) revert AlreadyCanceled();
        if (!s.cancelable) revert NotCancelable();

        s.cancelable = false;

        emit Renounced(id);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the full stream struct.
    /// @param id The stream id. Reverts with StreamNotFound if it does not exist.
    function getStream(uint256 id) external view exists(id) returns (Stream memory) {
        return _streams[id];
    }

    /// @notice Returns the stream's lifecycle status.
    /// @param id The stream id. Reverts with StreamNotFound if it does not exist.
    function statusOf(uint256 id) external view exists(id) returns (Status) {
        Stream storage s = _streams[id];
        if (uint256(s.withdrawn) + s.refunded == s.deposit) return Status.Depleted;
        if (s.canceled) return Status.Canceled;
        if (block.timestamp < s.startTime) return Status.Pending;
        if (block.timestamp >= s.endTime) return Status.Settled;
        return Status.Streaming;
    }

    /// @notice Total amount streamed to the recipient so far (withdrawn or not).
    /// @dev Frozen at cancel time for canceled streams. Rounds down until endTime.
    /// @param id The stream id. Reverts with StreamNotFound if it does not exist.
    function streamedAmountOf(uint256 id) public view exists(id) returns (uint128) {
        Stream storage s = _streams[id];
        if (s.canceled) return s.deposit - s.refunded;
        if (block.timestamp <= s.startTime) return 0;
        if (block.timestamp >= s.endTime) return s.deposit;
        // uint128 * uint40 fits in uint256; the result is < deposit, so the cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128((uint256(s.deposit) * (block.timestamp - s.startTime)) / (s.endTime - s.startTime));
    }

    /// @notice Amount the recipient can withdraw right now.
    /// @param id The stream id. Reverts with StreamNotFound if it does not exist.
    function withdrawableAmountOf(uint256 id) public view exists(id) returns (uint128) {
        return streamedAmountOf(id) - _streams[id].withdrawn;
    }

    /// @notice Amount the sender would get back by canceling right now (0 if the stream cannot be canceled).
    /// @param id The stream id. Reverts with StreamNotFound if it does not exist.
    function refundableAmountOf(uint256 id) external view exists(id) returns (uint128) {
        Stream storage s = _streams[id];
        if (!s.cancelable || s.canceled || block.timestamp >= s.endTime) return 0;
        return s.deposit - streamedAmountOf(id);
    }

    /// @notice Number of streams ever created by `sender`.
    function sentCount(address sender) external view returns (uint256) {
        return _sentIds[sender].length;
    }

    /// @notice Number of streams ever created with `recipient` as the recipient.
    function receivedCount(address recipient) external view returns (uint256) {
        return _receivedIds[recipient].length;
    }

    /// @notice Paginated list of stream ids created by `sender`, oldest first.
    /// @param offset Index of the first id to return. Out-of-range offsets return an empty array.
    /// @param limit Maximum number of ids to return.
    function sentIds(address sender, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _slice(_sentIds[sender], offset, limit);
    }

    /// @notice Paginated list of stream ids received by `recipient`, oldest first.
    /// @param offset Index of the first id to return. Out-of-range offsets return an empty array.
    /// @param limit Maximum number of ids to return.
    function receivedIds(address recipient, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _slice(_receivedIds[recipient], offset, limit);
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _withdraw(uint256 id, uint128 amount) private {
        Stream storage s = _streams[id];
        s.withdrawn += amount;
        emit Withdrawn(id, s.recipient, msg.sender, amount);
        _send(s.recipient, amount);
    }

    /// @dev Sends native zkLTC with a plain call and checks the result. Return data is not copied,
    ///      so a receiver cannot make the caller pay for a huge returndata payload.
    function _send(address to, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
        if (!ok) revert TransferFailed();
    }

    function _slice(uint256[] storage ids, uint256 offset, uint256 limit) private view returns (uint256[] memory out) {
        uint256 len = ids.length;
        if (offset >= len) return new uint256[](0);
        uint256 end = limit > len - offset ? len : offset + limit;
        out = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = ids[i];
        }
    }
}

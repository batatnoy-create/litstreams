// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LitStreams} from "../contracts/LitStreams.sol";

/// @notice Step-by-step on-chain lifecycle helper (brief §6.4). Every step is its own transaction so each
///         broadcast can be approved separately and the timers (minutes) can run between steps.
/// @dev Keys come from `.env`: `PRIVATE_KEY` is the sender, `RECIPIENT_PRIVATE_KEY` is the recipient.
///      Call a step with `--sig`, for example:
///        forge script script/Lifecycle.s.sol --sig "create(address,uint256,uint40,uint40,bool)" \
///          <contract> 10000000000000000 0 600 true --rpc-url $RPC_URL            (dry run)
///      Add `--broadcast` to really send it. `status` is read-only and never needs a broadcast.
contract Lifecycle is Script {
    /// @notice Sender creates a stream to the recipient (address derived from `RECIPIENT_PRIVATE_KEY`).
    /// @param startDelay Seconds from now until the stream starts; 0 means "start now" (contract gets 0).
    function create(address c, uint256 amountWei, uint40 startDelay, uint40 duration, bool cancelable) external {
        uint256 senderPk = vm.envUint("PRIVATE_KEY");
        address recipient = vm.addr(vm.envUint("RECIPIENT_PRIVATE_KEY"));
        uint40 startTime = startDelay == 0 ? 0 : uint40(block.timestamp) + startDelay;

        console.log("Sender:", vm.addr(senderPk));
        console.log("Recipient:", recipient);
        console.log("Expected stream id:", LitStreams(payable(c)).nextStreamId());

        vm.startBroadcast(senderPk);
        uint256 id = LitStreams(payable(c)).createStream{value: amountWei}(recipient, startTime, duration, cancelable);
        vm.stopBroadcast();

        console.log("Created stream id:", id);
    }

    /// @notice Withdraws everything currently withdrawable. Funds go to the recipient whoever calls.
    /// @param asRecipient true: the recipient key sends the tx; false: the sender key sends it.
    function withdrawMax(address c, uint256 id, bool asRecipient) external {
        vm.startBroadcast(vm.envUint(asRecipient ? "RECIPIENT_PRIVATE_KEY" : "PRIVATE_KEY"));
        uint128 amount = LitStreams(payable(c)).withdrawMax(id);
        vm.stopBroadcast();
        console.log("Withdrawn (wei):", amount);
    }

    /// @notice Sender cancels the stream; the unstreamed part is refunded to the sender.
    function cancel(address c, uint256 id) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        LitStreams(payable(c)).cancel(id);
        vm.stopBroadcast();
    }

    /// @notice Sender permanently gives up the right to cancel.
    function renounce(address c, uint256 id) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        LitStreams(payable(c)).renounce(id);
        vm.stopBroadcast();
    }

    /// @notice Read-only: prints the state of a stream. Safe to run any time, no broadcast.
    function status(address c, uint256 id) external view {
        LitStreams s = LitStreams(payable(c));
        LitStreams.Stream memory st = s.getStream(id);
        console.log("block.timestamp:", block.timestamp);
        console.log("status (0=Pending 1=Streaming 2=Settled 3=Canceled 4=Depleted):", uint256(s.statusOf(id)));
        console.log("startTime:", st.startTime);
        console.log("endTime:", st.endTime);
        console.log("cancelable:", st.cancelable);
        console.log("canceled:", st.canceled);
        console.log("deposit:", st.deposit);
        console.log("withdrawn:", st.withdrawn);
        console.log("refunded:", st.refunded);
        console.log("streamed:", s.streamedAmountOf(id));
        console.log("withdrawable:", s.withdrawableAmountOf(id));
        console.log("refundable:", s.refundableAmountOf(id));
    }
}

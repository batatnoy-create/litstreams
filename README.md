# LitStreams

**Get paid in hard money, every second.** Per-second zkLTC payment streaming on LitVM, Litecoin's EVM rollup.

**Live (testnet):** https://ubiquitous-chimera-7afb97.netlify.app/

> Testnet only. Unaudited. The zkLTC on LiteForge has no real value.

| | |
| --- | --- |
| Network | LitVM LiteForge testnet, chain ID `4441` |
| Contract | [`0xB3146ab6401d69DC7EFCa457a637760d192D1fFD`](https://liteforge.explorer.caldera.xyz/address/0xb3146ab6401d69dc7efca457a637760d192d1ffd) (source verified) |
| Source | `contracts/LitStreams.sol` (Solidity 0.8.24, `paris`) |

## How it works

1. **Lock.** A sender deposits native zkLTC for one recipient, with a start time and a duration.
2. **Stream.** The recipient's share grows linearly every second until the end time.
3. **Withdraw.** The recipient withdraws what has streamed at any time. Anyone can trigger a payout, but the money always goes to the recipient.
4. **Cancel (optional).** If the stream is cancelable, the sender can stop it: the unstreamed part is refunded, and the streamed part stays with the recipient. A sender can also renounce the right to cancel.

No admin, no fees, no upgrades, no token.

## Security notes

Read [`docs/SECURITY.md`](docs/SECURITY.md) before using it. In short: the contract is unaudited and runs on testnet only; the recipient cannot be changed, so a lost recipient key means streamed funds are stuck; time comes from the LitVM sequencer.

## Run the tests

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge build
forge test
forge coverage --no-match-coverage "(test|script)"
```

## The website

`web/` is a static single-page dApp with no build step (vendored ethers v6). It is deployed on Netlify from the `main` branch with `web` as the publish directory (see `netlify.toml`). To run it locally:

```bash
python -m http.server 8765 --directory web
```

## Docs

- [`docs/SPEC.md`](docs/SPEC.md): contract specification
- [`docs/DEPLOYMENTS.md`](docs/DEPLOYMENTS.md): deployment, verification and on-chain test transactions
- [`docs/DECISIONS.md`](docs/DECISIONS.md): every judgment call
- [`docs/SECURITY.md`](docs/SECURITY.md): threat model and limitations

## License

[MIT](LICENSE)

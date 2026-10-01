# DEPLOYMENTS

## LiteForge testnet (chain id 4441)

| | |
| --- | --- |
| Contract | `0xB3146ab6401d69DC7EFCa457a637760d192D1fFD` |
| Deploy tx | `0x01c329e8a976d218d4c6a965a709afe4db2360b1d6bd3846dd1764458adece1a` |
| Deploy block | 56604437 |
| Deployer / demo sender | `0x38D58184791De33f3935Eb32B503de6F5Bca1CAe` |
| Demo recipient | `0xb14991cf0AB9Fa866BDdF0e3FB9426C3600912ae` |
| Compiler | solc 0.8.24, evm `paris`, optimizer 200 runs |
| Gas used | 1,424,925 |
| Source verification | Pending: the Blockscout indexer was ~8,600 blocks behind at deploy time (see below). |
| On-chain code check | `keccak256(eth_getCode)` equals `keccak256(forge inspect deployedBytecode)` = `0x6e86…d1ef` |

Verification command (run once the explorer has indexed the contract):

```
forge verify-contract 0xB3146ab6401d69DC7EFCa457a637760d192D1fFD contracts/LitStreams.sol:LitStreams \
  --chain-id 4441 --verifier blockscout --verifier-url https://liteforge.explorer.caldera.xyz/api/ \
  --compiler-version 0.8.24 --evm-version paris --num-of-optimizations 200 --watch
```

## Lifecycle streams (brief §6.4)

Run on 2026-10-01 by `script/run-lifecycle.sh` (cast, timers honored). Full log: `docs/lifecycle-run.log`.
Amounts: 0.005 zkLTC per stream. All transactions status 1 (success).

| Stream | Step | Tx |
| --- | --- | --- |
| A (id 1, 10 min, cancelable) | create | `0x53e95433c8c0eba89defbbe084b428833ef9b1f5db6a20a720eb568d37bff34e` |
| A | `withdrawMax` by recipient at ~3 min (1.5667e15 wei) | `0x0274a93c41a6fbd85d6a61d15b532682fff6c6575e746c16aab659e04a474a0a` |
| A | `cancel` by sender at ~5 min (refund 2.45e15 wei) | `0x2f4a0bd8e93f1e3f1565cde2a48efe8eaf7b9560eac57bc14e9dd029b44eb844` |
| A | `withdrawMax` of the rest by recipient, status becomes Depleted | `0x40af0c661b81161883f9862f714e5af25ea785805221df5c71bf64896d2318c2` |
| B (id 2, 5 min, cancelable) | create | `0x32e19054dcec0a94558ef3b942a055e23b41b7c4ce665b7f898a1cc54763e92c` |
| B | `renounce` | `0x51c2cb970d9faa88e750bf8795c8d63432b310f79b4f05b4dd7142e087121a6f` |
| B | `withdrawMax` called by the **sender** after the end; recipient balance +5e15 wei exactly | `0x830622bc4794698854ed0c897ba1ed000ba2ef401763ff393656edfd1f6b19a1` |
| C (id 3, starts in 10 min) | create | `0xfe33984fec23769f1d38210d038c75b438084cfdce0e53660e70fc20fa34e578` |
| C | `cancel` before start (full refund, status Depleted) | `0x89cad0bd8700ddb16cf48d9c89f58f02649dc3e790e7cbaa367c47596b693635` |

Other: gas top-up sender to recipient 0.004 zkLTC, tx `0x33cf39f3f3a6eba265643768d7626a6a795d47070abe9b2c6870e39955317e4d`.
Note: the explorer shows no on-demand blocks between transactions; on LitVM `block.timestamp` of the next transaction is the sequencer's clock, which the timers rely on.

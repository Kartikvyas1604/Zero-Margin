# ZeroMargin contract dependencies — pinned

`contracts/lib/` is not committed. Reproduce with:

```bash
cd contracts
forge install openzeppelin/openzeppelin-contracts@v5.1.0
forge install Uniswap/v4-core Uniswap/v4-periphery foundry-rs/forge-std
forge install transmissions11/solmate
```

| Dependency | Pinned ref | Exact commit |
| :--- | :--- | :--- |
| openzeppelin-contracts | tag `v5.1.0` (spec §16.2) | `69c8def5f222ff96f2b5beff05dfba996368aa79` |
| v4-core | branch `main` at install (spec §6.1 says pin the tag verified at kickoff; upstream shipped no `BaseHook` on this branch — the hook implements `IHooks` directly) | `e50237c43811bd9b526eff40f26772152a42daba` |
| v4-periphery | branch `main` at install (used for `HookMiner` in `test/shared/` + `LiquidityAmounts`) | `c6e4754d` |
| forge-std | tag `v1.17.0` | `f3dae6e6ee381f25eb6a246f7da9b85c91a68219` |
| solmate | `main` as fetched (v4-periphery's `Owned` dependency) | `89365b880c4f3c786bdd453d4b8e8fe410344a69` |

Deviations from the spec's reference layout are recorded in `../DECISIONS.md`.

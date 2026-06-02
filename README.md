# Robin Markets

Robin Markets is a DeFi protocol on Polygon that lets users stake Polymarket prediction-market positions (YES/NO conditional tokens) into a yield-bearing vault. The vault pairs tokens, merges them to USDC.e, deposits the USDC.e into ERC-4626 yield vaults, and distributes yield based on TWAP pricing.

## Deployed contracts

**Network:** Polygon (chain ID `137`) · Explorer: [polygonscan.com](https://polygonscan.com)

### Upgradeable (UUPS) — interact with the proxy

| Contract | Proxy | Current implementation |
| --- | --- | --- |
| RobinStakingVault | [`0xcb7444981296D08dA7161B75378e3773DbF5D806`](https://polygonscan.com/address/0xcb7444981296D08dA7161B75378e3773DbF5D806) | [`0x617e46bA1e532c05128E87d596e3989e172DbfF4`](https://polygonscan.com/address/0x617e46bA1e532c05128E87d596e3989e172DbfF4) |
| RobinTwapOracle | [`0xf08a02deeB4C7A09fAc8e8C6f8508D724612796f`](https://polygonscan.com/address/0xf08a02deeB4C7A09fAc8e8C6f8508D724612796f) | [`0xb99Ca353137d88D195cff973436de2F2a6940b46`](https://polygonscan.com/address/0xb99Ca353137d88D195cff973436de2F2a6940b46) |

### Non-upgradeable

| Contract | Address | Notes |
| --- | --- | --- |
| RobinStakingVaultExtension | [`0xee2FE153a04E786850C36DCf9a5926c205428976`](https://polygonscan.com/address/0xee2FE153a04E786850C36DCf9a5926c205428976) | Admin surface; `delegatecall`ed from the vault and shares its storage layout |
| RobinLens | [`0xDbB59819C5a4d28374a162e375Ce4595c8650dDC`](https://polygonscan.com/address/0xDbB59819C5a4d28374a162e375Ce4595c8650dDC) | Stateless batch view aggregator |
| RobinTimeLockController | [`0xCFc779670a6326c440919B41039bb9c48FA04C7A`](https://polygonscan.com/address/0xCFc779670a6326c440919B41039bb9c48FA04C7A) | Governs UUPS upgrades and timelocked admin functions |

Implementation addresses change with each upgrade; the proxy addresses above are stable. See the [release notes](https://github.com/robin-markets/staking-vault-contracts/releases) for the implementation set shipped in each version.

## More information
- **Audit reports** - [audits/](audits/)
- **Deployment broadcasts** - [broadcast/](broadcast/): Foundry run logs for the deploy and upgrade scripts (chain `137`).

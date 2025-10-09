# Deploying a Morpho Vault & Creating Markets

This doc explains the overall process for deploying a new Morpho vault and
creating new markets for it.

This process involves several forge scripts found in two contracts

- `script/templates/DeployMorphoVault.s.sol`
- `script/templates/CreateMorphoMarket.s.sol`

Generally, the process is as follows:

1. Create a market(s) on Morpho Blue
2. Deploy the vault using the Morpho Factory
3. Set the supply cap and queue for the market(s) (as curator)
4. Supply and borrow from the market(s) (to prevent 0% utilization decay)
5. Set the final curator

## Create a market on Morpho Blue

1. create a config json file at
   `script/templates/markets/{LOAN_TOKEN_NAME_COLLATERAL_TOKEN_NAME}.json`. for
   example:

```json
{
  "vaultAddressName": "meUSDC_METAMORPHO_VAULT",
  "loanTokenName": "USDC",
  "collateralTokenName": "xWELL_PROXY",
  "irmName": "MORPHO_ADAPTIVE_CURVE_IRM",
  "lltv": 625000000000000000,
  "supplyCap": 100000000000000,
  "setSupplyQueue": true,
  "morphoBlueName": "MORPHO_BLUE",
  "oracle": {
    "addressName": "MORPHO_CHAINLINK_WELL_USD_ORACLE_PROXY",
    "baseFeedName": "CHAINLINK_WELL_USD",
    "baseFeedDecimals": 18,
    "quoteFeedName": "CHAINLINK_USDC_USD",
    "quoteFeedDecimals": 6
  },
  "vaultDepositAssets": 0,
  "collateralAmount": 0,
  "borrowAssets": 0
}
```

2. export env for `NEW_MARKET_PATH` pointing to this file

```bash
export NEW_MARKET_PATH=script/templates/markets/{LOAN_TOKEN_NAME_COLLATERAL_TOKEN_NAME}.json
```

3. run the forge script

```bash
forge script script/templates/CreateMorphoMarket.s.sol:CreateMorphoMarket
```

## Deploy a Morpho Vault

1. create a config json file at `script/templates/vaults/{VAULT_NAME}.json`. for
   example:

```json
{
  "addressName": "meUSDC_METAMORPHO_VAULT",
  "vaultName": "USDC Vault",
  "vaultSymbol": "meUSDC",
  "assetName": "USDC",
  "factoryName": "MORPHO_FACTORY_V1_1",
  "curatorName": "ANTHIAS_MULTISIG",
  "saltString": "meUSDC",
  "initialTimelock": 0
}
```

2. export env for `NEW_VAULT_PATH` pointing to this file

```bash
export NEW_VAULT_PATH=script/templates/vaults/{VAULT_NAME}.json
```

3. run the forge script

```bash
forge script script/templates/DeployMorphoVault.s.sol:DeployMorphoVault
```

## Set the market supply cap and queue

This script can only be called while we are the vault curator; we will be
setting the final curator at the end of this process

Assuming `NEW_MARKET_PATH` is still set in the env

```bash
forge script script/templates/CreateMorphoMarket.s.sol:ConfigureMorphoMarketCaps
```

## Supply and borrow from the market

This must be done immediately after deployment of the market to prevent 0%
utilization decay
([see morpho docs](https://docs.morpho.org/curate/tutorials-market-v1/creating-market/#fill-all-attributes))

Assuming `NEW_MARKET_PATH` is still set in the env

Assuming the config json contains positive values for `vaultDepositAssets`,
`collateralAmount`, `borrowAssets` (in decimals) AND the sender has sufficient
balance of the collateral token

```bash
forge script script/templates/CreateMorphoMarket.s.sol:MorphoSupplyBorrow
```

## Set the final curator

This will transfer curator role to the final curator address and cannot be
undone; this script should only be run _after_ the previous step

Assuming `NEW_VAULT_PATH` is still set in the env

```bash
forge script script/templates/DeployMorphoVault.s.sol:SetFinalCurator
```

## [DRY RUN] Creating WELL and MAMO markets for the `meUSDC_METAMORPHO_VAULT` vault

### WELL

```bash
export NEW_VAULT_PATH=script/templates/vaults/meUSDC_METAMORPHO_VAULT.json
export NEW_MARKET_MARKET_PATH=script/templates/markets/meUSDC_WELL_MARKET.json

forge script script/templates/CreateMorphoMarket.s.sol:CreateMorphoMarket

# we prank as the anthias multisig for this dry run
forge script script/templates/CreateMorphoMarket.s.sol:ConfigureMorphoMarketCaps --broadcast --unlocked 0x08edebffae68970dcf751baa826182b3a4acfc05

# see market config for the values
forge script script/templates/CreateMorphoMarket.s.sol:MorphoSupplyBorrow

forge script script/templates/DeployMorphoVault.s.sol:SetFinalCurator
```

### MAMO

```bash
export NEW_VAULT_PATH=script/templates/vaults/meUSDC_METAMORPHO_VAULT.json
export NEW_MARKET_MARKET_PATH=script/templates/markets/meUSDC_MAMO_MARKET.json

forge script script/templates/CreateMorphoMarket.s.sol:CreateMorphoMarket

# we prank as the anthias multisig for this dry run
forge script script/templates/CreateMorphoMarket.s.sol:ConfigureMorphoMarketCaps --broadcast --unlocked 0x08edebffae68970dcf751baa826182b3a4acfc05

# see market config for the values
forge script script/templates/CreateMorphoMarket.s.sol:MorphoSupplyBorrow

forge script script/templates/DeployMorphoVault.s.sol:SetFinalCurator
```

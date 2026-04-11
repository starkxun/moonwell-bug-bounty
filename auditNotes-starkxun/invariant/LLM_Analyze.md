# Moonwell V2 借贷核心协议建模（基于代码）

> 范围说明：本建模聚焦借贷主路径与奖励子系统，依据以下核心合约：
> - `src/Unitroller.sol`
> - `src/Comptroller.sol`
> - `src/ComptrollerStorage.sol`
> - `src/MToken.sol`
> - `src/MErc20Delegator.sol`
> - `src/MTokenInterfaces.sol`
> - `src/rewards/MultiRewardDistributor.sol`

---

## 1. 角色与权限

### A. Governance / Timelock（通过 admin 落地）
- `Unitroller.admin`：协议最高管理权限（升级 Comptroller 实现、移交 admin）。
- `Comptroller.admin`：
  - 参数治理：`_setPriceOracle`、`_setCloseFactor`、`_setCollateralFactor`、`_setLiquidationIncentive`
  - 市场治理：`_supportMarket`、`_setRewardDistributor`
  - Guardian 任命：`_setPauseGuardian`、`_setBorrowCapGuardian`、`_setSupplyCapGuardian`
  - 资金救援：`_rescueFunds`
- `MToken.admin`：
  - 市场级治理：`_setComptroller`、`_setReserveFactor`、`_setInterestRateModel`、`_setProtocolSeizeShare`
  - 储备资金治理：`_reduceReserves`
  - 管理员移交：`_setPendingAdmin` / `_acceptAdmin`
- `MultiRewardDistributor` 实际无独立 owner，核心权限依赖 `comptroller.admin()`（`onlyComptrollersAdmin`）。

### B. Guardian 角色
- `Comptroller.pauseGuardian`：可暂停 `mint/borrow/transfer/seize`，但**只能 pause，不能 unpause**（unpause 仅 admin）。
- `borrowCapGuardian`：可设置各市场 `borrowCaps`。
- `supplyCapGuardian`：可设置各市场 `supplyCaps`。
- `MultiRewardDistributor.pauseGuardian`：可暂停奖励发放（不暂停奖励累计）。

### C. Emission Config Owner（奖励配置所有者）
- `MultiRewardDistributor` 中每个 `(mToken, emissionToken)` 配置有 owner。
- owner 或 comptroller admin 可更新：
  - `_updateSupplySpeed`
  - `_updateBorrowSpeed`
  - `_updateOwner`
  - `_updateEndTime`

### D. 普通用户
- 供应、赎回、借款、还款、清算、mToken 转账、领取奖励。
- 用户资产操作受 `Comptroller` 风控钩子统一约束（`mintAllowed`/`borrowAllowed`/`redeemAllowed`/`seizeAllowed` 等）。

### E. 代理/实现层角色
- `Unitroller`：Comptroller 的代理存储层（fallback delegatecall）。
- `MErc20Delegator`：市场代币代理层，用户入口几乎都先进入 Delegator 再 delegate 到实现。

---

## 2. 用户入口函数

## 2.1 借贷市场用户入口（`MErc20Delegator` 暴露）
- 供应：`mint`、`mintWithPermit`
- 赎回：`redeem`、`redeemUnderlying`
- 借款：`borrow`
- 还款：`repayBorrow`、`repayBorrowBehalf`
- 清算：`liquidateBorrow`
- mToken 转账：`transfer`、`transferFrom`、`approve`
- 查询：`balanceOfUnderlying`、`borrowBalanceCurrent`、`exchangeRateCurrent` 等

> 以上函数本身多为转发，真实状态更新发生在 `MToken` 实现。

## 2.2 Comptroller 用户入口
- 抵押市场管理：`enterMarkets`、`exitMarket`
- 奖励领取：`claimReward(...)` 多重重载
- 风险查询：`getAccountLiquidity`、`getHypotheticalAccountLiquidity`

## 2.3 直接读取奖励
- `MultiRewardDistributor.getOutstandingRewardsForUser(...)`

---

## 3. 管理员入口函数

## 3.1 Unitroller（协议升级治理）
- `_setPendingImplementation`
- `_acceptImplementation`
- `_setPendingAdmin`
- `_acceptAdmin`

## 3.2 Comptroller（系统级风控/参数）
- 参数：`_setPriceOracle`、`_setCloseFactor`、`_setCollateralFactor`、`_setLiquidationIncentive`
- 市场：`_supportMarket`
- 上限：`_setMarketBorrowCaps`、`_setMarketSupplyCaps`
- Guardian：`_setBorrowCapGuardian`、`_setSupplyCapGuardian`、`_setPauseGuardian`
- 暂停开关：`_setMintPaused`、`_setBorrowPaused`、`_setTransferPaused`、`_setSeizePaused`
- 奖励绑定：`_setRewardDistributor`
- 资产救援：`_rescueFunds`

## 3.3 MToken（单市场参数）
- `_setComptroller`
- `_setReserveFactor`
- `_setInterestRateModel`
- `_setProtocolSeizeShare`
- `_addReserves`（外部可调，向储备注资）
- `_reduceReserves`（仅 admin）
- `_setPendingAdmin` / `_acceptAdmin`

## 3.4 MultiRewardDistributor
- 仅 comptroller admin：`_addEmissionConfig`、`_setEmissionCap`、`_rescueFunds`、`_unpauseRewards`
- pauseGuardian/admin：`_pauseRewards`、`_setPauseGuardian`
- 配置 owner/admin：`_updateSupplySpeed`、`_updateBorrowSpeed`、`_updateOwner`、`_updateEndTime`

---

## 4. 关键状态变量及其含义

## 4.1 Comptroller / Unitroller
- `admin / pendingAdmin`：治理权移交状态。
- `comptrollerImplementation / pendingComptrollerImplementation`：升级实现地址。
- `markets[address] => Market`：市场是否上线、抵押因子、用户是否入市。
- `accountAssets[user]`：用户已入市资产列表（参与流动性计算）。
- `allMarkets`：全市场枚举。
- `oracle`：价格预言机。
- `closeFactorMantissa`：单次可清算债务比例上限。
- `liquidationIncentiveMantissa`：清算激励倍数。
- `borrowCaps / supplyCaps`：市场借款/供应上限。
- `mintGuardianPaused / borrowGuardianPaused / transferGuardianPaused / seizeGuardianPaused`：动作级熔断。
- `rewardDistributor`：奖励分发器地址。

## 4.2 MToken（单市场账本）
- `totalSupply`：mToken 总供应。
- `accountTokens[user]`：用户 mToken 余额。
- `totalBorrows`：市场总借款（底层资产计价）。
- `accountBorrows[user].principal`：用户借款本金（按上次更新点）。
- `borrowIndex`：借款指数（全局复利因子）。
- `accrualBlockTimestamp`：上次计息时间戳。
- `totalReserves`：协议储备。
- `reserveFactorMantissa`：利息进入储备的比例。
- `protocolSeizeShareMantissa`：清算扣押中协议截留比例。
- `comptroller`：风控中心地址。
- `interestRateModel`：利率模型。
- `underlying`（MErc20）：底层资产地址。

## 4.3 MultiRewardDistributor
- `marketConfigs[mToken]`：每市场多奖励配置数组。
  - 配置内含：`owner`、`emissionToken`、`endTime`、供/借 emission speed、全局 index 与 timestamp。
- `supplierIndices/borrowerIndices[user]`：用户在该配置下的最新索引位置。
- `supplierRewardsAccrued/borrowerRewardsAccrued[user]`：用户应得未发奖励余额。
- `pauseGuardian`：奖励发放熔断角色。
- `emissionCap`：速度上限。
- `comptroller`：权限锚点与市场来源。

---

## 5. 资产流转路径

## 5.1 供应（Supply）
1. 用户调用 `MErc20Delegator.mint`。
2. 代理转发到 `MToken.mintInternal -> mintFresh`。
3. `Comptroller.mintAllowed` 校验：市场上线、未暂停、未超 supply cap。
4. `doTransferIn`：底层资产进入 mToken 合约。
5. 按 `exchangeRate` 铸造 mToken：更新 `totalSupply`、`accountTokens[user]`。

## 5.2 赎回（Redeem）
1. 用户调用 `redeem/redeemUnderlying`。
2. `MToken.redeemFresh` 调 `Comptroller.redeemAllowed` 校验流动性。
3. 更新 `totalSupply`、`accountTokens[user]`。
4. `doTransferOut`：底层资产从 mToken 转给用户。

## 5.3 借款（Borrow）
1. 用户调用 `borrow`。
2. `MToken.borrowFresh` 调 `Comptroller.borrowAllowed`：
   - 若用户未入市，尝试自动加入该市场；
   - 校验预言机价格、borrow cap、账户流动性。
3. 更新 `accountBorrows[user]`、`totalBorrows`。
4. `doTransferOut`：底层资产从 mToken 给用户。

## 5.4 还款（Repay）
1. 用户调用 `repayBorrow/repayBorrowBehalf`。
2. `Comptroller.repayBorrowAllowed`。
3. `doTransferIn`：底层资产进入 mToken。
4. 更新 `accountBorrows[user]`、`totalBorrows`。

## 5.5 清算（Liquidation）
1. 清算人调用借款市场 `liquidateBorrow`。
2. `Comptroller.liquidateBorrowAllowed` 校验 borrower shortfall 与 closeFactor。
3. 先还借款侧债务（`repayBorrowFresh`）。
4. `Comptroller.liquidateCalculateSeizeTokens` 计算应扣押抵押 mToken 数量。
5. 抵押市场 `seizeInternal`：
   - 减 borrower mToken；
   - 给 liquidator 一部分 mToken；
   - 协议截留部分转为 `totalReserves`（并相应减少 `totalSupply`）。

## 5.6 奖励（Reward）
1. 在 `mint/borrow/repay/redeem/transfer/seize` 等路径中由 Comptroller 触发更新索引与用户应计奖励。
2. 用户调用 `claimReward` 时，Comptroller 触发 `rewardDistributor` 更新并尝试发放。
3. 若奖励池余额不足或暂停发放，则仅累计到 `*_RewardsAccrued`。

---

## 6. 每个函数会修改哪些状态（按核心函数族归类）

## 6.1 Unitroller
- `_setPendingImplementation`：`pendingComptrollerImplementation`
- `_acceptImplementation`：`comptrollerImplementation`、`pendingComptrollerImplementation`
- `_setPendingAdmin`：`pendingAdmin`
- `_acceptAdmin`：`admin`、`pendingAdmin`

## 6.2 Comptroller 用户相关
- `enterMarkets` / `addToMarketInternal`：
  - `markets[mToken].accountMembership[user]`
  - `accountAssets[user]`
- `exitMarket`：
  - 删除 `markets[mToken].accountMembership[user]`
  - 从 `accountAssets[user]` 移除该市场
- `claimReward(...)`：不直接改 Comptroller 关键存储；会外部调用奖励合约更新/发放。

## 6.3 Comptroller 管理相关
- `_setPriceOracle`：`oracle`
- `_setCloseFactor`：`closeFactorMantissa`
- `_setCollateralFactor`：`markets[mToken].collateralFactorMantissa`
- `_setLiquidationIncentive`：`liquidationIncentiveMantissa`
- `_supportMarket`：`markets[mToken].isListed`、`markets[mToken].collateralFactorMantissa`、`allMarkets`
- `_setMarketBorrowCaps`：`borrowCaps[mToken]`
- `_setMarketSupplyCaps`：`supplyCaps[mToken]`
- `_setBorrowCapGuardian`：`borrowCapGuardian`
- `_setSupplyCapGuardian`：`supplyCapGuardian`
- `_setPauseGuardian`：`pauseGuardian`
- `_setMintPaused`：`mintGuardianPaused[mToken]`
- `_setBorrowPaused`：`borrowGuardianPaused[mToken]`
- `_setTransferPaused`：`transferGuardianPaused`
- `_setSeizePaused`：`seizeGuardianPaused`
- `_setRewardDistributor`：`rewardDistributor`

## 6.4 MToken 账本核心
- `accrueInterest`：
  - `accrualBlockTimestamp`
  - `borrowIndex`
  - `totalBorrows`
  - `totalReserves`
- `mintFresh`：`totalSupply`、`accountTokens[minter]`
- `redeemFresh`：`totalSupply`、`accountTokens[redeemer]`
- `borrowFresh`：`accountBorrows[borrower].principal`、`accountBorrows[borrower].interestIndex`、`totalBorrows`
- `repayBorrowFresh`：`accountBorrows[borrower].principal`、`accountBorrows[borrower].interestIndex`、`totalBorrows`
- `seizeInternal`：
  - `accountTokens[borrower]`
  - `accountTokens[liquidator]`
  - `totalReserves`
  - `totalSupply`

## 6.5 MToken 管理参数
- `_setPendingAdmin` / `_acceptAdmin`：`pendingAdmin`、`admin`
- `_setComptroller`：`comptroller`
- `_setReserveFactorFresh`：`reserveFactorMantissa`
- `_addReservesFresh`：`totalReserves`
- `_reduceReservesFresh`：`totalReserves`
- `_setInterestRateModelFresh`：`interestRateModel`
- `_setProtocolSeizeShareFresh`：`protocolSeizeShareMantissa`

## 6.6 MultiRewardDistributor
- `_addEmissionConfig`：`marketConfigs[mToken]` append 新配置
- `_setPauseGuardian`：`pauseGuardian`
- `_setEmissionCap`：`emissionCap`
- `_pauseRewards` / `_unpauseRewards`：`Pausable` 的 paused 状态
- `_updateSupplySpeed`：配置中的 `supplyEmissionsPerSec`
- `_updateBorrowSpeed`：配置中的 `borrowEmissionsPerSec`
- `_updateOwner`：配置中的 `owner`
- `_updateEndTime`：配置中的 `endTime`
- `updateMarketSupplyIndexInternal`：配置中的 `supplyGlobalIndex`、`supplyGlobalTimestamp`
- `updateMarketBorrowIndexInternal`：配置中的 `borrowGlobalIndex`、`borrowGlobalTimestamp`
- `disburseSupplierRewardsInternal`：
  - `supplierIndices[user]`
  - `supplierRewardsAccrued[user]`
- `disburseBorrowerRewardsInternal`：
  - `borrowerIndices[user]`
  - `borrowerRewardsAccrued[user]`

---

## 7. 哪些函数之间存在隐式耦合

1. `MToken.mint/borrow/redeem/repay/liquidate/seize/transfer` 与 `Comptroller.*Allowed`
- 所有用户资产动作都先过 Comptroller 钩子；参数改动（抵押因子、cap、pause、oracle）会立即改变用户入口行为。

2. `Comptroller.claimReward` 与 `MultiRewardDistributor`
- `Comptroller.rewardDistributor` 指针决定奖励逻辑是否可用；若设置为 0 地址，`claimReward` 直接不可用。

3. `Comptroller` 流动性计算与 `MToken` 快照接口
- `getHypotheticalAccountLiquidityInternal` 依赖每个市场 `getAccountSnapshot`、`exchangeRateStored`、`borrowBalanceStored`，任何市场实现差异都会影响全局风控结果。

4. `liquidateBorrow` 跨市场耦合
- 借款市场和抵押市场都需要“fresh”并共享同一 comptroller；清算额度计算依赖两侧价格 + 抵押市场汇率。

5. `accrueInterest` 与几乎所有状态变更函数
- 多数关键变更函数要求 market fresh（当前时间戳），所以先 `accrueInterest` 是隐式前置条件。

6. `MultiRewardDistributor` 权限锚定 `comptroller.admin()`
- 奖励合约本身权限来自外部 comptroller；若 comptroller admin 变更，奖励合约权限自动迁移。

7. `pause` 与“仅发放暂停、不停止累计”
- 奖励暂停时，`sendReward` 不转账，但 `*_RewardsAccrued` 仍增长，形成“账上累计、延后支付”耦合行为。

---

## 8. 系统最核心的 3~5 条会计关系

1. 市场资产恒等式（近似）
- `totalSupply * exchangeRate ~= cash + totalBorrows - totalReserves`
- 其中 `exchangeRate` 由 `exchangeRateStoredInternal` 基于三者推导。

2. 借款指数与用户债务关系
- 用户当前债务与 `borrowIndex` 成比例增长。
- 当用户发生借/还款时，会把 `accountBorrows[user].interestIndex` 对齐到当前 `borrowIndex`。

3. 清算分配关系
- `seizeTokens = liquidatorSeizeTokens + protocolSeizeTokens`
- `protocolSeizeAmount = protocolSeizeTokens * exchangeRate`
- 并导致：`totalReserves += protocolSeizeAmount`，`totalSupply -= protocolSeizeTokens`。

4. 风控约束关系
- 可借额度取决于：
  - `sum(collateral * collateralFactor * price)` 与 `sum(borrow * price)` 比较
- 当 shortfall > 0 时可进入清算流程。

5. 奖励索引与应计关系
- 用户应计奖励 = 旧应计 + 用户规模 * (全局索引增量)
- 若未实际发放（余额不足或 paused），差额留在 `*_RewardsAccrued`，后续可继续发。

---

## 9. 状态机（简洁描述）

## 9.1 市场级状态机（Comptroller 视角）
- `Unlisted`：市场未上线，不允许 mint/borrow 等。
- `Listed`：市场上线，可参与风控与借贷。
- `Paused(X)`：针对某动作 X（Mint/Borrow/Transfer/Seize）可被暂停。
- `Listed + Active`：动作未暂停，按 cap + liquidity + oracle 正常运行。

状态迁移：
- `Unlisted -> Listed`：`_supportMarket`
- `Listed -> Paused(X)`：guardian/admin 调 `_set*Paused(..., true)`
- `Paused(X) -> Listed Active`：仅 admin 可 `_set*Paused(..., false)`

## 9.2 账户级状态机（借贷生命周期）
- `Idle`：未入市或无仓位。
- `Collateralized`：已 supply 且 enterMarkets。
- `Borrowing`：存在借款头寸。
- `Healthy`：liquidity >= 0 且 shortfall = 0。
- `Liquidatable`：shortfall > 0。
- `Repaid/Exitable`：债务为 0 且可退出市场。

典型流转：
- `Idle -> Collateralized`：mint + enterMarkets
- `Collateralized -> Borrowing`：borrow
- `Borrowing -> Liquidatable`：价格/参数变化或负债增长导致 shortfall
- `Liquidatable -> Borrowing/Healthy`：被 liquidate 后头寸下降
- `Borrowing -> Repaid/Exitable`：repay
- `Repaid/Exitable -> Idle`：exitMarket + redeem

## 9.3 奖励子系统状态机
- `Accruing`：索引更新并累计应计奖励。
- `PausedDisbursement`：暂停发放，仅累计不转账。
- `Disbursing`：claim 或钩子触发，若余额足够则转账并冲减应计。
- `InsufficientBalance`：余额不足时继续保留应计，等待后续发放。

---

## 备注
- 本文是“协议建模”而非漏洞结论，不直接推断漏洞。
- 若要继续，可在此模型上追加：
  - 不变量清单（Invariant）
  - 函数级前后置条件（Pre/Post conditions）
  - 风险路径优先级（按可达性 + 资金影响）

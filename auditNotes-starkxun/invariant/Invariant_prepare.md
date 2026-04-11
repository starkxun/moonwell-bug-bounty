# Moonwell V2 Invariant 准备清单

说明：以下不变量用于属性测试/handler 模式（例如 Foundry invariant fuzz）。
除特别说明外，默认按“单市场 mToken 维度”检查，并允许 1~2 wei 级别舍入误差。

---

## 1. 全局不变量

### G1. 市场列表唯一且已上市
- invariant描述
  - `allMarkets` 中每个市场地址应唯一，且在 `markets[address].isListed` 中为 true。
- 数学表达
  - $\forall i \neq j,\ allMarkets[i] \neq allMarkets[j]$
  - $\forall m \in allMarkets,\ markets[m].isListed = true$
- 适合在哪些handler动作后检查
  - `_supportMarket`、治理批量上架后。
- 可能出现误报的情况
  - 测试中直接写存储或 fork 状态被外部脚本污染。

### G2. 全局流动性返回值互斥
- invariant描述
  - `getAccountLiquidity(account)` 返回的 `liquidity` 与 `shortfall` 不应同时为正。
- 数学表达
  - $liquidity \times shortfall = 0$
- 适合在哪些handler动作后检查
  - `enterMarkets`、`exitMarket`、`mint`、`redeem`、`borrow`、`repayBorrow`、`liquidateBorrow`。
- 可能出现误报的情况
  - 价格源异常（预言机返回无效值）导致上层测试桩行为失真。

### G3. 暂停状态机约束
- invariant描述
  - guardian 可暂停但不能解暂停；非 admin 无法执行 unpause。
- 数学表达
  - 若调用者 `!= admin` 且传入 `state=false`，`_setMintPaused/_setBorrowPaused/_setTransferPaused/_setSeizePaused` 必须失败或状态不变。
- 适合在哪些handler动作后检查
  - 各 pause/unpause handler 后。
- 可能出现误报的情况
  - handler 中 prank 地址配置错误（把 admin 当成普通地址）。

### G4. 奖励暂停只影响发放不影响累计
- invariant描述
  - paused 时奖励应可继续累积，但不应实际转出奖励 token。
- 数学表达
  - paused 时，`sendReward(user, x, token)` 返回值应为 `x` 或未减少 accrued；且 `balance(distributor, token)` 不减少。
- 适合在哪些handler动作后检查
  - `_pauseRewards` 后的 `claimReward`、`update/disburse` 路径。
- 可能出现误报的情况
  - 奖励 token 为税费型/rebasing token，余额变化不等于转账语义。

### G5. 关键时间戳单调
- invariant描述
  - 市场 `accrualBlockTimestamp` 和奖励全局时间戳应单调不减。
- 数学表达
  - $accrualTs_{t+1} \ge accrualTs_t$
  - $supplyGlobalTimestamp_{t+1} \ge supplyGlobalTimestamp_t$
  - $borrowGlobalTimestamp_{t+1} \ge borrowGlobalTimestamp_t$
- 适合在哪些handler动作后检查
  - `accrueInterest`、`mint/borrow/repay/redeem`、奖励索引更新函数后。
- 可能出现误报的情况
  - 测试中人为回退区块时间（非真实链行为）。

---

## 2. 单账户不变量

### A1. 入市关系双向一致
- invariant描述
  - 若账户在 `accountAssets` 中包含某市场，则 `checkMembership` 必须为 true；反向亦然。
- 数学表达
  - $m \in accountAssets[u] \iff markets[m].accountMembership[u]=true$
- 适合在哪些handler动作后检查
  - `enterMarkets`、`exitMarket`、`borrow`（自动入市）后。
- 可能出现误报的情况
  - handler 只更新一侧状态（例如直接写 storage 的测试桩）。

### A2. 退出市场后不再持有 membership
- invariant描述
  - `exitMarket` 成功后，用户对该市场 membership 必须为 false。
- 数学表达
  - `exitMarket(m)` success $\Rightarrow markets[m].accountMembership[u]=false$
- 适合在哪些handler动作后检查
  - `exitMarket` 后。
- 可能出现误报的情况
  - 调用返回非 0 错误码但测试仍按 success 分支断言。

### A3. 用户债务不为负，且全额还款后归零
- invariant描述
  - 用户借款余额始终 `>=0`，若 `repayAmount = type(uint).max` 且成功，则 `borrowBalanceStored == 0`。
- 数学表达
  - $borrowBalanceStored(u) \ge 0$
  - `repayBorrow(max)` success $\Rightarrow borrowBalanceStored(u)=0$
- 适合在哪些handler动作后检查
  - `repayBorrow`、`repayBorrowBehalf` 后。
- 可能出现误报的情况
  - fee-on-transfer 底层资产导致实际还款额小于输入额。

### A4. 账户 mToken 余额与总供应边界
- invariant描述
  - 任一账户 mToken 余额不应超过市场总供应。
- 数学表达
  - $accountTokens[u] \le totalSupply$
- 适合在哪些handler动作后检查
  - `mint`、`redeem`、`transfer`、`seize` 后。
- 可能出现误报的情况
  - 使用错误市场地址读取了不匹配的总供应。

### A5. 借款前后流动性方向合理
- invariant描述
  - 在价格不变前提下，成功 borrow 后账户 shortfall 不应降低为更安全方向（通常更差或不变）。
- 数学表达
  - 固定 oracle 情况下：$shortfall_{after} \ge shortfall_{before}$ 且 $liquidity_{after} \le liquidity_{before}$
- 适合在哪些handler动作后检查
  - `borrow` 后。
- 可能出现误报的情况
  - 同交易中同时发生 supply/价格变动，打破“价格不变”前提。

---

## 3. 会计不变量

### C1. 核心资产恒等式（近似）
- invariant描述
  - 市场资产关系应满足：底层现金 + 总借款 - 总储备 与 share side 对应。
- 数学表达
  - $exchangeRateStored \approx \dfrac{cash + totalBorrows - totalReserves}{totalSupply}$（当 `totalSupply>0`）
- 适合在哪些handler动作后检查
  - `mint`、`redeem`、`borrow`、`repay`、`liquidate`、`_addReserves`、`_reduceReserves` 后。
- 可能出现误报的情况
  - 舍入误差、直接向 mToken 合约捐赠底层资产、rebasing token。

### C2. 清算扣押拆分守恒
- invariant描述
  - 清算扣押的 token 由“清算人份额 + 协议份额”构成。
- 数学表达
  - $seizeTokens = liquidatorSeizeTokens + protocolSeizeTokens$
- 适合在哪些handler动作后检查
  - `liquidateBorrow` 成功后。
- 可能出现误报的情况
  - 测试未捕获内部事件字段，只能近似推导。

### C3. 协议储备在清算中的增量关系
- invariant描述
  - 清算时协议份额应折算为底层并增加 `totalReserves`。
- 数学表达
  - $\Delta totalReserves \approx protocolSeizeTokens \times exchangeRateStored$
- 适合在哪些handler动作后检查
  - `liquidateBorrow` 成功后。
- 可能出现误报的情况
  - 同步发生利息累计导致 `totalReserves` 额外增长。

### C4. 非 reduce 路径下储备不应下降
- invariant描述
  - 除 `_reduceReserves` 外，`totalReserves` 不应减少。
- 数学表达
  - 若动作 $\notin \{_reduceReserves\}$，则 $totalReserves_{after} \ge totalReserves_{before}$
- 适合在哪些handler动作后检查
  - 所有用户动作、`accrueInterest`、`_addReserves`、清算后。
- 可能出现误报的情况
  - handler 把 `_reduceReserves` 封装在复合动作里但未标记。

### C5. 借款总量与账户债务方向一致
- invariant描述
  - borrow 成功应使 `totalBorrows` 增，repay 成功应使其减（在无并发动作下）。
- 数学表达
  - borrow success $\Rightarrow totalBorrows_{after} > totalBorrows_{before}$
  - repay success $\Rightarrow totalBorrows_{after} < totalBorrows_{before}$（除极小值/0）
- 适合在哪些handler动作后检查
  - `borrow`、`repayBorrow`、`repayBorrowBehalf` 后。
- 可能出现误报的情况
  - 同交易内触发 `accrueInterest` 带来额外增长，掩盖净变化。

### C6. 总供应与账户余额边界一致
- invariant描述
  - mint 增发总供应，redeem/协议扣押销毁应减少总供应。
- 数学表达
  - mint success: $\Delta totalSupply > 0$
  - redeem success: $\Delta totalSupply < 0$
  - seize 含协议份额时: $\Delta totalSupply = -protocolSeizeTokens$
- 适合在哪些handler动作后检查
  - `mint`、`redeem`、`liquidateBorrow` 后。
- 可能出现误报的情况
  - 组合动作里前后多次 mint/redeem 抵消。

---

## 4. 权限不变量

### P1. Comptroller 管理参数仅 admin 可变
- invariant描述
  - 非 admin 调用参数治理函数应失败或状态不变。
- 数学表达
  - caller `!= admin` 时：
    - `_setPriceOracle/_setCloseFactor/_setCollateralFactor/_setLiquidationIncentive/_supportMarket/_setRewardDistributor` 不得生效。
- 适合在哪些handler动作后检查
  - 全部治理 handler 后。
- 可能出现误报的情况
  - 使用 Unitroller 代理时 admin 地址读取来源错误。

### P2. cap guardian 权限边界
- invariant描述
  - 借款/供应 cap 只能由 admin 或对应 guardian 设置。
- 数学表达
  - caller $\notin \{admin, borrowCapGuardian\}$ 时 `_setMarketBorrowCaps` 不生效。
  - caller $\notin \{admin, supplyCapGuardian\}$ 时 `_setMarketSupplyCaps` 不生效。
- 适合在哪些handler动作后检查
  - cap 变更 handler 后。
- 可能出现误报的情况
  - 多链 fork 中 guardian 地址读取错链。

### P3. pause guardian 不能单独恢复
- invariant描述
  - guardian 可 pause，unpause 必须 admin。
- 数学表达
  - caller `== pauseGuardian` 且 `state=false` 时，`_set*Paused` 必须失败。
- 适合在哪些handler动作后检查
  - pause/unpause handler 后。
- 可能出现误报的情况
  - 测试中 pauseGuardian 与 admin 设置成同一地址。

### P4. MToken 管理函数仅市场 admin
- invariant描述
  - 非市场 admin 不能更改 comptroller、利率模型、reserve factor、protocol seize share、reduce reserves。
- 数学表达
  - caller `!= mToken.admin` 时相关函数状态不变或失败。
- 适合在哪些handler动作后检查
  - mToken 管理 handler 后。
- 可能出现误报的情况
  - 使用 Delegator 时 admin 槽位初始化不正确导致读值偏差。

### P5. 代理升级权限仅 delegator admin / unitroller admin
- invariant描述
  - 非 admin 不可升级实现。
- 数学表达
  - caller `!= admin` 时：`MErc20Delegator._setImplementation` / `Unitroller._setPendingImplementation` 不生效。
- 适合在哪些handler动作后检查
  - 升级相关 handler 后。
- 可能出现误报的情况
  - 测试脚本错误地直接调用 implementation 合约而非 proxy。

### P6. 奖励配置 owner 权限边界
- invariant描述
  - 非 config owner 且非 comptroller admin 不可修改该配置速度/owner/endTime。
- 数学表达
  - caller $\notin \{config.owner, comptroller.admin\}$ 时 `_updateSupplySpeed/_updateBorrowSpeed/_updateOwner/_updateEndTime` 不生效。
- 适合在哪些handler动作后检查
  - 奖励配置更新 handler 后。
- 可能出现误报的情况
  - 读取配置索引错误，检查了错误 emissionToken 对。

---

## 5. 赎回/清算后应满足的不变量

### R1. 赎回后账户与总供应同步下降
- invariant描述
  - 赎回成功后，用户 mToken 余额和总供应按赎回份额减少。
- 数学表达
  - redeem token 模式：$\Delta accountTokens_u = -redeemTokens$，$\Delta totalSupply = -redeemTokens$
- 适合在哪些handler动作后检查
  - `redeem`、`redeemUnderlying` 后。
- 可能出现误报的情况
  - `redeemUnderlying` 路径中 redeemTokens 由汇率换算并截断，需容忍舍入。

### R2. 赎回后现金充足性未被破坏
- invariant描述
  - 成功赎回意味着执行前现金充足；执行后 `cash` 不应为负语义（EVM 下体现为不下溢）。
- 数学表达
  - redeem success 前提：$cash_{before} \ge redeemAmount$
- 适合在哪些handler动作后检查
  - `redeem`、`redeemUnderlying` 后。
- 可能出现误报的情况
  - 对 ETH/WETH 路径 cash 读取口径不一致。

### R3. 清算后借款人债务下降
- invariant描述
  - 清算成功后借款人借款余额应下降（至少不增加）。
- 数学表达
  - liquidate success $\Rightarrow borrowBalance_{after}(borrower) < borrowBalance_{before}(borrower)$
- 适合在哪些handler动作后检查
  - `liquidateBorrow` 后。
- 可能出现误报的情况
  - 同交易触发额外利息累计，极端情况下净值接近不变（需比较“先计息再清算”的同口径值）。

### R4. 清算后抵押转移方向正确
- invariant描述
  - 借款人抵押 mToken 减少，清算人抵押 mToken 增加（协议份额除外）。
- 数学表达
  - $\Delta accountTokens_{borrower} = -seizeTokens$
  - $\Delta accountTokens_{liquidator} = +liquidatorSeizeTokens$
- 适合在哪些handler动作后检查
  - `liquidateBorrow` 后。
- 可能出现误报的情况
  - 若清算人与借款人为同地址，交易应直接失败；不要在失败路径上断言余额变化。

### R5. 清算 close factor 约束不可被绕过
- invariant描述
  - 单次清算偿还额不得超过允许上限。
- 数学表达
  - $repayAmount \le closeFactor \times borrowBalanceStored(borrower)$（在 `liquidateBorrowAllowed` 检查口径下）
- 适合在哪些handler动作后检查
  - `liquidateBorrow` 前后（前置期望失败/成功断言）。
- 可能出现误报的情况
  - 使用的是 stale borrowBalance 口径而非 allowed 内部口径。

---

## 6. 与 share price / utilization / debt index 相关的不变量

### S1. share price 为正
- invariant描述
  - 当市场存在总供应时，exchange rate 必须大于 0。
- 数学表达
  - $totalSupply > 0 \Rightarrow exchangeRateStored > 0$
- 适合在哪些handler动作后检查
  - `mint`、`redeem`、`borrow`、`repay`、`accrueInterest` 后。
- 可能出现误报的情况
  - 非标准底层 token 导致 getCash 口径异常。

### S2. 初始阶段 share price 下界
- invariant描述
  - 市场初始化后，exchange rate 不应低于 `initialExchangeRateMantissa` 的可接受误差下界。
- 数学表达
  - $exchangeRateStored \gtrsim initialExchangeRateMantissa - \epsilon$
- 适合在哪些handler动作后检查
  - 市场初始化、早期 mint/redeem 后。
- 可能出现误报的情况
  - 大额坏账/非常规资产注入导致 share price 下行（需结合业务是否允许）。

### S3. utilization 边界
- invariant描述
  - 利用率应在 [0,1] 区间（分母为正时）。
- 数学表达
  - $U = \dfrac{totalBorrows}{cash + totalBorrows - totalReserves}$
  - 若分母 $>0$，则 $0 \le U \le 1$
- 适合在哪些handler动作后检查
  - `borrow`、`repay`、`redeem`、`liquidate`、`accrueInterest` 后。
- 可能出现误报的情况
  - 会计被外部直接注入/抽走底层资产，导致分母口径与协议预期偏离。

### S4. borrowIndex 单调不减
- invariant描述
  - 借款指数随时间推进应单调不减。
- 数学表达
  - $borrowIndex_{t+1} \ge borrowIndex_t$
- 适合在哪些handler动作后检查
  - `accrueInterest`，以及会触发其调用的所有用户动作后。
- 可能出现误报的情况
  - 测试中修改时间戳到过去或直接改 storage。

### S5. 纯计息动作下现金不变
- invariant描述
  - 仅执行 `accrueInterest` 时，不应直接转移底层现金。
- 数学表达
  - pure accrue 场景：$cash_{after} = cash_{before}$
- 适合在哪些handler动作后检查
  - 独立 `accrueInterest` handler 后。
- 可能出现误报的情况
  - 底层资产为 rebasing/fee token，余额会自发变化。

### S6. 债务索引映射关系
- invariant描述
  - 用户债务应与其 `principal` 和 `interestIndex` 按比例对应（考虑截断）。
- 数学表达
  - $borrowBalanceStored(u) \approx principal_u \times \dfrac{borrowIndex}{interestIndex_u}$
- 适合在哪些handler动作后检查
  - `borrow`、`repay`、`accrueInterest`、`liquidate` 后。
- 可能出现误报的情况
  - 舍入截断、用户 `interestIndex=0`（未借款）分支未特殊处理。

---

## 建议落地方式

1. 先做“强不变量”
- P 类权限不变量、G1/G3、R1/R3/R4、S4。

2. 再做“近似不变量”
- C1/C3/S2/S6（统一设置容差 epsilon）。

3. handler 组合优先级
- `mint -> enter -> borrow -> warp -> repay -> redeem`
- `mint -> enter -> borrow -> warp -> liquidate`
- `pause/unpause + claimReward`
- `governance parameter updates + user actions`

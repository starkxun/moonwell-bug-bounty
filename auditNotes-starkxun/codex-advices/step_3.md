# Step 3 - Moonwell式借贷协议风险会计测试缺口清单

> **这份清单干什么用？**
> “会计漏洞”是借贷协议最隐蔽的一类风险——用户操作看起来成功了，但合约内部的账本悄悄偏离了真实值，最终在赎回或清算时爆发。这份清单只聚焦“带利息累计 + 奖励分配”的会计风险，帮你补上这类测试缺口。

---

## 测试基建约定（先搭好这套基础，后面的测试写起来快很多）

**角色：**
- `alice`：借款 / 供给主角
- `bob`：对手方 / 清算者
- `carol`：第三方还款者

**关键状态快照字段（在每个测试前后都抓一份）：**
```solidity
struct MarketSnap {
    uint256 cash;              // 合约持有的底层资产余额
    uint256 totalBorrows;      // 全部待还借款（含利息）
    uint256 totalReserves;     // 协议储备金（从利息中抽取）
    uint256 totalSupply;       // 流通中的 mToken 总量
    uint256 borrowIndex;       // 借款累积利息指数（单调递增）
    uint256 exchangeRate;      // 1 mToken 对应多少底层资产
    uint256 rewardSupplyIndex; // 供给侧奖励累积指数
    uint256 rewardBorrowIndex; // 借款侧奖励累积指数
}
```

**统一后置检查函数（每个测试结尾都调用）：**
```solidity
assertMarketAccounting(mToken);          // 会计恒等式
assertUserDebtConsistency(user, mToken); // 用户债务与全局一致
assertRewardAccounting(user, mToken, emissionToken); // 奖励守恒
```

---

## [P0] 1) 利率指数会计（Interest Index Accounting）

> **通俗理解：** `borrowIndex` 就像一张“累积利息凭条”，时间过去越多，上面的数字应该越大，绝不能变小，也不能在同一时刻更新两次。

### 应始终成立的不变量
- `borrowIndex` 单调不减（永远只涨不跌）。
- 当 `timeDelta > 0` 且 `totalBorrows > 0` 时，`borrowIndex` 严格增加。
- 当 `timeDelta = 0` 时，重复调用 `accrueInterest` 不应改变 `borrowIndex`（幂等性）。

### 如何被违反
- `accrueInterest` 内的时间差处理错误（同块重复计息或漏计息）。
- 高 utilization 或治理参数突变时，指数更新公式出现精度/顺序错误。

### 建议测试（模糊/不变）
- `testFuzzBorrowIndexMonotonicity(uint40 dt, uint256 utilSeed)` — 随机时间差，验证指数只涨不跌
- `invariant_borrowIndexNeverDecreases()` — 长序列不变量测试
- 分支：同块连续触发 `accrueInterest` 两次

### 关键断言
```solidity
assertGe(borrowIndexAfter, borrowIndexBefore);           // 永不降低
if (dt == 0) assertEq(borrowIndexAfter, borrowIndexBefore); // 同块幂等
if (dt > 0 && totalBorrows > 0)
    assertGt(borrowIndexAfter, borrowIndexBefore);       // 有借款时严格递增
```

### 新手 invariant 模板
```solidity
// test/invariants/BorrowIndexInvariant.t.sol
contract BorrowIndexInvariant is Test {
    MToken mToken;
    uint256 lastBorrowIndex;

    function setUp() public {
        // ... 初始化市场 ...
        lastBorrowIndex = mToken.borrowIndex();
    }

    function invariant_borrowIndexNeverDecreases() public {
        uint256 current = mToken.borrowIndex();
        assertGe(current, lastBorrowIndex, "borrow index decreased!");
        lastBorrowIndex = current;
    }
}
```

---

## [P0] 2) 借用指数/供给指数一致性（Borrow vs Supply Index Coherence）
### 应始终成立的不变量
- 供给端价值增长与借款端利息增长在“准备金抽成后”保持可解释关系。
- exchangeRate 变化应与 cash、borrows、reserves 的变动一致。

### 如何被违反
- 计息顺序错误：先更新 exchangeRate 后更新 reserves（或反之）导致错位。
- utilization 极端时，borrow 侧增长没有正确传导到 supply 侧。

### 建议测试
- fuzz: testFuzzSupplyBorrowIndexCoherence(uint40 dt, uint256 borrowAmt)
- invariant: invariant_exchangeRateMatchesBalanceSheet()

### 关键断言
- 近似断言：exchangeRate ~= (cash + borrows - reserves) / totalSupply（容差 epsilon）
- 在无外部注资/抽资时，系统净值变化只能来自利息与费用项

---

## [P0] 3) 奖励指数更新正确性（Reward Index Correctness）

> **通俗理解：** 奖励应该“先结算旧账，再更新仓位”。如果顺序反了（先更新仓位再结算），就会出现“幽灵奖励”——用户凭空多领了本不属于他的奖励。

### 应始终成立的不变量
- 每个 `emissionToken`：`user.totalReward == supplySide + borrowSide`（奖励总量守恒）。
- 全局奖励索引仅在有效时间窗内推进（`endTime` 后不继续累计）。
- 同块重复 `claim/update` 不应双计（幂等性）。

### 如何被违反
- `updateMarketSupplyIndex` / `updateMarketBorrowIndex` 调用顺序写错。
- 先修改用户仓位，再结算旧索引，导致新仓位享受了旧时间段的奖励（幽灵奖励）。

### 建议测试
- `testFuzzRewardIndexUpdateOrdering(uint40 dt, uint8 actionOrder)` — 随机操作顺序
- `invariant_rewardTotalEqualsSides()` — 长序列守恒
- 分支：`mint→borrow→repay→liquidate→claim` 混合路径

### 关键断言
```solidity
// 对每个 emissionToken 验证
assertEq(totalAmount, supplySide + borrowSide, "reward total mismatch");
// endTime 后不再增加
if (block.timestamp > endTime)
    assertEq(deltaReward, 0, "reward after endTime");
// 同块重复 claim 无额外增量
assertEq(rewardAfterSecondClaim, rewardAfterFirstClaim);
```

### 关键顺序规则（新手必读）
```
正确顺序：先 updateIndex（结算旧奖励）→ 再 updateBalance（修改仓位）
错误顺序：先 updateBalance（修改仓位）→ 再 updateIndex（结算时用了新仓位）
```

---

## [P1] 4) 反复操作中的四舍五入累积（Rounding Accumulation）
### 应始终成立的不变量
- 单步舍入误差有界，且长期累积不出现单向可提取价值。
- 用户债务不会因反复微量 repay 出现“永远还不清”的异常尘埃。

### 如何被违反
- mint/redeem、repay/borrow、liquidation seize 的舍入方向不一致。
- 多次小额操作把误差累积成可观价值偏移。

### 建议测试
- fuzz: testFuzzRoundingAccumulationLoop(uint16 n, uint256 dust)
- invariant: invariant_roundingDriftBounded()

### 关键断言
- 循环 n 次后：总偏差 <= 预设上限（如 n * 1 wei 量级）
- 最终 full repay 后 borrowBalance 在协议容忍阈值内归零

---

## [P0] 5) 用户余额与协议总额不同步（User vs Global Accounting Desync）
### 应始终成立的不变量
- 全体用户的借款变动总和与 totalBorrows 变动一致（考虑计息项）。
- 全体用户 mToken 余额总和与 totalSupply 一致。

### 如何被违反
- 某些路径（repayBehalf、liquidate、transfer）更新了用户侧但漏更新全局侧。
- 失败路径回滚不完整，残留部分状态。

### 建议测试
- fuzz: testFuzzGlobalUserSyncAcrossMixedActions(uint8 seqLen)
- invariant: invariant_userGlobalTotalsStayConsistent()

### 关键断言
- Σ userMTokenBalance == totalSupply
- 操作失败前后：关键状态完全相等（snapshot compare）
- 债务总量变化与事件/索引变化可对账

---

## [P1] 6) 过时缓存值（Stale Cached Values）
### 应始终成立的不变量
- 所有风险判断使用的索引/汇率是“当前应计后”值或与设计一致的 stored 值语义。
- 在关键状态转换前（borrow/redeem/liquidate）不会用陈旧缓存绕过风控。

### 如何被违反
- getAccountLiquidity 或清算资格计算依赖过时 exchangeRate/borrowBalance。
- 先读取缓存再执行多步状态变化，最终使用旧值决策。

### 建议测试
- 分支：testBorrowUsesFreshAccrualState()
- fuzz: testFuzzStaleReadThenStateChange(uint40 dt, uint8 actionGap)
- invariant: invariant_noRiskCheckOnStaleState()

### 关键断言
- 显式 accrue 与隐式 accrue 两条路径最终结果一致（容差内）
- 临界账户在价格/时间变化后，借款与赎回放行结论正确

---

## [P1] 7) 股份转资产边缘情况（Share-to-Asset Edge Cases）
### 应始终成立的不变量
- convertToAssets(convertToShares(x)) 在容差内保持一致（考虑舍入方向）。
- 当 totalSupply 极小或 exchangeRate 极端时，不出现 0-share/0-asset 黑洞。

### 如何被违反
- 小数精度处理导致小额存入铸造 0 shares。
- 大汇率下 redeem 反向换算损失超预期。

### 建议测试
- fuzz: testFuzzShareAssetConversionExtremes(uint256 amount, uint256 rateSeed)
- invariant: invariant_shareAssetConversionBoundedError()

### 关键断言
- amount>0 时，若设计允许则 shares>0；若不允许应明确 revert
- 往返转换误差 <= 设计容差

---

## [P0] 8) 债务随时间增长（Debt Growth Over Time）
### 应始终成立的不变量
- 债务在正利率下随时间非递减（无还款前提）。
- 借款人份额债务增长与 borrowIndex 增长方向一致。

### 如何被违反
- 债务快照与指数映射错误，导致时间后 debt 反降。
- repay/borrow 混合后 debtStored 与实时 debt 不一致。

### 建议测试
- fuzz: testFuzzDebtGrowthMonotonicity(uint40 dt1, uint40 dt2)
- invariant: invariant_debtNonDecreasingWithoutRepay()

### 关键断言
- 无还款区间内 assertGe(debtAfter, debtBefore)
- debt 增量与 borrowIndex 比例关系近似一致

---

## [P1] 9) 准备金要素/费用会计（Reserve Factor / Fee Accounting）
### 应始终成立的不变量
- totalReserves 仅按 reserveFactor 从利息中抽取，不应凭空增减。
- reserveFactor 变更后仅影响后续利息，不重写历史累计。

### 如何被违反
- reserveFactor 应用区间错（跨时间段被整段按新参数重算）。
- 费用提取路径重复计入或漏计入 reserves。

### 建议测试
- 分支：testReserveFactorChangeAppliesForwardOnly()
- fuzz: testFuzzReserveAccountingAcrossRateChanges(uint40 dt, uint256 rf)
- invariant: invariant_reserveGrowthExplainedByInterest()

### 关键断言
- totalReservesAfter - totalReservesBefore ~= interestAccrued * reserveFactor（分段计算）
- 参数变更前后分段对账成立

---

## [P0] 10) 清算激励会计（Liquidation Incentive Accounting）
### 应始终成立的不变量
- 被扣抵押总额 = 清算人所得 + 协议分成（seize share）
- 借款减少量、抵押扣减量、奖励结算量三者方向一致且可对账。

### 如何被违反
- seizeTokens 舍入/比例处理错导致“凭空多扣或少扣”。
- liquidator 与 protocol 份额拆分与 incentive 参数不一致。

### 建议测试
- fuzz: testFuzzLiquidationSplitConservation(uint256 repayAmt)
- invariant: invariant_liquidationValueConservation()
- 边界：shortfall 刚过阈值与 closeFactor 临界。

### 关键断言
- collateralSeized == liquidatorPart + protocolPart（容差内）
- borrower debt 下降；shortfall 不上升（理想应下降）
- 清算失败路径不应改变任何账户状态

---

## [P1] 11) 坏账处理假设（Bad Debt Handling Assumptions）
### 应始终成立的不变量
- 出现资不抵债后，系统不会把坏账“隐形转移”为正常资产收益。
- 清算后若仍有残余坏账，其表示与后续处理路径一致且可追踪。

### 如何被违反
- 极端价格冲击后，借款人债务未被正确标记/反映到全局会计。
- 坏账场景下奖励仍按正常借款持续发放，造成额外泄漏。

### 建议测试
- 场景分支：testBadDebtAfterSeverePriceShock()
- fuzz: testFuzzBadDebtResidualAccounting(uint256 shockBps, uint40 dt)
- invariant: invariant_badDebtDoesNotCreatePhantomAssets()

### 关键断言
- 资不抵债账户：shortfall > 0 且其后续行为符合限制（借款/赎回拒绝）
- 全局账本不因坏账场景出现“净资产虚增”
- 奖励发放在坏账状态下符合协议定义（继续/暂停必须可验证）

---

## 建议优先实现顺序（按风险）
1. 利率指数会计、借供指数一致性、用户-全局同步、清算激励会计（P0）。
2. 奖励指数正确性、债务随时间增长、过时缓存值（P0/P1）。
3. 准备金会计、舍入累积、股份转资产边缘、坏账处理（P1）。

## Foundry 编写提示（最小落地模板）
- 命名规范：testFuzz_* 用于参数扰动，invariant_* 用于全局守恒。
- 每个测试结束统一执行：
  - assertMarketAccounting(mToken)
  - assertUserDebtConsistency(alice, mToken)
  - assertRewardAccounting(alice, mToken, emissionToken)
- 对关键路径增加 snapshot 前后对比，确保失败路径“零状态污染”。

---

## 补充：会计类缺口的最低成本验证顺序

### 第一层（手推）
- 先把每个 P0 主题写成公式与不变量：
  - borrowIndex 单调
  - exchangeRate 资产负债恒等式
  - liquidation 拆分守恒
  - totalReward = supplySide + borrowSide
- 每条公式配最小反例：dt=0、dt>0、极小金额、临界 close factor。

### 第二层（unit + mock）
- 会计类几乎都能先脱离 fork：
  - 利率模型参数、oracle、reward distributor 全部 mock。
  - 用确定性时间推进验证分段会计（参数变更前后）。
- 目标：先把 P0 的“等式是否成立”在本地跑稳定。

### 第三层（invariant）
- 将已验证公式提升为长序列不变量：
  - user/global 同步
  - 债务随时间单调
  - reserve 增长可解释
- 建议把动作按阶段放开，先 borrow/repay，再加 liquidation/claim。

### 第四层（fork fuzz）
- 只验证 mock 难以覆盖的“真实参数组合”：
  - 多市场真实配置、真实奖励计划、真实治理后状态
- 用于发现环境耦合问题，不用于替代基础公式验证。

### 一句话准则
- **会计问题优先“公式先行”**：手推和 unit 能证明 80% 风险，fork 只验证剩下 20% 真实环境耦合。
- **快速自测：** 如果你对某个公式或不变量“说不清楚为什么成立”，那就是最值得先补的测试。

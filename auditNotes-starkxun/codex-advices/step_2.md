# Step 2 - 贷款协议对抗性与边缘覆盖检查表（Foundry）

目标：补齐当前偏快乐路径的测试缺口。每个条目都给出可直接转成 Foundry 用例的结构。

建议约定（便于统一实现）
- 角色：alice（供应者/借款者）、bob（对手方/清算者）、carol（第三方还款者）。
- 通用断言函数：
  - assertAccountLiquidityInvariant(user)
  - assertMarketAccountingInvariant(mToken)
  - assertRewardConservation(user, mToken)
- 时间控制：同块不 warp；跨时间用 vm.warp(block.timestamp + dt)。
- 允许误差：涉及除法的断言使用绝对误差或相对误差（如 1~2 wei 或 1e-12 比例）。

---

## [ ] 1. 边界值（Boundary Values）
- 盲点：只测中间值时，常漏掉 min/max 边缘分支（例如 closeFactor 上限、cap 边界、可借额度边界）。
- 用户串行：
  1) alice 供应抵押并 enter market。
  2) 计算 maxBorrow，分别尝试 maxBorrow-1、maxBorrow、maxBorrow+1 借款。
  3) 在 cap 临界位重复 mint/borrow。
- 建议测试名：
  - testBorrowAtLiquidityBoundary()
  - testMintAtSupplyCapBoundary()
  - testRepayAtCloseFactorBoundary()
- 预期断言：
  - 边界内成功，边界外失败（错误码/自定义错误符合预期）。
  - 成功路径后账户 liquidity >= 0；失败路径状态完全不变。

## [ ] 2. 零金额（Zero Amount）
- 盲点：0 金额调用可能错误成功、错误扣奖励、或破坏索引更新顺序。
- 用户串行：
  1) alice 已有仓位。
  2) 调用 mint(0)、borrow(0)、repayBorrow(0)、redeem(0)、liquidateBorrow(...,0,...).
- 建议测试名：
  - testZeroAmountActionsRevertOrNoopConsistently()
- 预期断言：
  - 要么统一 revert，要么统一 no-op（按协议设计）。
  - 无论哪种，totalBorrows、totalSupply、user balance、reward index 不应漂移。

## [ ] 3. 微量尘埃（Dust）
- 盲点：最小单位金额在 exchangeRate/borrowIndex 缩放后容易被截断，形成“还不清/提不尽”的残留。
- 用户串行：
  1) alice 借款后多次 repay 极小金额（1 wei, 2 wei, 3 wei）。
  2) 最后尝试 full repay。
  3) 赎回时用最小 redeemTokens 重复操作直到接近 0。
- 建议测试名：
  - testDustRepayDoesNotCreateUnpayableDebt()
  - testDustRedeemConvergesWithoutStateCorruption()
- 预期断言：
  - 最终 borrowBalance 可归零（或在协议定义尘埃阈值内可被一次性清理）。
  - 不出现负债反弹、奖励异常跳变、总账本不守恒。

## [ ] 4. 最大 UINT / 接近极限值
- 盲点：虽然 Solidity 0.8 防溢出，但业务逻辑可能在乘除缩放、指数累计时触发非预期 revert 或精度塌陷。
- 用户串行：
  1) 用 type(uint256).max、max-1、max/2 输入到可达路径（通过 bound 到协议上限附近）。
  2) 在高 utilization 下触发 accrue + borrow/repay。
- 建议测试名：
  - testNearUintMaxInputsBoundedCorrectly()
  - testAccrualWithLargeStateValues()
- 预期断言：
  - 仅在设计上应失败的地方失败；不会出现 silent wrap 或错误成功。
  - 失败前后状态一致；成功路径索引单调、会计恒等式成立。

## [ ] 5. 同一块内重复操作（Same-Block Repetition）
- 盲点：依赖 block.timestamp 的索引更新在同块 delta=0，可能出现重复领收益、重复计息或漏计。
- 用户串行：
  1) alice 在同一块连续 mint -> borrow -> repay -> claimReward（不 warp）。
  2) 重复第二轮相同操作。
- 建议测试名：
  - testRepeatedActionsInSameBlockIdempotence()
  - testSameBlockRewardIndexNoDoubleCount()
- 预期断言：
  - 同块重复不会额外产生利息或奖励（除非设计明确允许）。
  - 第二轮与第一轮对关键状态增量一致或为 0（按预期）。

## [ ] 6. 长时间间隔后的行动（Long Idle Gap）
- 盲点：长时间无交互后首次操作承担大量 accrue，易暴露溢出、极端舍入、奖励截止处理错误。
- 用户串行：
  1) alice 建仓后 idle 30/90/180 天。
  2) 首次执行 borrow 或 repay 或 redeem。
  3) 之后立刻 claimReward。
- 建议测试名：
  - testFirstActionAfterLongIdleAccruesSafely()
  - testRewardEndTimeAfterLongWarp()
- 预期断言：
  - borrowIndex 单调上升，无异常回退。
  - reward 在 endTime 后不再继续累计；endTime 前累计量与时长一致。

## [ ] 7. 用户之间排序依赖（Ordering Dependency）
- 盲点：A 先操作与 B 后操作可能拿到不公平份额（尤其奖励与清算先后顺序）。
- 用户串行：
  1) alice 与 bob 在相同初始状态下，交换操作顺序（A先/B后 与 B先/A后）。
  2) 比较两条路径的最终分配。
- 建议测试名：
  - testUserOrderingDoesNotLeakValue()
  - testBorrowerLiquidatorOrderingFairness()
- 预期断言：
  - 除去可解释的时间差，最终价值分配差异在容差内。
  - 不存在通过抢先顺序稳定获利的异常路径。

## [ ] 8. 部分还款/部分借款/部分提取顺序
- 盲点：同样净头寸，不同操作顺序可能触发不同的风险检查与索引结算，导致状态分叉。
- 用户串行：
  1) 路径 A：borrow x -> repay y -> redeem z。
  2) 路径 B：borrow x -> redeem z -> repay y。
  3) 路径 C：repay y -> borrow x -> redeem z（从等价初始状态开始）。
- 建议测试名：
  - testPartialActionOrderEquivalence()
  - testPartialRepayThenRedeemRiskGate()
- 预期断言：
  - 可达且合法的顺序下，最终债务/抵押/奖励应一致或可解释差异。
  - 非法顺序必须被风控拒绝，且拒绝不污染状态。

## [ ] 9. 利息累计后状态变化（Post-Accrual Transition）
- 盲点：很多测试在操作前后未强制 accrue，导致“存储值 vs 实时值”不一致问题被掩盖。
- 用户串行：
  1) alice 借款。
  2) warp 一段时间。
  3) 分别走两条路：先 accrue 再 repay；直接 repay 让函数内部触发 accrue。
- 建议测试名：
  - testExplicitVsImplicitAccrualConsistency()
  - testAccrueThenLiquidateStateTransition()
- 预期断言：
  - 两条路径在最终债务、储备金、索引、奖励上应一致（容差内）。
  - 不应出现“先手触发 accrue”可套利差异。

## [ ] 10. 四舍五入方向问题（Rounding Direction）
- 盲点：借贷协议常在 mint/redeem、borrow/repay、liquidate seize 三处出现方向不一致，长期会系统性偏向某一方。
- 用户串行：
  1) 构造 exchangeRate 与 borrowIndex 为非整除比例。
  2) 进行最小单位重复 mint/redeem、repay/liquidate。
  3) 统计累积误差方向。
- 建议测试名：
  - testRoundingBiasMintRedeem()
  - testRoundingBiasRepayLiquidate()
- 预期断言：
  - 单步误差在设计容差内，且长期误差不出现单边可提取价值。
  - 会计守恒：系统总资产变化可由利息/费用解释。

## [ ] 11. 奖励指数漂移（Reward Index Drift）
- 盲点：多 token 奖励、供应借款双边奖励下，索引更新顺序容易错，出现 totalAmount 与分项不一致。
- 用户串行：
  1) alice 供应并借款，bob 仅供应。
  2) 中途部分还款、清算、再次借款。
  3) 两人分别 claim。
- 建议测试名：
  - testRewardIndexDriftAcrossMixedActions()
  - testRewardTotalEqualsSupplyPlusBorrowSides()
- 预期断言：
  - 对每个 emission token：totalAmount == supplySide + borrowSide。
  - 用户间奖励增量与份额变化方向一致，不出现负增量或跨用户串账。

## [ ] 12. 行动间担保价值变化（Collateral Value Changes Between Actions）
- 盲点：现实里价格在用户多步操作间变化；若只测静态价格，会漏掉临界健康度翻转问题。
- 用户串行：
  1) alice 供应抵押并借款到接近上限。
  2) 模拟价格下跌（或 collateral factor 下调）。
  3) alice 再尝试 borrow/redeem，bob 尝试 liquidate。
- 建议测试名：
  - testBorrowAndRedeemAfterCollateralShock()
  - testLiquidationEligibilityAfterPriceMove()
- 预期断言：
  - 价格冲击后 borrow/redeem 被正确拒绝；liquidation 在 shortfall>0 时被放行。
  - 清算后 shortfall 下降，账户向安全区收敛。

---

## Foundry 实施建议（便于快速落地）
- 用表驱动参数化：amount、warpDelta、priceShock、actionOrder。
- 对每个 checklist 条目至少实现一个确定性测试 + 一个 fuzz 版本。
- 在 fuzz 中加入状态快照前后比对：
  - market 级：cash、totalBorrows、totalReserves、borrowIndex、exchangeRate。
  - user 级：mToken balance、borrow balance、liquidity/shortfall、outstanding rewards。
- 增加统一后置断言（每个测试结尾调用）：
  - assertMarketAccountingInvariant(mToken)
  - assertAccountLiquidityInvariant(alice/bob)
  - assertRewardConservation(alice/bob, mToken)

## 建议优先补测顺序
1. 同一块重复操作 + 奖励指数漂移（高概率抓到隐藏计数问题）。
2. 部分操作顺序 + 担保价值变化（高业务风险）。
3. 清算/还款舍入方向 + 尘埃（高经济敏感）。
4. 长时间 idle + 近极值输入（稳定性与抗脆弱性）。

---

## 补充：本清单的分层实施建议

### 先做手推/反例
- 条目 1/2/3/10：先写边界表（0、1、max-1、max、max+1）。
- 条目 5/6：先明确同块与跨块的理论增量应为多少。
- 条目 8/9：先定义“顺序等价”允许的误差范围。

### 再做 unit + mock
- 条目 2/3/4/10/11：完全适合无 fork 单元测试。
- 条目 12：价格变化用 mock oracle 控制，不必先上 fork。
- 目标：把每个条目至少落地 1 个确定性用例 + 1 个轻量 fuzz。

### 然后做 invariant
- 把条目 5/9/11 汇总为全局不变量（同块幂等、会计守恒、奖励守恒）。
- 初期限制 handler 动作集合，避免无关噪声拖慢执行。

### 最后做 fork fuzz
- 只把条目 7/12 这类强依赖真实市场状态的场景放到 fork。
- 先小参数冒烟，再夜间大参数回归。

### 条目到测试类型速查
- 手推优先：1, 2, 3, 4, 10
- unit+mock 优先：2, 3, 4, 8, 9, 10, 11, 12
- invariant 优先：5, 9, 11
- fork fuzz 兜底：7, 12

# Step 4 - 借贷协议状态机审计视角测试缺口

目标：把 Moonwell 式借贷市场建模为状态机，聚焦“危险过渡”而不是快乐路径。

## 1) 状态机骨架

### 账户状态（按风险语义分层）
- S0 无仓位：无供给、无借款、未入市。
- S1 仅供给未入市：持有 mToken 但未作为抵押启用。
- S2 供给且已入市：抵押已启用，可借。
- S3 已借款且健康：shortfall=0，liquidity>=0。
- S4 临界健康：接近清算阈值（liquidity≈0）。
- S5 可清算：shortfall>0。
- S6 部分清算后：债务下降但可能仍接近阈值。
- S7 全部还清待退出：债务=0，可尝试失效抵押/退出市场。

### 全局状态（影响所有账户）
- G0 正常参数：价格稳定、市场未暂停、cap 充足。
- G1 时间推进：利息累计、奖励索引推进。
- G2 价格冲击：抵押品价格下跌或借款资产价格上涨。
- G3 参数突变：collateral factor / close factor / reserve factor / cap / pause 变化。
- G4 流动性紧张：市场 cash 不足，赎回/借款受限。

### 用户动作
- A_supply 供给
- A_withdraw 撤退（redeem/redeemUnderlying）
- A_borrow 借用
- A_repay 偿还（含 repayBehalf）
- A_claim 领取奖励
- A_enableCollateral 附带使得（enter market）
- A_disableCollateral 附带失效（exit market）
- A_liquidate 清算路径（liquidate + seize）

---

## 2) 临界态跃迁与禁止跃迁

### 临界态跃迁（应重点测试）
- T1: S1 --A_enableCollateral--> S2
- T2: S2 --A_borrow--> S3/S4
- T3: S4 --(G1 or G2 or 他人先操作)--> S5
- T4: S5 --A_liquidate--> S6 或回到 S4/S3
- T5: S3 --A_repay(partial)--> S3/S4/S7
- T6: S3 --A_withdraw(partial)--> S4 或失败
- T7: S7 --A_disableCollateral--> S1/S0
- T8: 任意有仓位状态 --A_claim--> 同状态（仅奖励余额变化）

### 禁止跃迁（应始终拒绝）
- F1: S0 --A_borrow--> 成功（禁止）
- F2: S3/S4/S5 --A_disableCollateral--> 成功且导致 shortfall>0（禁止）
- F3: S5 --A_withdraw--> 成功（禁止）
- F4: G3.pauseBorrow=true 时任何账户 --A_borrow--> 成功（禁止）
- F5: closeFactor 限制外清算成功（禁止）
- F6: 同块重复更新导致奖励或利息双计（禁止）

---

## 3) 常缺失过渡点（审计高价值）

以下每一项均给出：初始状态、动作场景、预期结果、漏洞类别。

## [ ] M1 临界健康到账户可清算的“静默跃迁”
- 初始状态：S4（liquidity 很小，shortfall=0）。
- 动作场景：无用户主动操作，仅 G1 时间推进（利息累计）或 G2 小幅价格波动，再触发一次 borrow/redeem/liquidate 检查。
- 预期有效/无效结果：
  - 有效：账户进入 S5 后仅允许 repay/liquidate，borrow/withdraw 必须拒绝。
  - 无效：仍允许 borrow 或 withdraw。
- 可能暴露漏洞类别：过时缓存值、风险检查时机错误、计息前后状态竞争。

## [ ] M2 他人先行动导致你的退出失效
- 初始状态：alice 在 S3（有借款），bob 在同市场可操作。
- 动作场景：bob 先借走大量流动性或触发价格变动，再由 alice 执行 A_disableCollateral 或 A_withdraw。
- 预期有效/无效结果：
  - 有效：若会触发 shortfall 或 cash 不足，应拒绝。
  - 无效：错误放行退出/赎回。
- 可能暴露漏洞类别：排序依赖、TOCTOU 风险、流动性检查缺失。

## [ ] M3 部分还款后错误解锁抵押
- 初始状态：S3 或 S4。
- 动作场景：A_repay(partial) 后立即 A_disableCollateral 或 A_withdraw(max)。
- 预期有效/无效结果：
  - 有效：仅在最终 liquidity>=0 才放行。
  - 无效：部分还款后过早允许退出，导致隐性坏账。
- 可能暴露漏洞类别：状态转移条件错误、边界检查漏洞。

## [ ] M4 同块重复动作导致索引双计
- 初始状态：S2/S3，G0。
- 动作场景：同一块内连续执行 supply->borrow->repay->claim->claim。
- 预期有效/无效结果：
  - 有效：第二次 claim 不应重复领取同一时间窗奖励；同块 accrue 幂等。
  - 无效：奖励或利息重复累计。
- 可能暴露漏洞类别：奖励指数漂移、幂等性缺陷、重入式逻辑重放（即使无重入）。

## [ ] M5 从可清算到部分清算后的错误状态
- 初始状态：S5。
- 动作场景：bob 对 alice 执行部分清算（受 closeFactor 限制），随后 alice 尝试 borrow/withdraw。
- 预期有效/无效结果：
  - 有效：若仍高风险应继续拒绝；若恢复健康则按规则允许。
  - 无效：清算后状态标记错误导致不当放行或过度拒绝。
- 可能暴露漏洞类别：清算会计错位、状态机回迁错误。

## [ ] M6 奖励领取与仓位变化顺序耦合
- 初始状态：S3，存在 supply+borrow 双边奖励。
- 动作场景：路径 A 先 claim 再 repay；路径 B 先 repay 再 claim；比较结果。
- 预期有效/无效结果：
  - 有效：差异仅来自应计时间差，不应出现系统性多领/少领。
  - 无效：顺序可稳定套利奖励。
- 可能暴露漏洞类别：奖励索引结算顺序错误、用户级与全局级对账不一致。

## [ ] M7 长时间空窗后首次动作跨越多状态
- 初始状态：S3，长时间无交互。
- 动作场景：warp 30~180 天后首次执行 A_repay 或 A_withdraw。
- 预期有效/无效结果：
  - 有效：先完成计息再执行动作，结果与显式 accrue 路径一致（容差内）。
  - 无效：首次动作使用旧指数导致错误放行/拒绝。
- 可能暴露漏洞类别：延迟计息缺陷、债务时间增长错算。

## [ ] M8 价格冲击与清算激励会计联动
- 初始状态：S4。
- 动作场景：G2 价格冲击使账户入 S5，bob 执行 A_liquidate，alice 紧接 A_claim。
- 预期有效/无效结果：
  - 有效：seize 拆分守恒，奖励只按剩余仓位继续累计。
  - 无效：清算后奖励仍按旧仓位发放，或清算拆分不守恒。
- 可能暴露漏洞类别：清算激励会计错误、奖励-仓位脱锚。

## [ ] M9 失效抵押（exit）与多市场聚合风险
- 初始状态：alice 在多市场抵押+借款（跨市场聚合）。
- 动作场景：对单一市场执行 A_disableCollateral，观察聚合 liquidity。
- 预期有效/无效结果：
  - 有效：仅当聚合层面仍安全才允许 exit。
  - 无效：只检查单市场，忽略账户级聚合风险。
- 可能暴露漏洞类别：跨市场风控遗漏、成员关系与资产列表不同步。

## [ ] M10 坏账假设路径中的禁止跃迁
- 初始状态：极端冲击后 S5 且部分债务无法被单次清算覆盖。
- 动作场景：连续多次部分清算、部分还款、尝试借新债。
- 预期有效/无效结果：
  - 有效：坏账状态下 borrow/withdraw 受限，系统净资产不虚增。
  - 无效：账户可在坏账残留下重新借款或提走价值。
- 可能暴露漏洞类别：坏账处理假设错误、风险门控绕过。

---

## 4) 测试建议：单元 / 多步模糊 / 长串不变量

### A. 基于过渡的单元测试（Transition Unit Tests）
- testTransition_S4_to_S5_ByTimeAccrual()
- testTransition_DisableCollateral_Rejected_WhenWouldShortfall()
- testTransition_SameBlockClaim_NoDoubleCount()
- testTransition_PartialRepay_DoesNotOverUnlockCollateral()
- testTransition_LiquidationSplit_Conservation()

单元断言重点
- 动作前后状态标签变化符合预期（例如 S4->S5）。
- 禁止跃迁必须拒绝且状态无污染。
- 会计守恒：collateral seized = liquidator part + protocol part（容差内）。

### B. 多步模糊场景（Scenario Fuzz）
- testFuzzScenario_ActionSequence_WithTimeAndPriceShocks(uint8[] actions, uint40[] dts, int24[] priceMoves)
- testFuzzScenario_MultiUserOrderingDependence(uint8 orderSeed)

模糊设计要点
- 动作集合含：supply/withdraw/borrow/repay/claim/enable/disable/liquidate。
- 在序列中随机插入：时间推进、价格变动、其他用户先手动作。
- 对每步执行后记录快照并做局部不变量检查。

### C. 长动作串行不变量（Stateful Invariants）
- invariant_NoForbiddenTransitionEverSucceeds()
- invariant_BorrowIndexMonotonic()
- invariant_AccountLiquidityShortfallMutualExclusion()
- invariant_RewardTotalEqualsSupplyPlusBorrow()
- invariant_GlobalUserAccountingSync()
- invariant_BadDebtCannotReborrowOrWithdrawUnsafe()

不变量关键断言
- liquidity * shortfall == 0。
- borrowIndex 单调不减；dt=0 的重复更新幂等。
- 对每个 emission token：total == supplySide + borrowSide。
- 用户侧与全局侧总账一致（容差内）。

---

## 5) 优先级（先补最危险过渡）
1. M1/M3/M9：抵押使得/失效与借款安全边界。
2. M4/M6：同块与顺序依赖导致奖励/利息双计。
3. M5/M8/M10：清算后回迁、清算激励会计、坏账路径。
4. M2/M7：他人先手与长时间空窗后的状态突变。

这份清单可直接映射到 Foundry：
- 单元测试用于确认单条跃迁合法性。
- Stateful fuzz 覆盖组合路径与先后手差异。
- Invariant 在长序列上捕获缓慢漂移型会计漏洞。

---

## 补充：状态机场景的分层落地顺序

### 层 1：手工画迁移表（先于写代码）
- 对每个 Mx 场景写 4 列：前置状态、动作、预期目标状态、禁止状态。
- 先人工检查禁止跃迁 F1 到 F6 是否闭合（无漏口）。

### 层 2：Transition Unit Test（最先实现）
- 先落地单条跃迁：例如 S4->S5、S5->S6、S7->S1。
- 只用 mock 时间与 mock 价格，不上 fork。
- 每条测试只验证一个跃迁，保证失败时定位清晰。

### 层 3：Stateful Invariant（中成本）
- 将“禁止跃迁永不成功”提升为 invariant。
- 先小动作集合（supply/borrow/repay/withdraw），再加入 liquidate/claim。

### 层 4：Fork Fuzz（最后）
- 仅针对 M2/M7/M8 这类强依赖真实流动性与多链时序场景。
- 目标是验证真实环境鲁棒性，而非基础状态机正确性。

### 建议节奏
- 每新增一个动作前，先补该动作的 2 到 3 条迁移 unit，再放进 invariant handler。

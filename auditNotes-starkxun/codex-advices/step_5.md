# Step 5 - 借贷协议多用户交互缺失场景审查（审计视角）

> **这份清单干什么用？**
> 单用户测试就像只测“我一个人使用这个 ATM”，但真实世界里多人同时操作时会发生什么？这份清单专门覆盖“多用户交互才能触发”的风险场景——它们在单用户测试中根本不可见。

---

## 角色约定（统一使用，贯穿所有场景）

| 角色 | 身份 | 典型行为 |
|------|------|---------|
| **Alice** | 健康供应者 | 主要提供流动性/抵押，被动受其他用户影响 |
| **Bob** | 借款人 | 高频借还，健康度接近阈值 |
| **Carol** | 清算人/机会主义者 | 抢先交易、奖励捕获、多清算竞争 |
| **Admin/Guardian** | 参数控制方 | 调整参数、暂停/恢复功能 |

**目标：只讨论“多用户交互才会出现”的风险，不重复单用户快乐路径。**

---

## 测试框架（建议所有场景共用）

```solidity
// test/MultiUserBase.t.sol
contract MultiUserBase is Test {
    address alice = makeAddr("alice");
    address bob   = makeAddr("bob");
    address carol = makeAddr("carol");
    address admin = makeAddr("admin");

    // 每个场景开始时拍一张快照，结束后对比
    function snapshotUser(address user) internal view returns (UserSnap memory) {
        return UserSnap({
            mTokenBalance: mToken.balanceOf(user),
            borrowBalance: mToken.borrowBalanceStored(user),
            accruedReward: rewardDistributor.rewardAccrued(user)
        });
    }
}
```

---

## [P0] 场景 1：顺序依赖导致清算资格翻转（Ordering-Dependent Liquidatability）

> **通俗理解：** Carol 在清算 Bob 之前，先做一笔操作（比如大量赎回推高利用率），让 Bob 突然满足了清算条件。问题是：这个操作合法吗？清算资格是否被人为制造了？

### 完整动作串行
1. Alice 在市场 A 大额供给，保持健康。
2. Bob 在市场 A 借款，健康度接近阈值（`liquidity` 小于安全缓冲）。
3. Carol 先执行一次小额借款或大额赎回，降低市场可用 cash 或推动利用率变化。
4. 同一区块/相邻区块内，Carol 尝试对 Bob 清算。
5. 对照路径：Carol 不做步骤 3，直接清算 Bob。

### 为什么单用户测试会漏掉
- 单用户无法制造“他人先手改变可清算条件”的竞态；同一账户路径看不到资格翻转。

### Foundry 测试代码框架
```solidity
function test_OrderDependentLiquidationEligibility() public {
    // 设置：Bob 在 S4（临界健康）
    setupBobAtEdge();

    // 路径 A：Carol 先插入操作，再清算
    uint256 snapId = vm.snapshot();
    vm.prank(carol);
    mToken.redeem(largeAmount); // 降低 cash，推高利用率
    vm.prank(carol);
    (uint err) = mToken.liquidateBorrow(bob, repayAmt, address(mTokenCollateral));
    bool liquidatedWithFrontRun = (err == 0);

    // 路径 B：Carol 直接清算（不插入操作）
    vm.revertTo(snapId);
    vm.prank(carol);
    (err) = mToken.liquidateBorrow(bob, repayAmt, address(mTokenCollateral));
    bool liquidatedWithout = (err == 0);

    // 断言：清算资格差异必须可被协议规则解释
    // 不允许出现：无 shortfall 也能清算
    (,, uint256 shortfall) = comptroller.getAccountLiquidity(bob);
    if (shortfall == 0) {
        assertFalse(liquidatedWithFrontRun, "liquidation without shortfall");
    }
}
```

### 关键断言
- 分支差异必须可解释，不可出现“无 shortfall 也可清算”。
- 清算失败路径：Bob 债务、Carol 余额、全局 `borrows/reserves` 不变（零状态污染）。

---

## [P0] 场景 2：领先式状态变化触发他人退出失败（Lead-State Exit Denial）
### 完整动作串行
1. Alice 供给并入市（可随时退出的健康状态）。
2. Bob 在同市场大额借款，占用 cash。
3. Alice 尝试 `redeem` 或 `exitMarket`。
4. Admin 调整 borrow cap/collateral factor 后重复步骤 3。

### 为什么单用户测试会漏掉
- 单用户模型不会引入“别人先借空池子”对 Alice 的退出可行性冲击。

### Foundry 测试大纲
- `function test_LeadBorrowCanBlockUnrelatedSupplierExit() public`
- 子用例：仅 Bob 借款、Bob 借款+治理参数变化。

### 关键断言
- Alice 退出失败时必须是明确原因（cash 不足或风控拒绝），而非错误码漂移。
- 失败不应污染 Alice 的 membership 或奖励索引。

---

## [P0] 场景 3：奖励稀释/不公平积累（Late Join Dilution Abuse）

> **通俗理解：** Alice 努力存款了 30 天，Bob 突然在第 30 天的最后一秒大量存入，然后一起领奖励。问题是：Bob 是否通过“插队”获得了不属于他的历史奖励？这是很多 DeFi 协议的经典漏洞。

### 完整动作串行
1. Alice 长时间供给，Bob 长时间借款（奖励持续累计）。
2. Carol 在奖励更新前**同一区块内**大额供给或借款“插队入场”。
3. 三方在同块/下一块 claim。
4. 对照路径：Carol 不插队，正常入场。

### 为什么单用户测试会漏掉
- 奖励公平性是“相对份额 + 时间”问题，单用户看不到插队稀释对他人的影响。

### Foundry 测试代码框架
```solidity
function test_RewardDilutionByLateJoinerSameBlock() public {
    // Alice 和 Bob 已持仓 30 天
    vm.warp(block.timestamp + 30 days);

    // 记录 Alice 在 Carol 插队前的应计奖励
    uint256 aliceRewardBefore = getAccruedReward(alice);

    // Carol 在同一区块大额插队（不 warp）
    vm.prank(carol);
    mToken.mint(carolLargeAmount);

    // 三人同块 claim
    rewardDistributor.claimReward(alice, address(mToken));
    rewardDistributor.claimReward(carol, address(mToken));

    uint256 aliceRewardAfter = getAccruedReward(alice);

    // Alice 历史 30 天的奖励不应被 Carol 回溯稀释
    assertGe(aliceRewardAfter, aliceRewardBefore,
        "Carol should not dilute Alice historical rewards");

    // 奖励守恒：totalAmount == supplySide + borrowSide
    assertEq(getTotalReward(), getSupplySideReward() + getBorrowSideReward());
}
```

### 关键断言
- Alice/Bob 的历史区间奖励**不应被 Carol 回溯稀释**。
- `totalAmount == supplySide + borrowSide` 对每个用户每个 emissionToken 恒成立。
- Carol 只能从她**入场后**的时间窗口开始积累奖励。

---

## [P1] 场景 4：利息计制时间差异被机会用户利用（Accrual Timing Arbitrage）
### 完整动作串行
1. Bob 借款后长时间无交互。
2. Carol 先触发一次会导致 `accrueInterest` 的操作（如小额 borrow/repay）。
3. Bob 立即 repay；对照路径是 Bob 先 repay 再由 Carol 触发 accrue。

### 为什么单用户测试会漏掉
- 单用户只有单一路径，无法比较“谁先触发 accrue”对债务结算影响。

### Foundry 测试大纲
- `function test_AccrualTriggerOrderingDoesNotLeakValue() public`
- 两条路径从同一快照回放，比较 Bob 实付与系统收益。

### 关键断言
- 两路径最终债务与储备变化应一致（容差内）。
- 不应出现可稳定套利的“先手触发计息优势”。

---

## [P0] 场景 5：用户间流动性耗尽连锁（Shared Liquidity Exhaustion）
### 完整动作串行
1. Alice 与 Bob 都依赖同一借款池流动性。
2. Bob 大额 borrow 到接近池子可借上限。
3. Alice 尝试 borrow 或 redeemUnderlying。
4. Carol 再发起清算/套利行为，观察 Alice/Bob 可执行性变化。

### 为什么单用户测试会漏掉
- 单用户不体现“共享池容量竞争”与连锁失败。

### Foundry 测试大纲
- `function test_SharedLiquidityExhaustionCrossUserImpact() public`
- 用参数化金额覆盖：`small/medium/nearMax`。

### 关键断言
- 被拒绝操作必须是预期拒绝，不得出现错误成功导致负 cash。
- 全局会计不被破坏：`cash + borrows - reserves` 与 exchangeRate 一致（容差内）。

---

## [P0] 场景 6：治理变更影响“无关用户”健康度（Collateral/Borrow Limit Spillover）
### 完整动作串行
1. Alice 健康供给者，Bob 借款者，二者仓位互不相同。
2. Admin 调整 collateral factor / borrow cap / reserve factor（针对某市场）。
3. 仅 Bob 执行小操作触发全局状态更新。
4. 检查 Alice 是否被意外影响（liquidity、可退出性、奖励）。

### 为什么单用户测试会漏掉
- 单用户默认“参数变化影响自己”是正常的，但无法识别对无关账户的异常溢出效应。

### Foundry 测试大纲
- `function test_GovernanceParamChangeDoesNotCorruptUnrelatedUsers() public`
- 分支覆盖：每种参数单独改、组合改。

### 关键断言
- 无关用户的风险暴露只应通过协议定义的全局机制变化，不应出现离散跳变异常。
- 参数变更前后，未参与市场的用户状态不应变化。

---

## [P1] 场景 7：共享流动性下多清算人竞争边缘（Multi-Liquidator Race）
### 完整动作串行
1. Bob 进入可清算状态（shortfall>0）。
2. Carol 与 Alice（或另一个清算者）在短时间内连续部分清算 Bob。
3. 第二位清算者按旧预期 repayAmount 尝试清算。

### 为什么单用户测试会漏掉
- 单一清算者不会暴露“前一个清算已改变 closeFactor 可用额度”的竞态。

### Foundry 测试大纲
- `function test_MultiLiquidatorRaceRespectsUpdatedDebtAndCloseFactor() public`
- 第一次清算后立即读取新 debt，再执行第二次清算。

### 关键断言
- 第二次清算不得基于旧债务超额执行。
- 清算拆分守恒：`seized = liquidatorPart + protocolPart`（容差内）。

---

## [P1] 场景 8：管理员操作导致用户状态不一致（Admin-Induced State Desync）
### 完整动作串行
1. Alice、Bob 都已入市并有仓位。
2. Guardian 暂停 borrow 或奖励分发；Governor 随后恢复或调整参数。
3. Bob 在暂停前后进行 repay/borrow；Alice 进行 claim/withdraw。
4. 检查两人在相同条件下是否出现行为分叉。

### 为什么单用户测试会漏掉
- 单用户通常只验证“自己是否被暂停/恢复”，难以发现“不同用户状态机不同步”。

### Foundry 测试大纲
- `function test_AdminPauseResumeKeepsUserStateMachineConsistent() public`
- 覆盖 pause->action->unpause->action 全流程。

### 关键断言
- pause 期间仅禁止应禁止动作；风险收敛动作（repay/liquidate）应按设计保留。
- 恢复后用户状态一致，不应有人“永久卡死”或异常放行。

---

## [P1] 场景 9：repayBehalf 与奖励/债务归属错配

> **通俗理解：** Carol 替 Bob 还了债（`repayBorrowBehalf`），但会计系统正确记录了吗？债务应该减少 Bob 的，奖励不应该转给 Carol，否则就出现了“还别人的债却拿别人的奖励”的错误。

### 完整动作串行
1. Bob 借款并持续累计借款侧奖励。
2. Carol 执行 `repayBorrowBehalf(Bob, amount)`（Carol 出钱，帮 Bob 还债）。
3. Bob 与 Carol 分别 `claim` 奖励。
4. Alice 作为对照组仅 supply+claim（验证不受影响）。

### 为什么单用户测试会漏掉
- 单用户 repay 不会测试“付款人（Carol） != 借款人（Bob）”时的索引归属问题。

### Foundry 测试代码框架
```solidity
function test_RepayBehalfDoesNotMisattributeRewardsOrDebt() public {
    // Bob 借款 30 天，累计奖励
    vm.prank(bob);
    mToken.borrow(borrowAmt);
    vm.warp(block.timestamp + 30 days);

    // 快照：repayBehalf 前的状态
    uint256 bobDebtBefore  = mToken.borrowBalanceCurrent(bob);
    uint256 carolDebtBefore = mToken.borrowBalanceCurrent(carol);
    uint256 bobRewardBefore = getAccruedReward(bob);
    uint256 carolRewardBefore = getAccruedReward(carol);

    // Carol 替 Bob 还债
    vm.prank(carol);
    mToken.repayBorrowBehalf(bob, repayAmt);

    // 验证债务归属正确
    assertLt(mToken.borrowBalanceCurrent(bob), bobDebtBefore,
        "Bob debt should decrease");
    assertEq(mToken.borrowBalanceCurrent(carol), carolDebtBefore,
        "Carol debt should NOT change");

    // 验证奖励归属正确
    assertEq(getAccruedReward(carol), carolRewardBefore,
        "Carol should NOT get Bob reward");
}
```

### 关键断言
- 债务**仅减少 Bob 的**，Carol 的债务不变。
- 奖励不串账：Carol 不应获得 Bob 的历史借款奖励。
- Bob 的历史奖励在 repayBehalf 后仍属于 Bob，`claimReward(bob)` 应正常工作。

---

## [P2] 场景 10：先清算后参数变更再清算的跨步骤会计偏移
### 完整动作串行
1. Carol 对 Bob 做一次部分清算。
2. Admin 立刻调整 liquidation incentive 或 protocol seize share。
3. Carol/他人再次清算 Bob。

### 为什么单用户测试会漏掉
- 单用户通常不会把“清算 + 治理变更 + 再清算”串起来验证分段会计。

### Foundry 测试大纲
- `function test_LiquidationAccountingAcrossParamChangeSegments() public`
- 分段记录每次清算的 repay、seize、protocol share。

### 关键断言
- 参数变更只影响变更后的清算段，不回溯污染上一段。
- 分段加总后，全流程价值守恒成立。

---

## 建议补测优先级

> **新手建议：** 每个场景都先用固定输入写一个确定性测试，跑通后再写 fuzz 版本。

1. **场景 1/3/5/6**（高风险多用户交互核心面）— 先做
   - 场景 3（奖励稀释）最容易落地，建议第一个写
   - 场景 9（repayBehalf）逻辑清晰，建议第二个写

2. **场景 2/4/7**（顺序与时间差异竞态）— 中期

3. **场景 8/9/10**（管理与归属一致性）— 后期

## 可复用不变量（用于长序列 stateful fuzz）
- `invariant_NoCrossUserUnauthorizedValueTransfer()`
- `invariant_RewardConservationPerEmissionToken()`
- `invariant_UserGlobalAccountingSyncUnderMultiActorActions()`
- `invariant_PauseRulesConsistentAcrossUsers()`
- `invariant_LiquidationSplitConservationAcrossRaces()`

---

## 补充：多用户场景的成本控制路线

### 第一层：手写反例剧本（先定攻击路径）
- 每个场景先写最小三人剧本：谁先手、谁后手、谁获利。
- 明确“若存在漏洞，价值会从谁转移到谁”。

### 第二层：unit + mock 重放剧本（主力）
- 用 mock oracle、mock rate、mock reward 把 10 个场景逐条重放。
- 同一初始快照跑 A/B 顺序分支，比较最终价值分配差异。
- 这是多用户审计最划算的一层，定位最清晰。

### 第三层：stateful invariant（扩展覆盖）
- 把已验证的剧本抽象成不变量：
	- 无未授权价值转移
	- 清算拆分守恒
	- pause 规则跨用户一致
- 通过随机顺序扩大覆盖，但仍保持本地 mock 环境。

### 第四层：fork fuzz（最终验真）
- 仅将以下类型上 fork：
	- 治理时序 + 多用户竞争
	- 真实流动性深度影响清算资格
	- 真实奖励配置下的插队稀释
- 建议作为定时回归，不作为日常开发主回路。

### 优先落地建议
1. 先做场景 1/3/9 的 unit+mock（顺序依赖、奖励归属、repayBehalf）。
2. 再把场景 5/7 抽成 invariant（共享流动性与多清算人竞争）。
3. 最后只把场景 6/10 放到 fork fuzz 做真实性验证。

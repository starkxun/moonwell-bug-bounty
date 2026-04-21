# Step 2 - 贷款协议对抗性与边缘覆盖检查表（Foundry）

> **这份清单干什么用？**
> 正常流程测试只覆盖了“一切正常时”的路径。这份清单专门补充那些“边界情况”和“对抗性操作”——现实中的漏洞正是藏在这里。每个条目都给出可直接转成 Foundry 测试的结构。

---

## 测试基础约定（先读这里，写代码时作为参考）

**角色设定（统一使用，方便阅读）：**
- `alice`：主要供应者或借款者（正常用户）
- `bob`：对手方或清算者（可能是攻击者）
- `carol`：第三方还款者或机会主义者

**可复用的断言辅助函数（建议写一个 `BaseTest.sol` 统一管理）：**

```solidity
// 验证账户流动性健康
function assertAccountLiquidityInvariant(address user) internal view {
    (uint256 err, uint256 liquidity, uint256 shortfall) =
        comptroller.getAccountLiquidity(user);
    assertEq(err, 0, "liquidity check error");
    assertEq(shortfall, 0, "unexpected shortfall");
}

// 验证市场会计恒等式: exchangeRate ≈ (cash + borrows - reserves) / totalSupply
function assertMarketAccountingInvariant(address mToken) internal view {
    uint256 cash = MToken(mToken).getCash();
    uint256 borrows = MToken(mToken).totalBorrows();
    uint256 reserves = MToken(mToken).totalReserves();
    uint256 supply = MToken(mToken).totalSupply();
    if (supply > 0) {
        uint256 expected = (cash + borrows - reserves) * 1e18 / supply;
        uint256 actual = MToken(mToken).exchangeRateStored();
        assertApproxEqAbs(actual, expected, 2, "accounting invariant broken");
    }
}

// 验证奖励总量守恒: totalReward == supplySide + borrowSide
function assertRewardConservation(address user, address mToken) internal view {
    // 根据具体 reward 合约补充实现
}
```

**时间控制：**
- 同一区块内不使用 `vm.warp`（测试幂等性）
- 跨时间用 `vm.warp(block.timestamp + dt)`（`dt` 单位为秒，例如 1天 = 86400）

**允许误差：** 涉及除法的断言使用绝对误差或相对误差（如 1\~2 wei，或 1e-12 比例）

---

## [ ] 1. 边界值（Boundary Values）
- **盲点：** 只测中间值时，常漏掉 min/max 边缘分支（例如 closeFactor 上限、cap 边界、可借额度边界）。
- **通俗理解：** 就像测一扇门，不仅要测“正常开关”，还要测“刚好满载时”和“超重一丁点时”会发生什么。
- **测试步骤：**
  1. alice 供应抵押并 enter market。
  2. 计算 `maxBorrow`，分别尝试 `maxBorrow-1`、`maxBorrow`、`maxBorrow+1` 借款。
  3. 在 supply cap 临界位重复 mint/borrow。
- **建议测试名：**
  - `testBorrowAtLiquidityBoundary()`
  - `testMintAtSupplyCapBoundary()`
  - `testRepayAtCloseFactorBoundary()`
- **预期断言：**
  - 边界内：操作成功，账户 `liquidity >= 0`。
  - 边界外：操作失败，错误码符合预期，且**失败前后状态完全一致**（重要！）。
- **最小代码示例：**
  ```solidity
  function testBorrowAtLiquidityBoundary() public {
      uint256 maxBorrow = getMaxBorrow(alice);
      // 恰好在边界内：应成功
      vm.prank(alice);
      mToken.borrow(maxBorrow - 1);
      // 恰好超出边界：应失败
      vm.prank(alice);
      vm.expectRevert();  // 或检查返回错误码
      mToken.borrow(2);   // 再借 2 就超出了
  }
  ```

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
- **盲点：** 依赖 `block.timestamp` 的索引更新在同块 `delta=0`，可能出现重复领收益、重复计息或漏计。
- **通俗理解：** 如果银行按“每天”结算利息，那你一天内存取多次，不应该结算多次利息。合约里的“每天”是通过 `block.timestamp` 判断的，同一个区块内时间不变，所以索引不应该更新多次。
- **测试步骤：**
  1. alice 在同一块连续 `mint` → `borrow` → `repay` → `claimReward`（**不调用** `vm.warp`）。
  2. 记录第一轮结束时的状态快照。
  3. 重复一轮相同操作，比较状态变化。
- **建议测试名：**
  - `testRepeatedActionsInSameBlockIdempotence()`
  - `testSameBlockRewardIndexNoDoubleCount()`
- **预期断言：**
  - 同块重复操作不会额外产生利息或奖励（除非协议设计明确允许）。
  - 第二轮结束后，`borrowIndex`、`supplyIndex`、`rewardIndex` 与第一轮结束时相同。
- **最小代码示例：**
  ```solidity
  function testSameBlockRewardIndexNoDoubleCount() public {
      // 第一轮：mint + claim
      vm.prank(alice);
      mToken.mint(100e18);
      uint256 rewardBefore = getAccruedReward(alice);
      rewardDistributor.claimReward(alice, address(mToken));
      uint256 rewardAfter1 = getAccruedReward(alice);

      // 同一块再次 claim（不 warp）
      rewardDistributor.claimReward(alice, address(mToken));
      uint256 rewardAfter2 = getAccruedReward(alice);

      // 第二次 claim 不应增加奖励
      assertEq(rewardAfter2, rewardAfter1, "double count in same block");
  }
  ```

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

**测试文件组织结构建议：**
```
test/
├── BaseTest.sol          ← 统一存放角色设置、assert 辅助函数
├── BoundaryTest.t.sol    ← 条目 1、2、3、4（边界值类）
├── SameBlockTest.t.sol   ← 条目 5（同块重复）
├── LongIdleTest.t.sol    ← 条目 6（长时间空闲）
├── OrderingTest.t.sol    ← 条目 7、8（顺序依赖）
├── RoundingTest.t.sol    ← 条目 10（舍入方向）
└── invariants/
    └── RewardInvariant.t.sol  ← 条目 11（奖励指数漂移）
```

**参数化 fuzz 通用模板：**
```solidity
function testFuzz_BorrowAndRepay(uint256 amount, uint40 dt) public {
    amount = bound(amount, 1e6, maxBorrow);
    dt = uint40(bound(dt, 0, 180 days));

    vm.prank(alice);
    mToken.borrow(amount);
    vm.warp(block.timestamp + dt);
    vm.prank(alice);
    mToken.repayBorrow(amount);

    // 统一后置断言（每个测试都加上）
    assertMarketAccountingInvariant(address(mToken));
    assertAccountLiquidityInvariant(alice);
    assertRewardConservation(alice, address(mToken));
}
```

**fuzz 状态快照对比建议（在复杂测试中使用）：**
```solidity
struct MarketSnapshot {
    uint256 cash;
    uint256 totalBorrows;
    uint256 totalReserves;
    uint256 borrowIndex;
    uint256 exchangeRate;
}
MarketSnapshot memory before = takeSnapshot(mToken);
// ... 执行操作 ...
MarketSnapshot memory after_ = takeSnapshot(mToken);
// 验证变化量符合预期
```

- 用表驱动参数化：`amount`、`warpDelta`、`priceShock`、`actionOrder`。
- 对每个 checklist 条目至少实现一个**确定性测试**（fixed inputs）+ 一个 **fuzz 版本**（随机 inputs）。
- **统一后置断言**（每个测试结尾都要调用）：
  - `assertMarketAccountingInvariant(mToken)`
  - `assertAccountLiquidityInvariant(alice)`（或 `bob`）
  - `assertRewardConservation(alice, mToken)`

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

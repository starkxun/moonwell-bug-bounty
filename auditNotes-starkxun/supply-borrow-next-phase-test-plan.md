# Supply/Borrow 下一阶段测试计划

## 目标与策略

当前主流程（存款、借款、还款、奖励、利息、风控）已完成阅读和基础验证，下一步优先做补充细节测试，再进入新模块阅读。

执行顺序：

1. 先做 1-2 天供借模块边界与对抗测试
2. 达到完成标准后，再转向利率模型/预言机/清算外围

原因：

- 测试环境和上下文已热，补边界的发现效率最高
- 可以尽快把主链路从“能跑通”提升到“抗边界、抗异常”

## 高优先级补充测试清单

### 1. 边界值与阈值

- [ ] Supply Cap: N-1、N、N+1 三点覆盖
- [ ] Borrow Cap: N-1、N、N+1 三点覆盖
- [ ] Collateral Factor 临界借款：刚好可借与多借 1 wei
- [ ] Close Factor 临界清算：maxClose 与 maxClose+1

### 2. 记账一致性与舍入

- [ ] repayAmount = type(uint256).max（全额还款）
- [ ] 部分还款 + 再借 + 再还的交替路径
- [ ] 小额 dust 借还循环后，borrowBalanceStored / totalBorrows 无异常漂移
- [ ] mint/redeem 最小单位下长期舍入偏移检查

### 3. 利息与时间推进

- [ ] 多次 warp + accrueInterest 后 borrowIndex 单调递增
- [ ] 长时间不操作后首次交互的利息结算正确
- [ ] 高利用率场景下 borrow rate 上限保护行为

### 4. 风控拒绝路径

- [ ] oracle 价格为 0 时 borrow 被拒绝
- [ ] 未入市用户借款路径与自动入市逻辑一致性
- [ ] pause guardian 开启时 mint/borrow/transfer 行为符合预期

### 5. 非标准代币行为

- [ ] doTransferIn 在 fee-on-transfer 下按实际到账记账
- [ ] repay 实际到账小于输入值时账务仍一致

## 推荐断言模板（每条测试至少覆盖）

- [ ] 状态变量守恒：cash / borrows / reserves / index
- [ ] 操作前后差值断言：用户余额、市场余额、债务余额
- [ ] 错误路径断言：expectRevert 文案或错误条件

## 建议执行节奏

Day 1：边界值 + 记账一致性

- 优先完成 Cap、Collateral、CloseFactor、全额还款与 dust 场景

Day 2：时间/利息 + 风控拒绝 + 非标准代币

- 完成 warp/accrue 组合路径和暂停、价格异常、fee-on-transfer 路径

## 阶段完成标准（满足后再读新模块）

- [ ] 核心失败路径均有覆盖（含 Cap、Liquidity、Pause、Price=0）
- [ ] 核心状态变量具备单调性/守恒性断言
- [ ] 至少 2-3 个跨市场场景（A 抵押借 B）
- [ ] 至少 1 个价格冲击/清算场景

## 下一阶段阅读顺序（完成以上后）

1. 利率模型：JumpRateModel / WhitePaperInterestRateModel
2. 预言机：Chainlink Oracle + 各类 Wrapper 价格路径
3. 清算外围：清算相关组合路径与可重入风险面

## 命令建议（按需）

- 单测定向：forge test --match-test <testName> -vv
- 失败后加日志：forge test --match-test <testName> -vvvv
- 先跑最小集合再扩展 fuzz，避免定位成本过高

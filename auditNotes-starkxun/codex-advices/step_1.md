# Step 1 - 借贷协议测试缺口优先级清单（Moonwell-like）

## 范围与基线
你当前已覆盖：供应/借款/还款/奖励/利息/抵押检查的主成功路径。

我重点按“生产事故最常见触发面”筛缺口：
- 多市场账户状态转换
- 清算数学和边界
- 利率与索引累计一致性
- 权限和治理参数变更后的行为
- 奖励核算与主账本同步
- 跨链/治理执行时序

注：当前 invariant 框架中已有多个模板仍是 TODO（如会计恒等式、membership 双向一致、清算后状态校验、索引单调性），说明这些风险目前大概率没有被系统性验证。

---

## P0（高严重 + 高可能）

### 1) 多市场交叉抵押与退出市场（exitMarket）状态竞争
- 为什么重要：Moonwell/Compound 风险引擎是“账户级聚合”，不是单市场孤立判断。单市场测试通过，不代表跨市场组合安全。
- 现实故障模式：
  - 用户在 A 市场供给、B 市场借款，随后 C 市场价格波动或参数变更后仍可错误 exit A。
  - getAssetsIn 与 checkMembership 不一致，导致风控绕过或误拒绝。
- 缺少什么测试：
  - 先 enter 多市场，再在不同价格和借款分布下尝试 exitMarket，断言仅在 liquidity >= 0 时成功。
  - 双向校验：assetsIn 包含的市场必须 membership=true，反之亦然。
- 推荐类型：不变测试 + 分支/集成测试。

### 2) 清算 close factor / seize 计算边界（尤其四舍五入）
- 为什么重要：清算是资金重新分配的核心，高价值事故常见于“边界金额+精度”导致多拿/少拿。
- 现实故障模式：
  - repayAmount 接近 closeFactor 上限时，允许超额清算或拒绝合法清算。
  - seizeTokens 因舍入偏差导致协议或清算人获得异常份额。
- 缺少什么测试：
  - 在 shortfall 刚刚 > 0、刚刚 == 0、刚刚 < 0 三个边界做 liquidateBorrow。
  - repayAmount 取 0、1 wei、closeFactor*debt、closeFactor*debt+1。
  - 对账：borrower 债务减少、liquidator 抵押增加、protocol seize share 与总扣减守恒。
- 推荐类型：模糊测试 + 单元测试（精确数学断言）+ 集成测试。

### 3) mToken transfer 对抵押账户流动性的影响
- 为什么重要：在 Compound 架构中，mToken 转账会触发 allowed 检查；如果漏测，可能出现“转走抵押仍保留借款”。
- 现实故障模式：
  - 账户已有借款时，transfer 被错误放行，形成隐性坏账。
  - pause 或风控状态下 transfer 逻辑分叉不一致。
- 缺少什么测试：
  - 用户借款后尝试转出抵押 mToken，断言在会造成 shortfall 时必须失败。
  - 覆盖 to=self、to=zero、极小余额、全部转出。
- 推荐类型：分支/集成测试 + 不变测试。

### 4) 市场会计恒等式未持续验证（cash/borrows/reserves/exchangeRate）
- 为什么重要：主账本错位通常不会立即 revert，但会在赎回或清算时爆发系统性损失。
- 现实故障模式：
  - accrueInterest 后 totalBorrows、totalReserves、exchangeRate 三者偏离。
  - 长时间 warp 后 share price 不再单调，出现套利窗口。
- 缺少什么测试：
  - 持续断言 exchangeRateStored ~= (cash + totalBorrows - totalReserves)/totalSupply（允许 epsilon）。
  - borrowIndex 单调不减，totalSupply>0 时 exchangeRate>0。
- 推荐类型：不变测试（首选）+ 模糊测试。

---

## P1（高严重 + 中可能）

### 5) 奖励与主账本不同步（借款变动、清算、repayBehalf 后）
- 为什么重要：奖励错误会导致长期漏发/超发，直接变成经济损失与治理争议。
- 现实故障模式：
  - 同一用户 supply+borrow+liquidation 后 totalAmount != supplySide+borrowSide。
  - repayBorrowBehalf 只更新 payer 或 borrower 一侧索引，导致“幽灵奖励”。
- 缺少什么测试：
  - 在同一账户执行 mint->borrow->partial repay->liquidate->claim，逐步校验 reward index 和未领取奖励增量。
  - 多奖励 token 并发下校验每个 emission token 的独立守恒。
- 推荐类型：分支/集成测试 + 模糊测试。

### 6) 利率模型参数突变后的连续性（治理变更后下一次 accrue）
- 为什么重要：治理可升级 IR 模型或 reserve factor；错误衔接会造成跳变式利息或债务错账。
- 现实故障模式：
  - 参数更新前后同一区块/相邻区块 accrual 不连续，借款人被异常计息。
  - 更新后 borrow rate 超过上限或出现负向/回退。
- 缺少什么测试：
  - governance 执行参数更新后，立即和延后一段时间分别 accrue，校验 borrows/reserves 变化与预期曲线一致。
  - 对 utilization 在低/中/高三段做回归。
- 推荐类型：集成测试 + 单元测试（模型函数）+ 模糊测试。

### 7) 借款/供应 cap 与 pause 组合状态的拒绝路径
- 为什么重要：生产事故常发生在“紧急参数切换”期间，功能开关组合可能出现漏拦截。
- 现实故障模式：
  - supply cap 达上限后仍可 mint 少量。
  - borrow paused 但 repay/liquidate 路径被误阻断（应允许风险收敛操作）。
- 缺少什么测试：
  - 对 mint/borrow/repay/liquidate/transfer 在 pause 与 cap 组合下做矩阵测试。
  - 断言错误码/错误信息与设计一致，避免前端和风控机器人误判。
- 推荐类型：分支测试 + 集成测试。

### 8) 非标准 ERC20 资产行为（fee-on-transfer / rebasing / 返回值异常）
- 为什么重要：真实链上资产经常不“标准”，而借贷协议会把它们当标准 ERC20 使用。
- 现实故障模式：
  - mint 输入 amount 与到账 amount 不一致，导致凭证发行过量。
  - repay 时 transfer fee 造成“看似还款成功，实际债务残留”。
- 缺少什么测试：
  - 引入 mock fee-on-transfer 与 rebasing token 市场，验证 mint/redeem/repay/liquidate 的会计守恒。
  - 覆盖 approve/transfer 返回 false 或不返回值分支。
- 推荐类型：单元测试（mock）+ 集成测试。

---

## P2（中严重 + 中可能）

### 9) 清算前后奖励归属时点（谁拿到临界区间奖励）
- 为什么重要：清算区间的奖励归属易被忽略，可能被机器人利用“清算前后切片”薅奖励。
- 现实故障模式：
  - borrower 在被清算后仍领取被转移抵押对应的 supply 奖励。
  - liquidator 获得奖励起算时间提前到清算前。
- 缺少什么测试：
  - 在清算发生的同一区块与相邻区块比较奖励增量。
  - 校验奖励索引更新顺序：先结算旧持仓，再转移份额。
- 推荐类型：分支/集成测试 + 模糊测试（时间与顺序扰动）。

### 10) 极端时间跳跃（长时间不交互）后的首次交互行为
- 为什么重要：线上冷门市场常长期无交互，首次触发 accrue 可能出现溢出/巨大舍入误差。
- 现实故障模式：
  - 首次 borrow 或 repay 触发异常大 accrual，导致交易失败或经济异常。
  - reward endTime 后继续累计或提前截断。
- 缺少什么测试：
  - warp 到 30/90/180 天后执行首笔 mint/borrow/repay/liquidate，校验索引与奖励截止逻辑。
- 推荐类型：模糊测试 + 集成测试。

### 11) 清算资产与借款资产为同一市场/不同市场的分支差异
- 为什么重要：同市场清算与跨市场清算路径在实现上通常有分叉，容易出现只测其一。
- 现实故障模式：
  - 同市场路径通过，跨市场路径因价格读取或 seize 计算错误失败/超扣。
- 缺少什么测试：
  - borrower 在 A 供给借 B，再测 A/B 互换及 A=A 场景，覆盖 close factor、liquidation incentive、protocol seize share。
- 推荐类型：集成测试 + 模糊测试。

---

## P3（中严重 + 低到中可能，但生产上常被忽视）

### 12) 跨链治理执行时序与参数漂移
- 为什么重要：多链部署中，参数在不同链落地时存在时间差，可能短时间出现风控不一致。
- 现实故障模式：
  - 链 A 已提高 collateral factor，链 B 未更新；跨链监控或策略假设失效。
  - 桥接消息重放/延迟导致奖励或风控参数瞬时反常。
- 缺少什么测试：
  - 模拟提案在不同 fork 链分批执行，比较关键参数与行为一致性。
  - 对桥接消息执行顺序扰动，断言幂等与最终一致。
- 推荐类型：集成测试（多 fork）+ 模糊测试（消息顺序/延迟）。

### 13) 权限边界的“可调用但应失败”路径未系统化
- 为什么重要：权限漏洞通常不是“函数不存在权限检查”，而是某些状态组合下绕过。
- 现实故障模式：
  - 非 admin 通过代理/包装器间接改风险参数。
  - pauseGuardian 能执行不该执行的恢复操作。
- 缺少什么测试：
  - 对 _setCollateralFactor/_setReserveFactor/_setProtocolSeizeShare 等关键入口做角色矩阵与代理调用矩阵。
  - 断言事件与状态都不发生变化，而不仅是 revert。
- 推荐类型：单元测试 + 分支测试。

---

## 建议先补的 6 个测试任务（可直接开工）
1. 多市场账户流动性与 exitMarket 拒绝/放行矩阵（P0）。
2. 清算边界数学套件：closeFactor、seize、舍入守恒（P0）。
3. transfer 触发风控拒绝路径（借款后转抵押）+ 不变断言（P0）。
4. 会计恒等式 invariant：exchangeRate/cash/borrows/reserves + borrowIndex 单调（P0）。
5. 奖励-账本同步回归：repayBehalf + liquidation + claim 顺序组合（P1）。
6. cap/pause 组合状态机测试，明确哪些动作必须允许（尤其 repay/liquidate）（P1）。

## 测试策略分配建议
- 单元测试：数学与权限边界（可精确断言数值和错误码）。
- 模糊测试：金额、时间、顺序扰动（找边界穿透）。
- 不变测试：长期状态守恒与单调性（最能抓“主路径通过但账本偏离”）。
- 分支/集成测试：跨市场、跨模块、治理后行为连续性。

---

## 补充：按成本分层的执行顺序（先便宜，后昂贵）

你现在的判断是对的：fork + 长序列 fuzz 成本最高，应该放在最后做“系统兜底”。

### 第一层：手写数学推导/反例（最快）
- 适合：
  - 清算边界（closeFactor、seize、protocol share）
  - 会计恒等式（cash/borrows/reserves/exchangeRate）
  - 借贷利率与索引单调性
  - cap/pause 组合下的允许/禁止动作矩阵
- 产出：
  - 每个主题 3 到 5 条可机读断言（等式/不等式/单调性）
  - 每条断言至少 1 个“反例输入”草案（例如 closeFactor*debt+1）

### 第二层：unit test + mock（主力）
- 适合：
  - 非标准 ERC20 行为（fee-on-transfer、rebase、false return）
  - 权限边界和治理参数变更（无需真实多链）
  - 清算数学的精确对账（用户/协议份额守恒）
  - 多市场 membership 双向一致性
- 目标：把 P0/P1 大部分先在本地无 fork 跑通，做到秒级到分钟级反馈。

### 第三层：invariant（中成本，抓慢漂移）
- 适合：
  - 长期守恒：会计恒等式、reward conservation、borrowIndex 单调
  - 状态机约束：禁止跃迁（例如有债务时 exitMarket）
- 建议：先缩小 action 集，再逐步扩展；先本地 mock 市场，再上 fork。

### 第四层：fork fuzz（最高成本，最后兜底）
- 适合：
  - 跨链治理时序
  - 真实市场参数耦合、真实价格与流动性环境
  - 仅在前 3 层都稳定后运行
- 建议：
  - 默认小 runs/depth 做冒烟
  - 夜间或 CI 定时跑大规模配置

### 快速决策规则
- 能写成闭式公式或边界不等式：先手推 + unit。
- 依赖外部行为但可模拟：优先 mock，避免 fork。
- 需要验证“长时间 + 多动作”漂移：再上 invariant。
- 必须验证真实链上耦合：最后 fork fuzz。

# Moonwell V2 可疑点清单（仅供人工深挖）

说明：以下均为“值得人工深挖的可疑点”，不是已确认漏洞结论。

## 可疑点 1：清算参数缺少显式边界约束，可能引发系统级会计失真

- 触发前提
  - 攻击者获得或影响治理权限（能够调用 Comptroller 管理参数函数）。
  - 或治理流程本身允许异常参数通过。

- 涉及函数
  - Comptroller._setCloseFactor
  - Comptroller._setLiquidationIncentive
  - 下游受影响路径：Comptroller.liquidateBorrowAllowed、Comptroller.liquidateCalculateSeizeTokens、MToken.liquidateBorrowFresh、MToken.seizeInternal

- 可能破坏的状态关系
  - 单次清算比例关系：maxClose = closeFactor * borrowBalance
  - 清算兑换关系：seizeTokens 与 repayAmount 的比例关系
  - 协议储备和总供应在清算中的变动关系（totalReserves、totalSupply）可能出现非预期放大或收缩。

- 攻击者收益方式
  - 若参数被设得过激，可在短时间内更高效率拿走借款人抵押，放大清算收益。
  - 若参数导致极端行为，攻击者可提前布局头寸后利用参数变化进行定向清算套利。

- 为什么它不是显然的误报
  - 代码中定义了 closeFactorMinMantissa 和 closeFactorMaxMantissa 常量，但 _setCloseFactor 没有显式使用这些边界做 require。
  - _setLiquidationIncentive 同样缺少显式数值范围约束。
  - 这是“参数安全边界未内建”的客观事实，不是凭空猜测。

- 我接下来应该人工检查什么
  - 检查治理层是否有强制参数边界（提案模板、离线脚本、审议流程、Timelock 校验）。
  - 回放历史治理提案，确认是否出现过异常 closeFactor 或 liquidationIncentive。
  - 用极端参数做 fork 仿真，观察清算函数与储备会计是否出现异常。

## 可疑点 2：市场新增健康检查过于“弱语义”，可能放行结构异常市场

- 触发前提
  - 新市场上架流程依赖 MarketAddChecker 作为核心验收标准。
  - 市场实现可满足最低检查条件，但内部经济参数或逻辑存在异常。

- 涉及函数
  - MarketAddChecker.checkMarketAdd
  - MarketAddChecker.checkAllMarkets
  - 测试调用点：SupplyBorrowIntegration.testMarketAddChecker

- 可能破坏的状态关系
  - “市场已正确初始化”被简化为 totalSupply >= 100 且 address(0) 有余额，无法覆盖利率模型、预言机、储备参数、代理实现一致性等关键关系。
  - 可能出现“检查通过但经济关系错误”的假阳性初始化状态。

- 攻击者收益方式
  - 若攻击者推动上架一个表面合规、实则参数危险的市场，可能在后续借贷或清算中提取价值。
  - 收益并非来自 checker 本身，而是来自“薄检查导致的危险市场上线”。

- 为什么它不是显然的误报
  - checker 的源码确实只检查两个条件，且注释目标是“初始化检查”，覆盖面有限是客观存在。
  - 这类问题属于流程防线薄弱，不是纯理论猜想。

- 我接下来应该人工检查什么
  - 梳理真实上架流程中，checker 之外还有哪些必过校验（oracle、interestRateModel、caps、collateral factor、delegate 实现地址等）。
  - 逐个对照历史已上线市场，确认是否存在“checker 通过但关键参数异常”的实例。
  - 为上架流程补充更强静态/动态断言清单。

## 可疑点 3：奖励配置所有者权限可改速度与期限，存在“可治理即可抽干”的激励面

- 触发前提
  - 攻击者控制 emission config owner，或通过 _updateOwner 拿到配置所有权。
  - 奖励池内已有可转移奖励资产，且未被暂停。

- 涉及函数
  - MultiRewardDistributor._updateSupplySpeed
  - MultiRewardDistributor._updateBorrowSpeed
  - MultiRewardDistributor._updateEndTime
  - MultiRewardDistributor._updateOwner
  - 领奖路径：Comptroller.claimReward 与 Distributor 的 disburse 路径

- 可能破坏的状态关系
  - 排放速度与奖励资产库存之间的稳态关系可能被打破。
  - 奖励分配公平性关系可能被所有者参数调整快速偏置到少数地址。

- 攻击者收益方式
  - 攻击者可通过自供给/自借贷头寸配合高排放速度，在短时间内攫取奖励池资金。
  - 若拥有配置迁移权限，可先改 owner 再执行速度和期限操作完成抽取。

- 为什么它不是显然的误报
  - 合约顶部注释明确提示了多 owner/原生资产排放下的抽干风险语义。
  - 相关函数确实允许 owner 级别更新关键排放参数，这是代码事实。

- 我接下来应该人工检查什么
  - 导出每个市场每个 emission token 的当前 owner，确认是否全由可审计治理实体控制。
  - 检查是否有排放变更速率限制、冷却期、告警机制。
  - 统计奖励池余额与当前速度下的可持续时长，识别可瞬时抽干配置。

## 可疑点 4：代理升级面非常强，若治理被接管可直接转为资产接管

- 触发前提
  - 攻击者获得 Unitroller admin 或各市场 MErc20Delegator admin。
  - 可执行实现升级操作。

- 涉及函数
  - Unitroller._setPendingImplementation
  - Unitroller._acceptImplementation
  - Comptroller._become
  - MErc20Delegator._setImplementation

- 可能破坏的状态关系
  - 代理存储与实现逻辑的一致性关系可被替换。
  - 资产账本与权限检查逻辑可在升级后被重定义，导致原会计关系失效。

- 攻击者收益方式
  - 通过恶意实现直接转移底层资产、伪造余额、绕过风控钩子，形成协议级资金接管。

- 为什么它不是显然的误报
  - 这是代理架构的真实高权限攻击面，不依赖猜测漏洞细节。
  - 合约内确实允许 admin 执行实现替换，且本体层未见延迟执行逻辑。

- 我接下来应该人工检查什么
  - 核实升级是否必经 Timelock、多签门限、链上延时、紧急否决机制。
  - 对最近升级历史做差异审计，确认是否有异常实现替换。
  - 评估“治理私钥失陷”下的最大可损失窗口。

## 可疑点 5：奖励发放暂停仅停转账不停累计，可能形成“延迟集中兑现”攻击窗口

- 触发前提
  - 奖励被 pause 一段时间，期间大量交易持续累积 rewardsAccrued。
  - 随后 unpause，且奖励池有足够余额被快速提取。

- 涉及函数
  - MultiRewardDistributor._pauseRewards
  - MultiRewardDistributor._unpauseRewards
  - MultiRewardDistributor.sendReward
  - Comptroller.claimReward

- 可能破坏的状态关系
  - “当期产生、当期发放”的直觉关系失效，变为“长期累计、瞬时释放”。
  - 释放时段的先后次序和 gas 竞速可能改变公平分配体验。

- 攻击者收益方式
  - 攻击者可在暂停期构建高权重头寸，等待解除后优先 claim，获取集中兑现优势。
  - 在高拥堵条件下，先到先得可能形成抢跑收益。

- 为什么它不是显然的误报
  - sendReward 在 paused 状态下明确返回未发送金额并继续累计，是代码确定行为。
  - 风险并非“会不会累计”，而是“累计后释放阶段的博弈与可提取性”。

- 我接下来应该人工检查什么
  - 回放历史 pause/unpause 事件，观察是否存在异常集中领取。
  - 检查 claim 路径是否存在可批量优先提取的脚本化优势。
  - 评估是否需要分批释放、解锁曲线、或解锁后速率限制来降低抢跑影响。

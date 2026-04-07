## 审计线路

### 核心借贷与清算

```bash
1. /home/starkxun/Aduditing-Lab/moonwell-contracts-v2/src/Comptroller.sol
2. /home/starkxun/Aduditing-Lab/moonwell-contracts-v2/src/MToken.sol
3. /home/starkxun/Aduditing-Lab/moonwell-contracts-v2/src/MErc20Delegate.sol
4. /home/starkxun/Aduditing-Lab/moonwell-contracts-v2/src/Unitroller.sol
```
审计目标：确认 mint/borrow/repay/redeem/liquidate 全路径上的权限、边界、会计一致性、暂停开关、cap 限制是否可绕过



### 整体目标

1. [ ] 理清三条关键流: 存款借款流、清算流、治理参数变更流; 每条流标明：谁可调用、依赖哪个外部合约、失败后状态如何
2. [ ] 阅读 integration 和 invariant, 了解开发者默认哪些链路一定成立, 拿到哪些永远不能打破的定义, 列出 gap 清单
3. [ ] 针对 gap 做定向审计, 审计方向包括: 参数误配导致资金冻结/失控、清算边界、预言机精度、奖励会计、跨链消息重放/失序
    
## 新增测试

### 测试 跨市场供应+借款+流动性变化

**基础断言：**
1. `exitMaret` 会先检查 market 是否有未还借款，若有则直接失败
2. 即使没有欠款，也会走 `redeemAllowedInternal` 做整户流动性检查，不满足则失败

**关注点**
1.  不要直接假设有借款就一定不能 exit 抵押市场， 导致整户 shortfall 才应失败
2.  失败路径别只看返回值，还要断言状态没变（membership 仍为 true）
3.  成功路径要与断言双向一致：assetIn 包含关系 与 checkMembership 要完全一致 

测试函数：
```bash
testExitMarketFailsWhenNeededCrossCollateral
```


### 测试 抵押率变更 -> 退出市场失败

**基础断言：**

## 目前已经完成的测试

### **清算相关：**

测试文件路径：test/unit/LiquidationBoundaryMath.t.sol

- [X] 正常清算和超出清算值的异常情况
- [X] 验证清算出来的 seizeToken 是向下取整并且是收紧的
- [X] 测试清算后，借款人损失的抵押品 mToken，必须等于清算人拿到的部分 + 协议抽成的部分

### **转账相关：**

测试文件路径：test/unit/TransferRiskCheck.t.sol

* [X] 没有借款的情况下 ，用户可以转出全部 mToken
* [X] 有借款的情况下，转出全部抵押品必须失败
* [X] 有借款的情况下，转出部分抵押品，只要不超出上限，则允许通过
* [X] 有借款的情况下，转出 safeTokenAmount + 1 必须失败，safeTokenAmount 成功
* [X] 有借款没有流动性的情况下，转出极小的 抵押品数量，会成功
* [X] 转账给自己必须失败
* [X] 转账为 0 时成功
* [X] 转账给 `address(0)` 时通过，资金丢失锁死
* [X] 转账 1 wei 的极端情况必须成功
* [X] transferGuardianPaused = true 时，所有 transfer 都会 revert

发现的异常点：

1. 转账目标地址 0x0 没有 **require**保护，会让用户的 mToken 永久锁死
2. 在 **liquidity == 0**边界上，单次 1 wei 转账由于 **tokensToDenom * 1 / 1e18 = 0** 被风控当作"无影响"放行。一次没事，但在其他配置/可循环调用的场景里值得复查

### **暂停相关：**

测试文件路径：test/unit/PauseCapMatrix.t.sol

* [X] mint 暂停后尝试 mint 必须失败
* [X] mint暂停后不影响 redeem 和 borrow 操作
* [X] borrow 暂停时，Liquidation 必须仍可执行
* [X] Seize 暂停，清算的 Seize 步骤 revert， 整个清算回滚
* [X] Seize 暂停不应该影响 正常用户的 transfer

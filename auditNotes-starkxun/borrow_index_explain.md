## borrowIndex 是什么？

`borrowIndex` 本质上是一个**累计利率倍数**，记录了"从市场创建到现在，1单位本金累计变成了多少"。

---

### 用一个直觉例子理解

假设你把100元存进银行，每年利率10%：

| 年份 | 余额 |
|------|------|
| 第0年 | 100 |
| 第1年 | 110 |
| 第2年 | 121 |
| 第3年 | 133.1 |

银行不需要给每个人单独记录"你是第几年存进来的"，只需要维护一个**全局累计系数**：

| 时间点 | 全局 borrowIndex |
|--------|----------------|
| 初始   | 1.000 |
| 1年后  | 1.100 |
| 2年后  | 1.210 |
| 3年后  | 1.331 |

---

### 用户借款时发生了什么

当你在**第1年**借了 **100 USDC**，合约会快照记录：

```
borrowSnapshot.principal      = 100        // 借款本金
borrowSnapshot.interestIndex  = 1.100      // 借款时的全局 borrowIndex
```

---

### 第3年你欠多少？

```
当前欠款 = principal × 当前borrowIndex / 借款时borrowIndex
         = 100 × 1.331 / 1.100
         = 121
```

这正好是"100元在第1年~第3年之间，以10%复利增长2年"的结果，完全正确。

---

### 对应代码逐行解释

```solidity
// 第一步：principal × 当前全局borrowIndex
(mathErr, principalTimesIndex) = mulUInt(
    borrowSnapshot.principal,   // 用户借款时的本金快照
    borrowIndex                 // 当前市场累计系数（最新值）
);

// 第二步：÷ 用户借款时的borrowIndex快照
(mathErr, result) = divUInt(
    principalTimesIndex,
    borrowSnapshot.interestIndex  // 用户借款时的累计系数快照
);
```

**比值 `当前borrowIndex / 借款时borrowIndex`** 就是"从你借款到现在"这段时间的累计利率，乘以本金就得到当前实际欠款。

---

### 为什么这么设计，而不是直接存余额？

因为链上每个区块都在产生利息，如果给每个用户都实时更新余额，gas 费用不可接受。

用这个设计，**只需要更新一个全局 `borrowIndex`**，每个用户的实时欠款都可以通过上面那个公式按需计算，非常高效。
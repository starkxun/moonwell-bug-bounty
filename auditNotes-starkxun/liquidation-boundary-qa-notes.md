# Liquidation Boundary 对话复习笔记

## 1. `_createShortfallPosition` 的核心作用

目标是构造一个“先健康、后资不抵债”的借款账户，供后续清算边界测试使用。

典型流程：

1. 给 `borrower` 铸造抵押资产（mock token）。
2. `borrower` 把抵押资产存入 `mCollateral`。
3. `borrower` 调 `enterMarkets`，把 `mCollateral` 设为可抵押市场。
4. `borrower` 从 `mBorrow` 借款。
5. 下调抵押品价格，触发 shortfall（资不抵债）。
6. 调 `getAccountLiquidity(borrower)` 验证状态。

---

## 2. 关键变量/函数含义

### `mCollateral` 和 `mBorrow`

- `mCollateral`：抵押品市场，用户把 `collateralUnderlying` 存进去作为抵押。
- `mBorrow`：借款市场，用户从这里借 `borrowUnderlying`。

### `_setPriceOracle(oracle)`

- 作用：给 Comptroller 配置价格预言机。
- 返回值：错误码；`0` 表示成功。

### `_setCollateralFactor`

- 给 `mCollateral` 设置 `0.8e18`：代表抵押折算率 80%。
- 给 `mBorrow` 设置 `0`：代表该市场不作为抵押用途。
- 断言返回 `0`：确认参数设置成功。

### `_seedBorrowMarketCash`

- 作用：先给借款市场注入可借现金池。
- 原因：若 `mBorrow` 市场没有资金，借款会因池子无现金而失败。

---

## 3. 清算机制要点（本次对话重点）

### 不是自动强平，而是“可被主动清算”

当账户出现 `shortfall > 0` 时，协议进入“可清算状态”，但不会自动平仓。
必须有人（liquidator）主动发交易调用清算函数，清算才会发生。

### 为什么要给 `liquidator` 注入资金

清算人需要先拿出借款资产，替借款人偿还部分债务（repay）。
所以测试里要先给 `liquidator` 铸造 `borrowUnderlying`。

### 为什么还要 `approve` 给 `mBorrow`

清算执行时，通常由借款市场合约从清算人账户中 `transferFrom` 扣款。
没有 allowance，市场无法扣到资金，清算交易会失败。

你可以把它理解成：

borrower：欠债的人
liquidator：替他先还一部分债的人
mBorrow：收债的市场合约（会从 liquidator 扣钱）
回报：liquidator 按 liquidation incentive 拿走折价后的抵押品

---

## 4. close factor 边界理解

- `borrowBalance = mBorrow.borrowBalanceStored(borrower)`：读取借款人当前债务（按存储值）。
- `maxClose = borrowBalance * closeFactor / 1e18`：单次清算可偿还上限。

如果测试目标是边界：

1. `repay = maxClose` 应成功。
2. `repay = maxClose + 1` 应失败（超出单次可清算上限）。

---

## 5. 本次对话发现的易错点

1. `shortfall == 0` 不代表可清算。
2. 可清算状态通常应为 `shortfall > 0`。
3. 若价格下跌后理论上已资不抵债，但断言仍写 `assertEq(shortfall, 0)`，语义是反的。
4. 清算授权对象应是执行扣款的市场合约（此场景通常是 `mBorrow`），不是借款人地址。

---

## 6. 一句话复盘

这组测试的核心是：先人为制造 shortfall，再验证 close factor 对单次清算偿还额度的边界约束。
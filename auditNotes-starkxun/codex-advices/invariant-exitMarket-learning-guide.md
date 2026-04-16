# invariant 学习手册：多市场交叉抵押 + exitMarket 状态竞争

适用场景：
- 你已经有集成测试 `testExitAfterCollateralFactorDrop` 能跑通
- 现在想把同一风险面升级为 invariant 测试

目标：
1. 在随机动作序列下持续触发 `enter/mint/borrow/repay/transfer/exit`
2. 验证 `getAssetsIn` 与 `checkMembership` 双向一致
3. 验证参数变更后，`exitMarket` 不会破坏账户状态一致性

---

## 一、先理解 invariant 要测什么

集成测试是：
- 你手工安排一条固定路径
- 断言该路径的结果

invariant 测试是：
- 让 Handler 随机执行很多动作
- 每次动作后都检查不变量是否一直成立

对于本题，不变量核心是：
- 结构 A：`getAssetsIn(user)` 的列表
- 结构 B：`checkMembership(user, market)` 的布尔值

需要满足：
- 正向：A 列表里的市场，B 必须是 `true`
- 反向：B 为 `true` 的市场，A 列表里必须找得到

---

## 二、实现顺序（建议照这个顺序）

### 第 1 步：先只做 membership 双向一致

文件：`test/invariant/BaseInvariant.t.sol`

先把模板函数 `invariant_accountMembershipBidirectionalTemplate` 写实。

最小骨架：

```solidity
function invariant_accountMembershipBidirectionalTemplate() public view {
    address[] memory users = handler.getUsers();
    MToken[] memory markets = handler.getMarkets();

    for (uint256 i = 0; i < users.length; i++) {
        MToken[] memory assetsIn = comptroller.getAssetsIn(users[i]);

        // forward
        for (uint256 j = 0; j < assetsIn.length; j++) {
            assertTrue(
                comptroller.checkMembership(users[i], assetsIn[j]),
                "assetsIn item must have membership=true"
            );
        }

        // reverse
        for (uint256 j = 0; j < markets.length; j++) {
            if (!comptroller.checkMembership(users[i], markets[j])) continue;

            bool found = false;
            for (uint256 k = 0; k < assetsIn.length; k++) {
                if (address(assetsIn[k]) == address(markets[j])) {
                    found = true;
                    break;
                }
            }

            assertTrue(found, "membership=true market must exist in assetsIn");
        }
    }
}
```

建议先只跑这个 invariant，保证通过后再加更复杂断言。

---

### 第 2 步：给 Handler 增加 exit 动作

文件：`test/invariant/Handler.sol`

新增动作：

```solidity
function exitMarket(uint8 userSeed, uint8 marketIndexSeed) external {
    if (markets.length == 0) return;

    address user = _pickUser(userSeed);
    MToken mToken = _pickMarket(marketIndexSeed);

    vm.prank(user);
    comptroller.exitMarket(address(mToken));
}
```

然后在 `BaseInvariant.setUp()` 的 selector 里把它加进去。

关键点：
- 不需要对返回值做 assert（invariant 里动作允许失败）
- 关键是动作执行后，不变量仍然成立

---

### 第 3 步：增加参数扰动动作

文件：`test/invariant/Handler.sol`

新增动作：

```solidity
function setCollateralFactor(
    uint8 marketIndexSeed,
    uint256 newCollateralFactor
) external {
    if (markets.length == 0) return;

    MToken mToken = _pickMarket(marketIndexSeed);
    newCollateralFactor = _bound(newCollateralFactor, 0, 0.9e18);

    vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
    try comptroller._setCollateralFactor(mToken, newCollateralFactor) {
        // no-op
    } catch {
        // no-op
    }
}
```

然后把 selector 也加入 `BaseInvariant`。

关键点：
- 必须用治理身份调用
- 用 `try/catch`，避免单次操作 revert 直接中断整个 fuzz 流

---

### 第 4 步：再加一个 exit 结果一致性 invariant（进阶）

思路：
- 对每个 user 的每个 membership=true 市场
- 先看 `getHypotheticalAccountLiquidity(user, market, balanceOf, 0)`
- 再实际 `exitMarket`（由 Handler 在随机路径里触发）
- invariant 只检查“状态一致性没坏”，不强依赖某次 exit 成败

为什么不直接在 invariant 函数里调用 exit？
- invariant 函数最好是 `view` 检查器
- 变更动作放 Handler，检查器做纯断言，职责更清晰

---

## 三、运行建议

先小轮次：

```bash
FOUNDRY_INVARIANT_RUNS=32 forge test --match-contract BaseInvariant --match-test invariant_accountMembershipBidirectionalTemplate -vv
```

再中轮次：

```bash
FOUNDRY_INVARIANT_RUNS=128 forge test --match-contract BaseInvariant -vv
```

最后大轮次（夜跑）：

```bash
FOUNDRY_INVARIANT_RUNS=512 forge test --match-contract BaseInvariant -vv
```

---

## 四、你最容易踩的坑

1. 动作函数里写了过强断言，导致随机流程被噪声失败淹没。
2. selector 漏加，导致你以为在测 exit，实际根本没覆盖到。
3. invariant 检查器做了状态修改，污染后续回合。
4. 参数扰动没有用 governor 身份，动作一直失败但你没发现。
5. 把 "动作是否成功" 和 "不变量是否被破坏" 混在一起断言。

---

## 五、一个好用的学习路径

1. 只开 `enter/mint/borrow`，把 membership 双向 invariant 跑通。
2. 加 `exitMarket` 动作，观察是否出现 membership 偏移。
3. 再加 `setCollateralFactor` 扰动，检查扰动后仍然双向一致。
4. 最后把 `repay/transfer/warp` 全开，做长时间压力。

按这个顺序，你能清楚知道是哪一类动作引入了问题。
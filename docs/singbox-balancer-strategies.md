# sing-box 负载均衡组：random / roundRobin 与分流规则引用

基于 `feature/chain-failover`（6afd2c8）。Xray 侧的 random / roundRobin 不在本次范围。

## 问题

1. **random / roundRobin 固定走第一个节点**：`_render_singbox_config` 把这两种策略渲染成 `selector`，`default` 为组内第一个节点。没有任何组件切换 selector，所以实际永远走第一个节点，既不随机也不轮询，节点不可用时也不会切走。
2. **分流规则引用组时写错出站名**（改第 1 条时发现）：`gen_singbox_routing_rules` 只转换了 `chain:节点`，`balancer:组名` 原样写进 `route.rules[].outbound`，而组出站的 tag 是 `balancer-组名`。
   - `sing-box check` 不校验规则引用的出站是否存在，所以配置校验和原有测试都通过了。
   - 实际运行时，命中规则的连接报 `router: outbound not found: balancer:组名`，然后直接失败。
   - 所有策略都受影响，包括 leastPing 和 failover。sing-box 的用户路由本来就不支持负载均衡组，所以 sing-box 下的负载均衡组此前从未真正生效。main 分支上也一样。

## sing-box 的能力（1.14）

- 官方文档里的分组出站只有两种：
  - `selector`：只能经 Clash API 切换，不指定时用第一个。
  - `urltest`：按延迟自动选择，检测失败的节点会被排除；全部失败时用第一个（见 v1.14.0 源码 `URLTestGroup.Select`）。
- changelog 里没有负载均衡相关的条目。
- 上游明确不做：SagerNet/sing-box#227（负载均衡）、#2373（随机选择出站）、#4110（给 urltest 加均衡模式）都以 not planned 关闭。

所以内核层面无法做到按连接随机或轮询。

## 修复

讨论过三个方案：
- 映射到 urltest；
- 复用 vless-failover 监控服务，经 Clash API 定时轮换 selector；
- 只改菜单说明。

选了**映射到 urltest**。它不依赖常驻服务和 Clash API，节点不可用时自动切走。运行时轮换只能按时间段分配，做不到按连接分配，改动量也大得多，以后需要真正分摊流量时可以在 urltest 基础上再加。

- **渲染**：random / roundRobin（以及未知策略）和 leastPing 一样渲染为 `urltest`：检测网址 gstatic，每 10 秒一次，容差 50 ms，30 分钟无流量后暂停检测。节点顺序不变，只引用成功生成的节点出站，不需要 Clash API。
- **分流规则**：`balancer:组名` 转换为 `balancer-组名`，和 Xray 一致。failover 组在 sing-box 分流规则中也因此才真正生效。
- **菜单**：
  - 三个创建入口（创建负载均衡组、Alice / Akile 导入）的策略列表都标注"sing-box 协议按最低延迟"；
  - 选择 random / roundRobin 后会额外提示；
  - "查看负载均衡组"界面中，这两种组会标注 sing-box 下的实际行为。

修复后各策略的行为：

| 策略 | Xray | sing-box |
|---|---|---|
| leastPing | 最低延迟（burstObservatory） | urltest：最低延迟，跳过不可用节点 |
| random | 每个连接随机选节点 | urltest（同上） |
| roundRobin | 每个连接轮流选节点 | urltest（同上） |
| failover | 监控服务按优先级指定，全部不可用时直连 | selector + 监控服务经 Clash API 切换 |

## 测试

新增 `tests/singbox-balancer-strategies.sh`，分三部分：

1. **渲染**：
   - 三种策略都是 urltest，节点顺序不变，跳过不存在的节点；
   - 没有 selector，不写 Clash API；
   - 规则引用 `balancer-组名`；
   - 引用完整性断言：规则、分组、final 引用的出站都必须存在（`sing-box check` 不检查这一项）；
   - 用真实 `sing-box check` 校验。
2. **真实运行**：只在本机回环地址上进行，不依赖外网。
   - 启动真实 sing-box，入站换成本机 mixed，检测网址换成本机 HTTP 服务。
   - 组内排第一的节点 B 不可用，节点 A 是另一个真实 sing-box 提供的 SOCKS 服务。
   - 按连接 ID 核对这一个请求：命中规则 → 进入 `balancer-RND` → 经节点 A 送达，且没有走直连。
3. **菜单**：策略列表、选择 random 后的提示、查看界面的标注；leastPing 不应出现标注。

`tests/chain-failover.sh` 的 sing-box 部分增加断言：分流规则引用 `balancer-FO`。

确认测试能抓到问题：只撤掉其中一处修复（或两处都撤掉）时，渲染断言和真实运行都会失败。

| 变体 | 真实运行的失败原因 |
|---|---|
| 只撤掉分流规则修复 | `outbound not found: balancer:RND` |
| 只撤掉 urltest 修复 | selector 固定走不可用的节点 B，连接被拒绝 |
| 两处都不修 | `outbound not found: balancer:RND` |

全量回归（WSL Ubuntu 24.04，Xray 26.11.9，sing-box 1.14.0）：

| | 通过 | 失败 | 跳过 |
|---|---|---|---|
| 基线 feature/chain-failover（6afd2c8） | 59 | 3 | 6 |
| 本分支 | 60 | 3 | 6 |

多出的一项通过是新测试。失败和跳过项和基线逐项相同，都是环境原因（`reality-target.sh`、`core-native.py`、`ss2022-native.py`，见 [upstream-sync-v3.7.20-preview.md](upstream-sync-v3.7.20-preview.md)）。只在第一个修复提交（`6f772de`）上单独跑 `singbox-balancer-strategies.sh` 和 `chain-failover.sh`，也都通过。

## 已知限制（未在本次修改）

- 组内节点全部不存在时，组出站的候选为空，`sing-box check` 报 `missing tags`，整份配置被拒绝。leastPing 原本就有这个问题，Xray 侧会把整组改为直连。
- Xray 的 random / roundRobin 只有配置了 `fallbackTag` 才跳过不可用节点（源码 `app/router/strategy_random.go`、`balancing.go`），当前渲染没有设置，所以 Xray 侧遇到不可用节点也照样会选中它。
- sing-box 下 random / roundRobin 不分摊流量，同一时间只用一个节点。

**未验证**：未在真机上端到端测试 sing-box 分流规则经负载均衡组转发，只做了上述本机回环测试。

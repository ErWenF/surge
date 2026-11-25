# v3.7.20 预览版：同步上游 mozisen/surge v3.7.7 + 链式代理主备故障转移

本版包含两部分：同步上游 v3.7.7 的改动，以及本 Fork 新增的[链式代理主备故障转移](chain-failover.md)。

本 Fork 与上游 [mozisen/surge](https://github.com/mozisen/surge) 自 v3.7.2（`12e9714`，2026-09-26）分叉，各自开发约两个月。上游 74 个提交逐项审阅后，按功能移植到本 Fork，最后用 `git merge -s ours` 记录同步到上游 `dbc16e0`（v3.7.7）。之后再同步上游，只会看到 `dbc16e0` 之后的新提交。

两边版本号各自独立：上游的 v3.7.3～v3.7.7 与本 Fork 同号版本内容不同。本 Fork 继续沿用自己的版本线。

## 新增与修复（来自上游）

- **Mieru 协议**（安装菜单 16）：安装 mita 服务端，生成 mihomo / Clash Meta 分享链接与订阅；二进制同样走发布方 SHA-256 校验。
- **Hysteria2 Salamander 混淆**（可选）：安装 HY2 时询问是否启用；sing-box 入站、分享链接、Surge/Loon/Clash 配置和订阅都带混淆参数。Surge 需 Mac 6.4.3+。
- **Hysteria2 与纯 TCP 协议共用端口号**：HY2 使用 UDP，可与只占 TCP 的协议使用同一端口号。
- **公网 IP 变化检测**：每 30 分钟检测一次；两个探测站结果一致，或连续两次得到同一新地址才确认，然后更新数据库、JOIN 文件和订阅文件，下次打开菜单时提示一次。出口 IP 不等于入口 IP 的机器，可用 `vless --check-ip off` 关闭，`vless --check-ip on` 重新开启。
- **REALITY 链接带 `support-x25519mlkem768=true`**：mihomo v1.19.31+ 直接导入即可连接 Xray 26.9.9+ 的 REALITY 服务端；其他客户端会忽略该参数。
- **Surge VLESS 节点行**：节点信息和 Surge 订阅增加 VLESS REALITY / XHTTP / XHTTP-CDN（Surge iOS 6.0.0+ / Mac 6.12.0+）。
- **真实证书模式下 sing-box 接管 VLESS REALITY**：握手目标改为本机 Nginx 8443，与 Xray 的 dest 一致。之前切换到 sing-box 后会连不上。
- **watchdog 只监管有核心协议的内核**：Snell 等独立协议不会再让 watchdog 反复拉起无配置的核心。升级后首次打开菜单会自动重写一次 watchdog 脚本。
- **统计核心更新**：卸载最后一个 Sing-box 协议后，也能只替换统计核心（带备份），不启动服务。
- **下载校验提示**：区分"校验值不一致"和"取不到校验值"。取不到时提示可能是 API 限流；不一致时警告可能被篡改，不再提示用 `ALLOW_UNVERIFIED_DOWNLOADS` 跳过。
- **po0fw Surge 模块**：指定代理 HEAD 连通性检测与失败重试、日志分级、写入 Logbook；面板支持固定槽 / FIFO 命名和「← 当前」标记。链接仍指向本 Fork，命中判断仍用 /24 匹配。说明见 [po0fw-proxy-check.md](../scripts/po0fw-proxy-check.md)。

## 本 Fork 新功能：链式代理主备故障转移

负载均衡组新增"主备故障转移"策略。节点按优先级使用：第一优先可用就走它，否则用下一个可用节点，全部不可用时走直连；高优先级节点恢复后，连续 3 次检测可用才切回。可在分流规则与用户路由（Xray、sing-box 协议的用户）中使用。

切换由常驻服务 `vless-failover` 在运行时完成，不重启内核。经每个节点访问全部检测网址（默认 gstatic + Cloudflare，可修改）都收到响应才算节点可用，能识别"能上 Google、上不了 Cloudflare"这类半故障节点。

用法、原理、限制和测试见 [chain-failover.md](chain-failover.md)。同一处代码顺带修复：
- Xray 均衡组健康检查改为覆盖组内全部节点。原先只覆盖与第一个节点名前缀相同的节点；只有用户路由时完全不生成健康检查。
- 均衡组不再引用已删除的节点。
- 创建均衡组时拒绝重名。
- sing-box 分流规则指向均衡组时，出口名原先写错（`balancer:组名`，实际 tag 是 `balancer-组名`），运行时命中规则的连接会失败。所有策略都受影响，main 上同样存在，现已修正。

## sing-box 负载均衡组的另两处改进

- **用户路由支持负载均衡组**（含故障转移组）：sing-box 协议的用户可以把路由设为某个组。原先这类设置会被静默忽略，用户实际走默认路由。
- **random / roundRobin 改为按最低延迟选择**：原先在 sing-box 中渲染成 selector，固定使用第一个节点，既不随机也不轮询，节点不可用时也不会切走。sing-box 内核没有随机或轮询出站组，上游明确不计划支持，所以现在和 leastPing 一样渲染为 urltest：跳过不可用节点，选延迟最低的。菜单中已注明。

详见 [singbox-balancer-strategies.md](singbox-balancer-strategies.md)。

## 本 Fork 修复（真机验证中发现）

- **识别 systemd-cron**：部分 Debian 机器用 systemd-cron 代替 cron。它没有 cron 守护进程，由 `cron-update.path` 把 crontab 转成 systemd 定时器。原先的检测只认 cron/crond，于是公网 IP 检测任务放弃写入；流量同步、到期检查等入口还会尝试 `apt-get install cron`，而 cron 与 systemd-cron 互相冲突，会把现有实现替换掉。现在把运行中的 `cron-update.path` 视为可用 cron。

## 全工程复查后的修复（2026-11-25）

- **crontab 内容未变时不再重写**：每次打开菜单都会修复定时任务，原先无论内容是否变化都重写 crontab。在 systemd-cron 上，每次写入都会触发 `daemon-reload` 并重新生成定时器。
- **故障转移探测端口避开其他进程**：原先只避开数据库和配置中的端口。如果 61800 起的端口已被其他程序占用，Xray 会起不来，整次配置变更被回滚。现在也会跳过其他进程正在监听的 TCP 端口；Xray 自己占用的端口不算，避免每次重新生成时端口漂移。
- **监控状态清理**：组不再被任何分流规则或用户路由引用后，旧状态不再保留。原先状态页会一直显示过期结果，以后重新引用时还会沿用过期的出口。
- **节点改名不再误报**：上一轮出口已不在组内（改名、删除或移出组）时静默重新选择，原先会发出"节点不可用，已切换"的通知。
- **异常日志去重**：Xray 未运行、Clash API 不可达等异常持续时，原先每 10 秒写一行日志。现在同一异常只记一次，恢复后记一行，状态页显示"最近异常"。
- 清理监控代码里未使用的分支和变量；每轮检查不再对每个节点单独调用 jq。
- **组内节点以内核配置为准**（真机复测发现）：监控原先从数据库读组内节点，再按配置过滤。节点改名时数据库先更新，配置稍后才重建；检查落在这个间隙时，新名字的节点被当作不存在，监控误切到低优先级节点，约 30 秒后再切回，并发出切回通知。现在直接读取配置中均衡器的候选列表。

### 真机复测（2026-11-25，Debian 12，jq 1.6，Xray 26.3.27）

测试前备份 `/root/surge-backup-20261125-154000.tar.gz`。只用测试节点、测试组和测试用户，原有 4 条分流规则未改动。

| 项目 | 结果 |
|---|---|
| `chain-failover`、`cron-realm-followup`、`cron-systemd-cron`、`singbox-user-balancer` | 在服务器上全部通过（jq 1.6） |
| crontab 不重写 | 升级和再次打开菜单后，crontab 文件修改时间都没有变化，内容与备份一致 |
| 探测端口避让 | 用 python3 占住 61800 后，探测入口分到 61801、61802；Xray 正常启动并监听这两个端口 |
| 日志去重 | 把 API 端口指向未监听端口，连续 4 轮失败，日志只有 1 行；状态页显示"最近异常"；恢复后记一行"检测恢复正常"并清除记录 |
| 节点改名 | 只改数据库、不重建配置时，监控继续使用内核正在用的节点；重建配置后静默选中改名后的节点，没有切换记录和通知 |
| 删除组 | 监控下一轮即清除该组状态 |
| 监控自动重载 | 用临时单元运行监控，把已安装脚本原子替换为多一行注释的版本（版本号仍为 3.7.20）：10 秒内记录"检测到脚本已更新，重新加载"并重新启动监控，PID 不变；换回原文件后再次重载 |
| 恢复 | `config.json`、crontab 与测试前一致；`db.json` 只有真实用户的流量计数增长；测试服务、探测端口、故障转移文件全部清除 |

复测还发现两个问题：
- **同版本更新后监控仍运行旧代码（已修复）**：服务定义只记录版本号。脚本内容变了、版本号没变（如预览版迭代）时，常驻的 `vless-failover` 不会重启，继续运行内存里的旧函数；本次复测中只能手动重启。现在监控每轮检查后查看脚本文件（inode、大小、修改时间），有变化且 `bash -n` 通过就 `exec` 自身重新加载（PID 不变）。语法检查不通过（如文件正在写入）时继续用旧代码，下轮再试。
- **systemd-cron 下读 crontab 也会触发重载（保持现状）**：本机的 systemd-cron 1.15.19 执行只读的 `crontab -l` 也会触发 `cron-update.service`（`daemon-reload` + `restart cron.target`，约 1～2 秒），所以每次打开菜单仍会重载一次。上面的修复去掉了重写，去不掉读取引起的重载。这是 systemd-cron 自身的行为，不影响代理服务。绕开它要直接读各发行版不同的 spool 路径，代价大于收益，所以不处理。
- 只在配置中不存在、数据库中仍存在的组（状态清理针对的情形）在这台服务器上无法构造：有全局分流规则时 Xray 会生成所有组。该情形只在单元测试中验证。

## 本 Fork 已有、未重复移植

- 配额执行、超额恢复、月度重置（上游 v3.7.3）：本 Fork 已有自己的实现与测试（独立 30 天周期、策略执行、事务回滚）。这次另外用真实内核验证了"用户全部停用"时的配置：Xray 生成空 `clients`、sing-box 生成空 `users`，都能通过校验，不会退回默认凭据。
- Xray 用户变更改写其他 VLESS 入站：本 Fork 已改为完整重建配置，只引入了上游的回归测试。
- Bash 5 严格模式自增中断：本 Fork 已修复。
- TG 用户机器人的 cron 准备：本 Fork 已改为常驻服务。

## 暂不移植

- **普通 Shadowsocks（ss-legacy）多用户独立密码**（上游 `7dc30bf`）：本 Fork 目前明确禁止给 ss-legacy 添加用户，不会产生无效链接。要支持多用户，需要在本 Fork 的用户体系（按端口用户、流量检查点、配额与重置）中重新实现，作为后续单独任务。
- 上游的版本号、预览记录、发布说明和根目录临时说明文件；`scripts/backups/` 手工备份。

## 升级注意

- 已有安装打开菜单后，会自动添加公网 IP 检测定时任务（每 30 分钟）。cron 守护进程不存在时不会自动安装软件包，只记录警告。
- 已有 HY2 节点不受影响，只有新安装时才询问是否启用混淆。
- 已导出的 REALITY 分享链接仍然可用；重新导出后带 ML-KEM 参数。
- 已有的 leastPing 负载均衡组：Xray 健康检查现在覆盖组内全部节点，下次重建配置后选择结果可能与之前不同（之前名字不同的节点从未被探测，等于被排除）。
- 不创建故障转移组时，不会启动 `vless-failover` 服务，也不会在 Xray 配置中开启 RoutingService 或探测入口。
- 已有的 sing-box random / roundRobin 组：下次重建配置后从"固定第一个节点"变为"可用节点中延迟最低的"。已有的 sing-box 用户若之前设过负载均衡组路由（原先被忽略），重建配置后开始生效。
- 已知限制：有全局分流规则时，sing-box 会生成所有负载均衡组；某个 leastPing / random / roundRobin 组的节点全部被删除时，即使该组没被使用，整份 sing-box 配置也会被拒绝。这是原有问题，本版不修改。

## 测试结果

2026-11-25，WSL Ubuntu 24.04（Bash 5.2，非 root），逐个运行 `tests/*.sh` 加 `tests/po0-modules.js`。使用真实内核：Xray 26.11.9（官方 Release，`.dgst` 校验）、sing-box 1.14.0 统计版（本 Fork `singbox-stats-binaries` 分支，按 manifest 校验）。

| | 通过 | 失败 | 跳过 |
|---|---|---|---|
| 预览分支，全工程复查修复后（新增断言并入 chain-failover、cron-realm-followup，测试项数不变） | 61 | 3 | 6 |
| 预览分支 `9343f6d`（含故障转移与 sing-box 均衡组改进） | 61 | 3 | 6 |
| 预览分支 `a782a8c`（含故障转移） | 59 | 3 | 6 |
| 预览分支 `68b4107`（仅同步上游） | 57 | 3 | 6 |
| 基线 main `5158655` | 46 | 3 | 5 |

两边失败的是同样 3 项，都由环境造成，与本次改动无关：
- `reality-target.sh`：测试要模拟脚本真实的 443 探测，非 root 无法绑定特权端口。
- `core-native.py` / `ss2022-native.py`：Xray 26.11.9 的 freedom 出站默认拦截回环目标（日志 `target blocked by a finalrule: tcp:127.0.0.1`），测试流量全部发往 127.0.0.1。换成测试针对的 Xray 26.3.27 后，`ss2022-native.py` 在分支和 main 上都通过；`core-native.py` 的 Xray 部分通过，在 sing-box 统计查询处失败，原因是本机没有 grpcurl（两边相同）。

相对 main 多出的 15 项通过就是这次新增的测试：
- 上游的 mieru-install、hy2-udp-port、hy2-salamander（含真实 sing-box 校验混淆配置）、public-ip-change、xray-user-regenerate、surge-vless-reality-config、mihomo-reality-mlkem、watchdog-xray-filter、singbox-reality-handshake、singbox-stats-no-config；
- 本 Fork 新增的 release-verify-rc、cron-systemd-cron、chain-failover、singbox-balancer-strategies（含真实 sing-box 运行）、singbox-user-balancer。

另用真实 sing-box 1.14.0 做了两条链路的运行时验证：分流规则 → 故障转移组 → 链式节点，用户路由 → 故障转移组 → 链式节点（未设路由的对照用户走直连）。两条链路的流量都实际到达了落地节点。

另用真实内核专门验证了"用户全部停用"的配置：sing-box 的 VLESS / Trojan / HY2 / TUIC / AnyTLS 生成空 `users`，Xray 的 VLESS / Trojan 生成空 `clients`，都能通过 `sing-box check` / `xray run -test`，不会退回默认凭据。

已知不稳定：`flock-compat.sh` 要求 30 秒锁超时的实测耗时在 29～31 秒之间，WSL 负载高时 main 上也出现过 32 秒的失败。本轮两边都通过。

### 真机验证（2026-11-25）

服务器：Debian 12（1 核 / 1 GB，systemd + systemd-cron），原有 v3.7.19，运行着 VLESS REALITY、SS2022、2 个链式节点、nginx 真实证书。测试前对脚本、`/etc/vless-reality`、服务文件、nginx、crontab 和防火墙规则做了完整备份。客户端在本地 WSL 运行。

- **升级**：按上面的预览版安装方式升级，3.7.19 自动备份到 `script-backups/`。升级前在隔离目录里用新旧两版渲染 Xray 配置做对比：旧版渲染结果与线上 `config.json` 一致，新版与旧版一致，所以升级不改变运行中的配置。整个验证过程中 Xray 进程始终没有重启。
- **watchdog** 按新逻辑重写并正常运行。
- **公网 IP 检测**：首次运行记录基准地址，数据库里的地址和实际公网 IP 一致，所以没有改写任何内容。在 systemd-cron 上发现检测问题并修复（见上文），修复后 crontab 写入 `*/30` 任务，systemd-cron 生成对应定时器。
- **Mieru**：菜单安装（mita 3.40.0 通过发布方校验），用 Mieru 官方客户端 3.40.0 解析服务器生成的 `mierus://` 链接，参数正确；实际连接后出口 IP 为服务器地址；错误密码被拒绝。
- **HY2 + Salamander**：菜单安装（同时装入 sing-box 1.14.4、grpcurl），用 sing-box 1.14.0 客户端实际连接，出口 IP 为服务器地址；混淆密码错误或不带混淆时都无法连接。
- **REALITY 链接**带 `support-x25519mlkem768=true`；Surge 订阅新增 VLESS REALITY 行，HY2 行带 `salamander-password`；Clash 订阅带 ML-KEM 开关。
- **原有 VLESS REALITY 节点**在全过程后实际连接正常。
- **卸载**两个临时协议后，`db.json`、Xray `config.json`、nginx 配置与测试前完全一致。
- **链式代理故障转移**：用测试用户和真实节点 LC-KDDI、LC-GLBB-Mini 做端到端验证，未改动原有分流规则。
  - 第一优先节点故障后 16 秒切换，并跳过半故障的 LC-KDDI，客户端出口变为 GLBB 的地址；
  - 全部不可用的组改走直连；
  - 节点恢复后连续 3 轮可用才切回；
  - 测试后配置与测试前一致。
  - 真机上发现并修复了 jq 1.6 兼容、单网址误判、删除组被配置事务拒绝三个问题。
  - 详见 [chain-failover.md](chain-failover.md#真机debian-12jq-16xray-26327)。

真机上观察到的原有行为（非本次改动引入）：
- 安装协议时的"安装依赖"步骤会把 openssl、libssl3、jq、dnsutils 升级到最新安全更新。
- 卸载 HY2 / Mieru 后，sing-box、grpcurl、mita 二进制，`mita` 系统用户和已禁用的 `vless-singbox` 服务单元仍保留。

**未验证**：
- 本地 6 项因缺少运行条件而跳过：mieru-live、nft-native、server-ipv6-native、singbox-stats-live（无 grpcurl）、snell-edit-native（无 Snell）、tg-bot-native。
- 公网 IP 变化检测只做了模拟测试和真机首次运行，没有真实换 IP。
- 没有用 Surge / mihomo 客户端实际导入订阅。
- 没有验证"真实证书 + sing-box 接管 VLESS REALITY"的组合。
- po0fw 模块只跑了 Node 回归，没有在 Surge 里运行。

### 测试环境清理复核（2026-11-25）

- 在 Debian 12 测试机上已确认，`/usr/local/bin` 下的 `sing-box`、`grpcurl` 和 `mita` 已清理。`mita` 用户、组及数据目录已移除，systemd 中已无 `vless-singbox`、`vless-mieru` 和 `mita` 单元。
- 清理时曾误删测试前的 Xray 配置快照，随后从当天 11:18:59 的备份恢复。逐项对照该备份，`backups/user-changes/` 下原有的 24 个快照目录、文件内容、属主、属组和权限均一致。当前 Xray `config.json` 也与该备份逐字节一致。
- `/etc/vless-reality` 保留了测试前的全部路径。新增的 6 个文件分别是 cron 锁、IP 检测日志和基准地址、升级前的 3.7.19 脚本备份，以及两个版本缓存标记。测试前和复测前的两份服务器备份仍在。
- 服务器安装的脚本与预览提交 `516f633` 的脚本逐字节一致。Xray、watchdog、Nginx、Docker、fail2ban 均在运行，`nginx -t` 通过，Nginx 正在监听 80 和 443，Xray 正在监听入站端口。此次清理后复核覆盖服务、配置和监听状态，客户端连接结果见前面的真机验证。

## 预览版安装

预览分支：[codex/upstream-sync-v3.7.20](https://github.com/ErWenF/surge/tree/codex/upstream-sync-v3.7.20)。按项目约定，预览版不创建 GitHub Release，也不标记为最新正式版。以 root 执行以下命令，已安装的节点和用户数据会保留：

```sh
wget -O vless-server-preview.sh https://raw.githubusercontent.com/ErWenF/surge/codex/upstream-sync-v3.7.20/vless-server.sh && VLESS_SCRIPT_SOURCE_REF=codex/upstream-sync-v3.7.20 sh vless-server-preview.sh
```

以预览分支运行时，"检查并更新"会从预览分支取脚本。预览分支的版本号就是正式版号 3.7.20（脚本自更新只接受纯数字版本），预览身份由分支名标明。

建议在测试机上依次验证：
1. 用 mihomo 导入 Mieru 订阅实际连接（官方 Mieru 客户端已在真机验证）；
2. 新装一个启用 Salamander 的 HY2，用 Surge / mihomo 实际连接；
3. 已有 REALITY 节点重新导出链接，mihomo 导入后能连接；
4. 打开菜单后确认 `crontab -l` 中出现 `# check-ip` 条目；需要关闭时执行 `vless --check-ip off`；
5. 若有真实证书 + sing-box 接管 VLESS REALITY 的组合，确认切换后客户端能连接；
6. 建一个故障转移组并在分流规则中使用：确认 `vless --failover-status` 显示当前出口，节点故障时切换并收到 TG 通知（TG 通知与 sing-box 故障转移尚未真机验证）。

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

负载均衡组新增"主备故障转移"策略。节点按优先级使用：第一优先可用就走它，否则用下一个可用节点，全部不可用时走直连；高优先级节点恢复后，连续 3 次检测可用才切回。可在分流规则与 Xray 用户路由中使用。

切换由常驻服务 `vless-failover` 在运行时完成，不重启内核。经每个节点访问全部检测网址（默认 gstatic + Cloudflare，可修改）都收到响应才算节点可用，能识别"能上 Google、上不了 Cloudflare"这类半故障节点。

用法、原理、限制和测试见 [chain-failover.md](chain-failover.md)。同一处代码顺带修复：
- Xray 均衡组健康检查改为覆盖组内全部节点。原先只覆盖与第一个节点名前缀相同的节点；只有用户路由时完全不生成健康检查。
- 均衡组不再引用已删除的节点。
- 创建均衡组时拒绝重名。

## 本 Fork 修复（真机验证中发现）

- **识别 systemd-cron**：部分 Debian 机器用 systemd-cron 代替 cron。它没有 cron 守护进程，由 `cron-update.path` 把 crontab 转成 systemd 定时器。原先的检测只认 cron/crond，于是公网 IP 检测任务放弃写入；流量同步、到期检查等入口还会尝试 `apt-get install cron`，而 cron 与 systemd-cron 互相冲突，会把现有实现替换掉。现在把运行中的 `cron-update.path` 视为可用 cron。

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

## 测试结果

2026-11-25，WSL Ubuntu 24.04（Bash 5.2，非 root），逐个运行 `tests/*.sh` 加 `tests/po0-modules.js`。使用真实内核：Xray 26.11.9（官方 Release，`.dgst` 校验）、sing-box 1.14.0 统计版（本 Fork `singbox-stats-binaries` 分支，按 manifest 校验）。

| | 通过 | 失败 | 跳过 |
|---|---|---|---|
| 预览分支 `6afd2c8`（含故障转移） | 59 | 3 | 6 |
| 预览分支 `68b4107`（仅同步上游） | 57 | 3 | 6 |
| 基线 main `5158655` | 46 | 3 | 5 |

两边失败的是同样 3 项，都由环境造成，与本次改动无关：
- `reality-target.sh`：测试要模拟脚本真实的 443 探测，非 root 无法绑定特权端口。
- `core-native.py` / `ss2022-native.py`：Xray 26.11.9 的 freedom 出站默认拦截回环目标（日志 `target blocked by a finalrule: tcp:127.0.0.1`），测试流量全部发往 127.0.0.1。换成测试针对的 Xray 26.3.27 后，`ss2022-native.py` 在分支和 main 上都通过；`core-native.py` 的 Xray 部分通过，在 sing-box 统计查询处失败，原因是本机没有 grpcurl（两边相同）。

相对 main 多出的 13 项通过就是这次新增的测试：
- 上游的 mieru-install、hy2-udp-port、hy2-salamander（含真实 sing-box 校验混淆配置）、public-ip-change、xray-user-regenerate、surge-vless-reality-config、mihomo-reality-mlkem、watchdog-xray-filter、singbox-reality-handshake、singbox-stats-no-config；
- 本 Fork 新增的 release-verify-rc、cron-systemd-cron、chain-failover。

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

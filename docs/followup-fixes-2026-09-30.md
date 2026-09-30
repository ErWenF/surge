# v3.7.6 后续修复与验证

对应 [v3.7.5 后续审计](audit-followup-2026-09-30.md)。本轮优先处理节点脚本，补充 Po0 客户端模块修复。审计编号 1–7、9–16 已有修复和相应回归；第 8 项改善了切换记账，但仍有 API 与停止操作之间无法原子化的窗口。

## 改动及原因

| 文件 / 审计编号 | 修复行为 |
|---|---|
| `vless-server.sh` / 1 | 现有核心配置收紧为 `600`；Sing-box 在私有临时文件中完成渲染再发布；用户变更和分流发布显式保持 `600`。 |
| 同上 / 2 | 停止全部服务使用已有 Snell 分组分派，并核对最终状态。组停止、取消自启跳过已停止、已禁用的成员，兼容 OpenRC 的非零返回。 |
| 同上 / 3–5 | 两个订阅设置入口共用发布、验证和回滚流程；备份订阅配置、UUID、内容及确实要修改的 hosts / 页面。保留已有伪装站点；冲突时拒绝发布。活动 Nginx 使用重载；停用订阅保留 Nginx 原运行状态和其他网站。检查实际活动、自启状态及订阅响应内容，失败恢复原状态。 |
| 同上 / 6–7 | Snell 收集输入、准备依赖时不持数据库锁；提交时重新检查用户名、端口和参数。编辑保存运行、自启、配置及统计快照；只恢复原本运行的实例，失败恢复端口、计数规则和原状态。 |
| 同上 / 8 | 校验后、核心切换前再次采集累计流量；先同步更新回滚数据库，再记账。重启失败恢复时保留这次采集的计量。 |
| 同上 / 9 | cron 增删共用有限等待锁，支持 mkdir 锁回退；读取异常不覆盖任务，仅移除明确的行尾标签。 |
| 同上 / 10 | Xray、Sing-box、Snell 使用相同的用户首个告警阈值；后续只保留高于首档的 90 / 95 档位，保留通知去重。 |
| 同上 / 11–13 | Realm 把 TCP / UDP 选项写入 endpoint 的 `network`；IPv6 地址正确加方括号；统计精确匹配目的端口。界面说明计数链重建会重置统计。 |
| `scripts/po0fw.sgmodule`、`Wifi-po0fw.sgmodule` / 14 | JS 地址指向本仓库；WiFi 模块增加可配置的目标模块名和超时限制。 |
| `scripts/Po0fw.js`、`po0fw-panel.js` / 15 | 使用一致的严格 IPv4 `/24` 判断；保留有效 IPv6 精确匹配；无效地址不认定命中。 |
| `scripts/wifi-module-switch.js` / 16 | 先读取模块状态、避免无效重复写入；处理错误和异步异常；提交后再次读取确认；超时与完成回调只结束一次。保留旧的 SSID 参数格式，支持名称中的 `&`、`%`。 |
| 主脚本 / 冗余、体验 | 合并重复订阅配置生成和后台版本请求；缓存原子发布、同仓库请求去重、失败保留旧缓存。合并相同状态展示分支；逐行订阅导入报告跳过数及原因。 |
| `tests/` | 补充故障、并发、权限、真实进程和网络验证；现有提取式测试加载新增阈值依赖。版本源测试验证版本格式，避免每次版本递增误报。 |

保留原有解析接口、协议兼容路径和可能被外部 source 调用的旧辅助函数。外部 Clash 导入仍是原有 YAML 子集，统一全部解析模型需另行验证兼容性。

## 使用变化

- 订阅的 hosts 映射变为明确选项，默认不添加。只有带 `# vless-sub` 标记的本脚本记录会被更新或清理；旧版本添加的无标记记录和用户记录保留。
- 修改订阅不会删除旧伪装站点。如果已有站点占用相同端口 / 名称，应选其他端口或域名。未通过校验或响应检查时，旧订阅恢复。
- 重设 UUID 在配置加载和订阅响应验证通过后才清理旧目录；订阅路径只暴露当前 UUID 的三个文件。
- 新订阅如需要自签名证书，生成独立的一对证书，避免覆盖节点核心正在使用的证书。备份目录和私钥保持私有；备份应保留用于回滚。
- Snell 编辑提示明确保留原运行状态；修改正在运行的实例仍会短暂断开该实例连接。Xray / Sing-box 变更仍可能重启共享核心，影响同核心其他连接。

## 验证范围

本地使用 LF 副本执行离线回归、ShellCheck error 级检查、Shell / JavaScript 语法检查及 `git diff --check`。服务器使用独立目录 `/root/surge-audit.ozJ10K`，现网服务不参与变更测试。

真实测试程序：Xray 26.3.27、含用户统计的 Sing-box 1.14.0、grpcurl 1.9.4、Realm 2.9.6、Snell 5.0.1、Nginx 1.22.1、Node 22.21.1。Realm / Snell 从官方发布源下载；Nginx 软件包仅在隔离目录解包；Node 校验官方 SHA-256 后提取。没有安装系统软件包、替换现网核心或更新生产脚本。

回归覆盖：

- 非特权 UID 无法读取模拟核心凭据；候选和发布配置权限为 `600`。
- 订阅校验、重载、启动、响应检查失败及站点冲突回滚；UUID、旧文件、hosts 和无关网站保留。
- Snell 四种运行 / 自启组合，配置失败恢复、输入等待时数据库锁可用、陈旧编辑拒绝。真实 Snell 进程和 nft 计数规则的端口修改 / 回滚使用独立网络命名空间。
- cron 并发增删、读取失败、精确标签、mkdir 回退；自定义 70 / 90 告警及去重；版本并发请求去重和失败保留缓存。
- 校验期间新增流量在切换前记账，失败回滚保留已采集量；原有真实核心 TCP / UDP、鉴权、停用、恢复、计量和分流回归。
- 真实 Realm 的 TCP-only、UDP-only、双协议及 IPv6 监听；真实 Nginx 的三种订阅响应、未知 UUID 拒绝、实际健康探测和其他站点重载连续性。
- Node VM 验证 Po0 网段匹配、面板错误、WiFi 切换成功 / 失败 / 不生效 / 异步异常及一次完成；不使用真实 Token、不请求真实 Po0 API。

服务器完整回归和重点重复验证的最终结果及现场一致性检查保存在 `verified.log`、`verified.exit`。测试过程中的较早日志也保留，不能替代最终结果。OpenRC 模拟曾被宿主 Xray 状态兜底干扰，已收紧为只检查 Snell 组；新增混合订阅用例曾污染后续 Base64 用例输入，已补齐独立输入。这两项是测试隔离修正。

最终结果：完整 **32 项 Shell 测试、3 项 Python 原生测试程序和 Po0 Node VM 用例通过，退出码 0，跳过项 0**；新增事务、cron / Realm、版本缓存、真实 Snell 编辑及 Po0 用例另做两轮重点复测。最后把 Realm / Snell / Nginx 原生探测全部置于独立网络命名空间，三轮复核通过，记录在 `namespace-final.log`、`namespace-final.exit`。

所列现网脚本、Xray 二进制、数据库、配置、hosts、resolv.conf 的哈希前后相同；systemd / init.d / cron.d 文件清单、root crontab 及服务活动状态、PID、重启次数一致。Xray 保持 active、PID 60000、NRestarts 0；cron 保持 active、PID 701；未发现匹配本轮探测路径的残留主进程。这些检查覆盖明确列出的文件和服务，不表示扫描全部服务器状态。

## 复核命令

```bash
cd /root/surge-audit.ozJ10K/repo
export XRAY_BIN=/usr/local/bin/xray
export SINGBOX_BIN=/root/surge-core-review.lOT5vG/stats-bin/bin/sing-box
export SINGBOX_TEST_BIN="$SINGBOX_BIN"
export GRPCURL_TEST_BIN=/root/surge-core-review.lOT5vG/stats-bin/bin/grpcurl
export REALM_TEST_BIN=/root/surge-audit.ozJ10K/bin/realm
export SNELL_TEST_BIN=/root/surge-audit.ozJ10K/bin/snell-server
export NGINX_TEST_BIN=/root/surge-audit.ozJ10K/nginx-root/usr/sbin/nginx
export NFT_NATIVE_TEST=1
export PATH=/root/surge-audit.ozJ10K/bin:/root/surge-core-review.lOT5vG/stats-bin/bin:$PATH
bash tests/run.sh
```

## 剩余边界

- 最后一次统计 API 返回与核心停止之间仍可新增流量；此实现缩短原有漏计窗口并保护回滚统计，**不保证严格零漏计**。严格计费需要核心支持可原子停止的统计，或采用独立、持续的计量来源。
- OpenRC 使用模拟接口检查，未启动真实 Alpine 系统；Snell 验证真实服务器进程与内核规则，systemd unit 安装和真实 Surge 握手未执行。
- Surge 仅验证 JS 与官方 [模块控制 API](https://manual.nssurge.com/tools/http-api.html) 的数据结构，尚无 iOS / macOS Surge 真机验证及真实 Po0 Token 验证。
- Realm 目前统计仍来自 IPv4 iptables 入站计数，IPv6 本轮验证的是配置和监听。
- 本脚本的 cron 锁无法约束外部工具直接覆盖 crontab。文件回滚覆盖正常失败；断电、SIGKILL 和回滚介质故障仍可能需要根据私有备份手工恢复。

后续维护建议沉淀到 `lessons.md`：多实例协议新增或修改时逐一检查停止、暂停、自启、编辑、卸载与状态入口；状态兜底应在模拟测试中隔离宿主进程；新增用例显式重置共用输入。本轮未修改协作规则。

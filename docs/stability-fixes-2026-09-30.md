# v3.7.5 稳定性修复与验证

日期：2026-09-30。业务基线：`5bc4020`（v3.7.4）；问题依据见 [审查记录](audit-2026-09-30.md)。本次保留目录、协议功能和依赖版本，集中修复确定的失败路径。

## 修改内容

| 文件 | 修复 |
| --- | --- |
| `vless-server.sh` | Snell 停用必须检查 stop、disable 及实际状态；用户启停失败恢复数据库、配置、unit 和原运行/自启状态，回滚失败明确报错。 |
| `vless-server.sh` | 全局分流在修改前持锁备份，两个核心候选均通过原生校验后才写入活动配置并重启；失败恢复旧数据库和两个配置，只恢复已尝试重启的服务，原停止核心保持停止。菜单按事务结果反馈。 |
| `vless-server.sh` | 手动清零先同步累计计数，再重置所选用户；同步失败不清零。Snell 拆出仅记账入口，避免清零顺带执行其他用户配额或改变服务状态。 |
| `vless-server.sh` | 订阅先生成全部候选，再逐文件原子发布；生成失败保留原文件，发布中途失败回滚已替换文件。相关订阅设置/刷新入口检查返回码。 |
| `vless-server.sh` | Base64 解码必须成功才采用结果；Clash 中间/末尾 VLESS 节点复用同一转换，区分 TLS、Reality 和明文，保留 WS path/host 并正确处理 IPv6。 |
| `vless-server.sh` | 订阅元数据完整验证后才赋值，缺失/重复/非法字段不会部分覆盖调用者；通过同目录临时文件原子写入，权限为 600。 |
| `vless-server.sh`、`nft.sh` | 算术前限制端口/IPv4 段长度，避免整数溢出；复用严格地址校验并拒绝 IPv6 末尾孤立冒号。保持主脚本接受五位以内前导零、nft 脚本拒绝前导零的原策略。 |
| `vless-server.sh` | 到期 cron 安装失败显式返回非零，CLI 传播退出码；通用用户字段读取保留合法的 `false`。 |
| `nft.sh` | 候选先校验；本工具表的 delete/create 放在同一个 nft batch 中，失败不清空旧运行规则并恢复持久化文件，其他表不变。清空成功后才关闭对应防火墙放行。初始配置创建不残留待提交标记。 |
| `tests/` | 新增五项回归；补齐原有 Snell 测试的记账依赖、月重置测试的告警函数及阈值持久化/通知去重断言、cron CLI 失败断言。 |

两个核心依然使用已有配置生成器和事务校验逻辑。没有删除候选“无调用函数”、统一全部订阅解析器、升级核心或安装依赖；这些精简工作可独立评估。

## 验证结果

- 本地 LF 副本：全部 Shell 语法检查通过；3 个 JavaScript 文件通过 `node --check`，2 个 Python 文件通过 AST 检查；ShellCheck 0.11.0 没有 error 级诊断，`git diff --check` 通过。
- 本地完整离线回归通过；不带原生二进制的测试明确跳过对应原生项目，不作为服务器实测替代。
- 服务器 `wawo-hk-pis`：Debian 12；复用 Xray 26.3.27、含 `with_v2ray_api` 的 Sing-box 1.14.0 和 grpcurl 1.9.4。所有文件和测试进程使用隔离目录或临时目录。
- 服务器完整回归：**28 项 Shell 测试及 2 项 Python 原生测试通过，退出码 0，跳过项 0，`command not found` 0**。覆盖 TCP/UDP、鉴权、用户停用/恢复、多端口隔离、出口故障拒绝连接、上下行计量及重复同步。
- nft 原生测试使用 `unshare --net`：校验失败及内核拒绝 batch 均保留旧规则；成功后旧规则被替换，独立 sentinel 表保持一致。没有在现网命名空间测试规则变更。
- 故障注入覆盖 Snell stop 返回失败/虚假成功、disable/start 失败、两核第二次校验/重启失败、统计 API 失败、订阅生成/中途发布失败、元数据写入失败和 cron 安装失败。
- 告警回归在补齐真实 getter/setter 后断言阈值持久化，并确认重复同步只产生一次通知。
- 测试前后现网数据库、Xray 配置、系统脚本及 `/etc/resolv.conf` 的 SHA-256 一致；Xray 仍 active、PID 60000、NRestarts 0；Sing-box/watchdog 仍 inactive；cron 仍 active、PID 701。无残留测试核心进程。

第一轮原生计量测试因测试启动环境未将既有 grpcurl 加入 PATH 而失败；补齐 PATH 后完整重跑通过，没有为此安装依赖或改动生产环境。

## 复现命令与保留证据

服务器保留目录：`/root/surge-audit.stability.EiaqEG`。

```bash
cd /root/surge-audit.stability.EiaqEG/repo
export XRAY_BIN=/usr/local/bin/xray
export SINGBOX_BIN=/root/surge-core-review.lOT5vG/stats-bin/bin/sing-box
export SINGBOX_TEST_BIN="$SINGBOX_BIN"
export GRPCURL_TEST_BIN=/root/surge-core-review.lOT5vG/stats-bin/bin/grpcurl
export PATH=/root/surge-core-review.lOT5vG/stats-bin/bin:$PATH
export NFT_NATIVE_TEST=1
bash tests/run.sh
```

完整日志/退出码为 `full-final.log`、`full-final.exit`；最终补充检查为 `supplemental.log`、`supplemental.exit`；配置哈希和服务状态保存在 `live-before.sha256`、`services-before.txt`、`services-final.txt`。仓库文件不包含服务器登录凭据。

## 验证边界

- 服务器尚未部署 v3.7.5，只运行隔离测试；没有修改现网 systemd、cron、防火墙、SSH、Nginx 或核心二进制。
- 真实 Snell 服务及 unit 恢复、Alpine/OpenRC 尚未实测；Snell 故障场景使用文件/服务状态模拟，不能宣称覆盖所有部署环境。
- 订阅逐文件原子替换，不是三个文件同时切换；断电、进程被强制终止及发布期间并发读取的整代一致性未覆盖。正常生成/发布错误有回滚，回滚再次失败会保留备份并报错。
- 外部 Clash 导入仍支持原来的行式 YAML 子集，没有扩展到任意 YAML 语法。第三方订阅、ACME、WARP、Cloudflare、QUIC 客户端完整链路不在本轮范围。
- 校验和回归证明上述环境/场景通过，不能保证所有系统故障下绝无副作用。事务备份可用于排障；后续批量精简应另建回归和提交。

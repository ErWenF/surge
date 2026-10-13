# v3.7.14 下载校验与 Reality 超时修复

基线：`cddca18`（v3.7.13）。本轮已同步远端到本地；修改集中在两个辅助函数，未调整数据库格式、协议配置生成或依赖版本。

## 修改及原因

- 下载校验按完整资产文件名匹配。原来的子串匹配可能误用同名 `.sig` 或其他相似文件的校验值。
- 通用 checksum 解析不用 awk 的区间正则，兼容 BusyBox；支持 GNU 文本/二进制标记、`./` 前缀、BSD `SHA256` / `SHA2-256`、大写和 CRLF。目标文件的校验记录缺失、重复或 SHA-256 格式不合法时拒绝安装。
- 保留 Xray 官方 `.dgst` 和 GitHub 资产 `digest` 的既有校验路径。
- Reality 检测的原生 `timeout` 使用经能力探测的 `--foreground`，让监护进程在 KILL 后回收直接子进程；不支持时使用已有 Bash 回退。该函数用于限时运行 curl / OpenSSL，不参与线上核心启动。
- 新增下载校验回归，补充真实 BusyBox timeout 回退及子进程回收断言。
- IPv6 离线测试在模拟无本机地址时，同时隔离内核接口状态；避免 `/proc` 回退读取宿主机真实公网 IPv6。这是测试修正，未修改地址发现逻辑。

## 验证

- 本地旧代码复现 checksum 错误接受；修复后的专项通过。修改的 Shell 文件语法、Python AST 和 `git diff --check` 通过。
- HK `103.192.179.234`（`wawo-hk-pis`）隔离目录：`/root/surge-checksums-20261013.vxWR6k`。GNU / BusyBox 通用 checksum 专项和 BusyBox Xray checksum 专项均通过；错误校验值不会触发核心替换。
- Reality 专项通过：原生、缺少 timeout、不支持参数、真实 BusyBox 四种场景下，抵抗 TERM 的命令均被终止并立即回收，且保留正常完成命令的退出码。
- 第一轮完整回归在进程回收断言处失败，已保留 `results-first.log`；修复没有放宽断言。第二轮在 IPv6 测试隔离处失败，记录为 `results-second.log`；修正后的 IPv6 专项在本地和 HK 均通过。
- 第三轮完整回归退出码 **0**：41 项 Shell 测试、3 项 Python 原生测试程序及 Po0 Node VM 用例通过；另外两个 Shell 测试入口明确跳过，分别为真实 IPv6 接口测试和实际 Xray 发布压缩包校验测试。最终日志和退出码为 `results-verified.log`、`test-verified-exit`。
- 真实 Xray 26.3.27 / Sing-box 1.14.0 验证 TCP、UDP、双向计量、用户停用/恢复、30 天流量周期、端口隔离及出口不可用时拒绝连接。HY2 / TUIC 通过原生配置检查，不代表客户端端到端测试。Realm 验证 TCP / UDP / IPv6 监听；Snell 验证配置及监听；Nginx 验证订阅响应及其他站点的重载连续性。
- 测试前后现网脚本、Xray 二进制、数据库、Xray 配置、`resolv.conf`、`hosts` 的 SHA-256 一致；服务状态、PID、重启次数和 root crontab 一致。Xray 保持 active、PID 468066、NRestarts 0；Sing-box / watchdog 保持 inactive；cron 保持 active、PID 701。
- 本地待提交脚本和三个测试文件的 LF 内容 SHA-256 与服务器实测副本一致。主脚本 SHA-256：`8cc158c0415d6f1592beb90b9b01e62d05ef55c58268b9a255ae1679c5bfc99d`。

## 验证边界

- 测试使用隔离配置、测试进程及独立网络命名空间；尚未部署本轮脚本，也未 push 或修改 Git remote。
- BusyBox 应用程序已实测，完整 Alpine / OpenRC 系统尚未实测。
- HY2 / TUIC 客户端端到端测试继续按此前安排暂缓。测试通过的项目不能替代这些协议的实际连通性验证。
- 真实 IPv6 接口创建和实际 Xray 发布压缩包验证未执行；Snell 未进行 Surge 客户端握手。本轮下载校验测试模拟发布元数据及下载文件，不声称已重新下载并安装所有官方核心。

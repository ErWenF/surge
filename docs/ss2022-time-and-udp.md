# SS2022 校时与 UDP 回程

安装 SS2022 时，主脚本会检查持续校时服务。已有运行中的 NTP 服务会保留；没有服务时，systemd 系统优先启用已安装的 `systemd-timesyncd`，否则安装 `chrony`；Alpine 也使用 `chrony`。这些服务开机自启并持续同步，不需要额外的定时任务。也可单独执行：

```sh
vless --ensure-time-sync
```

可通过 `VLESS_NTP_SERVERS` 指定空格分隔的 NTP 地址；已运行的校时服务保持原配置。默认沿用发行版配置；网络不能解析 NTP 域名的机器可传入经本地网络验证可达的 NTP IP。例如：

```sh
VLESS_NTP_SERVERS='192.0.2.10 192.0.2.11' vless --ensure-time-sync
```

`timedatectl show -p NTPSynchronized --value` 应返回 `yes`。首次同步可能需要一段时间；命令在约一分钟内仍未确认同步时会报错，不会自动修改系统 DNS 或其他代理服务。

容器内通常无权调整系统时钟。检测到未运行校时服务的 systemd 容器时，脚本会提示在宿主机启用校时，不在容器内安装无效的服务。

如果服务器另有策略路由，且抓包确认 SS2022 UDP 回复走错网卡，可以单独安装精确的回程规则。先确认正确出口位于 `main` 路由表，然后执行：

```sh
sh scripts/ss2022-udp-return.sh install CLIENT_IPV4 UDP_SOURCE_PORT PRIORITY
sh scripts/ss2022-udp-return.sh status CLIENT_IPV4 UDP_SOURCE_PORT PRIORITY
sh scripts/ss2022-udp-return.sh remove CLIENT_IPV4 UDP_SOURCE_PORT PRIORITY
```

该规则只匹配发往指定客户端 IPv4、源端口为指定 SS2022 UDP 端口的回复，查找 `main` 路由表。优先级必须空闲且高于错误的宽泛策略规则。工具通过 systemd 或 OpenRC 持久化，核心服务无需重启。不同内核或旧版 `iproute2` 如不支持 `ipproto` 与 `sport`，安装会失败，不会退化成宽泛规则。它不适用于所有 UDP 故障：须先双端抓包确认回程异常。

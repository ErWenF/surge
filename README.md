在Zyx0rx大佬基础上维护，问题反馈：  
  
[![Telegram](https://img.shields.io/badge/Telegram-@vless__vaio-26A5E4?logo=telegram&logoColor=white)](https://t.me/vless_vaio)  

vless脚本使用方法（以 root 在 Alpine、Debian、Ubuntu 或 CentOS 上运行）：

```sh
sh -c '
set -e
url=https://raw.githubusercontent.com/ErWenF/surge/main/vless-server.sh
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o vless-server.sh "$url"
elif command -v wget >/dev/null 2>&1; then
    wget -O vless-server.sh "$url"
else
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates
    else
        echo "错误: 未找到下载工具或受支持的包管理器" >&2
        exit 1
    fi
    curl -fsSL -o vless-server.sh "$url"
fi
exec sh vless-server.sh
'
```
快捷命令
```bash
vless
```

SS2022 持续校时与特殊策略路由下的 UDP 回程处理见 [说明](docs/ss2022-time-and-udp.md)。

nft脚本使用方法：
```bash
curl -L https://raw.githubusercontent.com/mozisen/surge/main/nft.sh -o nft.sh  
chmod +x nft.sh  
./nft.sh  
```

快捷命令：    
```bash  
nftm
```

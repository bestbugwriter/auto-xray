# Xray Reality Installer

运行 `sudo ./setup_xray_reality.sh <服务器域名或IP>` 即可自动安装 Xray 并生成服务端与客户端配置。
脚本会写入 `/usr/local/etc/xray/config.json`，并在当前目录输出 `client_config.json` 与对应的 `vless://` 链接。
本地 Socks5/HTTP 代理会随机生成用户名与密码，可在日志和生成的配置中查看。

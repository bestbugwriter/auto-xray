# Xray Reality Installer

运行 `sudo ./setup_xray_reality.sh <服务器域名或IP>` 即可自动安装 Xray 并生成服务端与客户端配置。
默认情况下脚本会写入 `/usr/local/etc/xray/config.json`，并在当前目录输出 `client_config.json` 与对应的 `vless://` 链接。
本地 Socks5 代理提供两个端口：10800（无需认证）与 10802（需认证，会随机生成用户名与密码），HTTP 代理端口 10801 同样会随机生成用户名与密码，可在日志和生成的配置中查看。
如需修改本地代理监听地址，可使用 `--proxy-listen 127.0.0.1` 之类的参数覆盖默认的 `0.0.0.0`。

若需指定 REALITY 的 SNI，可追加 `--sni example.com` 参数；未指定时脚本会从内置列表随机选择。也可通过 `--uuid`、`--private-key`/`--public-key`、`--short-id`、`--proxy-user`、`--proxy-pass` 参数自定义生成的配置值，未提供时脚本会自动生成。

若 Xray 已安装且只需在当前目录生成配置，可执行 `./setup_xray_reality.sh <服务器域名或IP> --auto-config`。脚本会输出 `server_config.json` 与 `client_config.json`，不会尝试安装或重启 Xray 服务。

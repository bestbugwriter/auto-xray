#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SNI_LIST=(
  "www.microsoft.com"
  "www.apple.com"
  "www.amazon.com"
  "www.cloudflare.com"
  "www.bing.com"
)

SERVER_TEMPLATE_FILE="${SCRIPT_DIR}/server_template.json"
CLIENT_TEMPLATE_FILE="${SCRIPT_DIR}/client_template.json"
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"
SERVER_CONFIG_FILE_OUT="${SCRIPT_DIR}/server_config.json"
CLIENT_CONFIG_FILE_OUT="${SCRIPT_DIR}/client_config.json"
LOG_FILE="${SCRIPT_DIR}/setup_xray.log"

log() {
  local message="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | tee -a "$LOG_FILE"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
  local dependencies=("curl" "bash" "openssl" "uuidgen" "jq")
  local missing=()

  for cmd in "${dependencies[@]}"; do
    if ! command_exists "$cmd"; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    log "错误：缺少必要的依赖：${missing[*]}"
    log "请先安装它们 (例如: apt update && apt install curl openssl uuid-runtime jq)"
    exit 1
  fi

  if [ ! -f "$SERVER_TEMPLATE_FILE" ]; then
    log "错误：找不到服务端模板文件：$SERVER_TEMPLATE_FILE"
    exit 1
  fi

  if [ ! -f "$CLIENT_TEMPLATE_FILE" ]; then
    log "错误：找不到客户端模板文件：$CLIENT_TEMPLATE_FILE"
    exit 1
  fi
}

generate_uuid() {
  uuidgen
}

generate_keypair() {
  if ! command_exists xray; then
    log "错误：找不到 'xray' 命令，请先完成 Xray 安装。"
    exit 1
  fi
  xray x25519
}

generate_shortid() {
  openssl rand -hex 8
}

generate_proxy_secret() {
  openssl rand -hex 6
}

select_sni() {
  local index=$((RANDOM % ${#SNI_LIST[@]}))
  echo "${SNI_LIST[$index]}"
}

generate_server_config() {
  local uuid="$1"
  local private_key="$2"
  local short_id="$3"
  local sni="$4"
  local output_file="${5:-$XRAY_CONFIG_FILE}"
  local dest="${sni}:443"

  mkdir -p "$(dirname "$output_file")"

  jq \
    --arg uuid "$uuid" \
    --arg dest "$dest" \
    --arg sni "$sni" \
    --arg private "$private_key" \
    --arg short "$short_id" \
    '(.inbounds[0].settings.clients[0].id) = $uuid
     | (.inbounds[0].streamSettings.realitySettings.dest) = $dest
     | (.inbounds[0].streamSettings.realitySettings.serverNames) = [$sni]
     | (.inbounds[0].streamSettings.realitySettings.privateKey) = $private
     | (.inbounds[0].streamSettings.realitySettings.shortIds) = [$short, ""]' \
    "$SERVER_TEMPLATE_FILE" > "$output_file"
}

generate_client_config() {
  local server_address="$1"
  local uuid="$2"
  local public_key="$3"
  local short_id="$4"
  local sni="$5"
  local account_user="$6"
  local account_pass="$7"

  jq \
    --arg address "$server_address" \
    --arg uuid "$uuid" \
    --arg public "$public_key" \
    --arg sni "$sni" \
    --arg short "$short_id" \
    --arg user "$account_user" \
    --arg pass "$account_pass" \
    '(.outbounds[] | select(.tag == "proxy").settings.vnext[0].address) = $address
     | (.outbounds[] | select(.tag == "proxy").settings.vnext[0].users[0].id) = $uuid
     | (.outbounds[] | select(.tag == "proxy").streamSettings.realitySettings.serverName) = $sni
     | (.outbounds[] | select(.tag == "proxy").streamSettings.realitySettings.publicKey) = $public
     | (.outbounds[] | select(.tag == "proxy").streamSettings.realitySettings.shortId) = $short
     | (.inbounds[] | select(.tag == "socks-in").settings.auth) = "password"
     | (.inbounds[] | select(.tag == "socks-in").settings.accounts) = [{user: $user, pass: $pass}]
     | (.inbounds[] | select(.tag == "http-in").settings.accounts) = [{user: $user, pass: $pass}]' \
    "$CLIENT_TEMPLATE_FILE" > "$CLIENT_CONFIG_FILE_OUT"
}

generate_vless_link() {
  local server_address="$1"
  local uuid="$2"
  local public_key="$3"
  local short_id="$4"
  local sni="$5"
  local remark="${server_address}_REALITY"

  local remark_encoded
  remark_encoded=$(printf '%s' "$remark" | jq -sRr @uri)

  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$uuid" "$server_address" "$sni" "$public_key" "$short_id" "$remark_encoded"
}

restart_xray_service() {
  if command_exists systemctl; then
    if systemctl restart xray; then
      log "Xray 服务已通过 systemctl 重启。"
      systemctl status xray --no-pager >/dev/null 2>&1 || log "警告：无法获取 Xray 服务状态，请手动检查。"
    else
      log "警告：通过 systemctl 重启 Xray 失败，请手动检查服务状态。"
    fi
  elif command_exists service; then
    if service xray restart; then
      log "Xray 服务已通过 service 重启。"
      service xray status >/dev/null 2>&1 || log "警告：无法获取 Xray 服务状态，请手动检查。"
    else
      log "警告：通过 service 重启 Xray 失败，请手动检查服务状态。"
    fi
  else
    log "警告：未检测到 systemctl 或 service，无法自动重启 Xray，请手动重启。"
  fi
}

usage() {
  cat <<EOF
用法: $(basename "$0") <服务器域名或IP> [--auto-config]
  --auto-config    已安装 Xray 的情况下使用，只在当前目录生成服务端和客户端配置文件，不执行安装或服务重启操作。
EOF
}

AUTO_CONFIG_ONLY=false
SERVER_ADDRESS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-config)
      AUTO_CONFIG_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -* )
      echo "错误：未知参数：$1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -z "$SERVER_ADDRESS" ]; then
        SERVER_ADDRESS="$1"
        shift
      else
        echo "错误：检测到多余的参数：$1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [ -z "$SERVER_ADDRESS" ]; then
  echo "错误：请提供服务器的公网 IP 地址或域名作为第一个参数。" >&2
  usage >&2
  exit 1
fi

if [[ $EUID -ne 0 && "$AUTO_CONFIG_ONLY" != true ]]; then
  echo "错误：请以 root 身份运行此脚本。" >&2
  exit 1
fi

rm -f "$LOG_FILE"

log "开始执行 Xray VLESS + REALITY 自动化配置。"
log "服务器地址/域名：$SERVER_ADDRESS"

if [ "$AUTO_CONFIG_ONLY" = true ]; then
  log "已启用 --auto-config 模式：仅在当前目录生成配置文件，不执行安装或服务重启操作。"
fi

check_dependencies

if ! command_exists xray; then
  if [ "$AUTO_CONFIG_ONLY" = true ]; then
    log "错误：检测到未安装 Xray，请先安装 Xray 后再使用 --auto-config 参数。"
    exit 1
  fi
  log "Xray 未安装，正在安装..."
  if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    log "Xray 安装完成。"
  else
    log "错误：Xray 安装失败。"
    exit 1
  fi
else
  log "检测到 Xray 已安装，跳过安装步骤。"
fi

log "正在生成配置信息..."
UUID=$(generate_uuid)
KEYPAIR_OUTPUT=$(generate_keypair)
PRIVATE_KEY=$(echo "$KEYPAIR_OUTPUT" | grep 'Private key:' | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYPAIR_OUTPUT" | grep 'Public key:' | awk '{print $3}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  log "错误：生成 REALITY 密钥对失败。"
  exit 1
fi

SHORT_ID=$(generate_shortid)
SELECTED_SNI=$(select_sni)
PROXY_USER=$(generate_proxy_secret)
PROXY_PASS=$(generate_proxy_secret)

log "UUID：$UUID"
log "Public Key：$PUBLIC_KEY"
log "Short ID：$SHORT_ID"
log "选择的 SNI/Dest：$SELECTED_SNI"
log "本地代理用户名：$PROXY_USER"
log "本地代理密码：$PROXY_PASS"

SERVER_CONFIG_DEST="$XRAY_CONFIG_FILE"
if [ "$AUTO_CONFIG_ONLY" = true ]; then
  SERVER_CONFIG_DEST="$SERVER_CONFIG_FILE_OUT"
fi

generate_server_config "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SELECTED_SNI" "$SERVER_CONFIG_DEST"

if [ "$AUTO_CONFIG_ONLY" = true ]; then
  log "服务端配置已生成：$SERVER_CONFIG_DEST"
else
  log "服务端配置已写入：$SERVER_CONFIG_DEST"
  restart_xray_service
fi

generate_client_config "$SERVER_ADDRESS" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SELECTED_SNI" "$PROXY_USER" "$PROXY_PASS"
log "客户端配置已生成：$CLIENT_CONFIG_FILE_OUT"

VLESS_LINK=$(generate_vless_link "$SERVER_ADDRESS" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SELECTED_SNI")

log "-----------------------------------------------------"
log "配置完成。"
log "服务端配置文件路径：$SERVER_CONFIG_DEST"
log "客户端配置文件路径：$CLIENT_CONFIG_FILE_OUT"
log "VLESS 链接如下："

echo ""
echo "$VLESS_LINK" | tee -a "$LOG_FILE"
echo ""

log "-----------------------------------------------------"
log "Socks5/HTTP 代理用户名：$PROXY_USER"
log "Socks5/HTTP 代理密码：$PROXY_PASS"
log "提示：请确认服务器防火墙已开放 TCP 443 端口。"
if [ "$AUTO_CONFIG_ONLY" = true ]; then
  log "提示：请手动将生成的服务端配置应用到 Xray。"
fi
log "脚本执行完毕。"

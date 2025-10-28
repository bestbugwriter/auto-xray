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

select_sni() {
  local index=$((RANDOM % ${#SNI_LIST[@]}))
  echo "${SNI_LIST[$index]}"
}

generate_server_config() {
  local uuid="$1"
  local private_key="$2"
  local short_id="$3"
  local sni="$4"
  local dest="${sni}:443"

  mkdir -p "$(dirname "$XRAY_CONFIG_FILE")"

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
    "$SERVER_TEMPLATE_FILE" > "$XRAY_CONFIG_FILE"
}

generate_client_config() {
  local server_address="$1"
  local uuid="$2"
  local public_key="$3"
  local short_id="$4"
  local sni="$5"

  jq \
    --arg address "$server_address" \
    --arg uuid "$uuid" \
    --arg public "$public_key" \
    --arg sni "$sni" \
    --arg short "$short_id" \
    '(.outbounds[] | select(.tag == "proxy").settings.vnext[0].address) = $address
     | (.outbounds[] | select(.tag == "proxy").settings.vnext[0].users[0].id) = $uuid
     | (.outbounds[] | select(.tag == "proxy").streamSettings.realitySettings.serverName) = $sni
     | (.outbounds[] | select(.tag == "proxy").streamSettings.realitySettings.publicKey) = $public
     | (.outbounds[] | select(.tag == "proxy").streamSettings.realitySettings.shortId) = $short' \
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

if [[ $EUID -ne 0 ]]; then
  echo "错误：请以 root 身份运行此脚本。" >&2
  exit 1
fi

rm -f "$LOG_FILE"

log "开始执行 Xray VLESS + REALITY 自动化配置。"

if [ $# -lt 1 ]; then
  log "错误：请提供服务器的公网 IP 地址或域名作为第一个参数。"
  log "示例：sudo ./setup_xray_reality.sh your.server.com"
  exit 1
fi

SERVER_ADDRESS="$1"
log "服务器地址/域名：$SERVER_ADDRESS"

check_dependencies

if ! command_exists xray; then
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

log "UUID：$UUID"
log "Public Key：$PUBLIC_KEY"
log "Short ID：$SHORT_ID"
log "选择的 SNI/Dest：$SELECTED_SNI"

generate_server_config "$UUID" "$PRIVATE_KEY" "$SHORT_ID" "$SELECTED_SNI"
log "服务端配置已写入：$XRAY_CONFIG_FILE"

restart_xray_service

generate_client_config "$SERVER_ADDRESS" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SELECTED_SNI"
log "客户端配置已生成：$CLIENT_CONFIG_FILE_OUT"

VLESS_LINK=$(generate_vless_link "$SERVER_ADDRESS" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SELECTED_SNI")

log "-----------------------------------------------------"
log "配置完成。"
log "客户端配置文件路径：$CLIENT_CONFIG_FILE_OUT"
log "VLESS 链接如下："

echo ""
echo "$VLESS_LINK" | tee -a "$LOG_FILE"
echo ""

log "-----------------------------------------------------"
log "提示：请确认服务器防火墙已开放 TCP 443 端口。"
log "脚本执行完毕。"

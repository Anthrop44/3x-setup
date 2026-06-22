#!/bin/bash

# 检查3x-ui panel状态

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
OUTPUT_FILE="$LOG_DIR/3x-panel-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"

rm -f "$OUTPUT_FILE"
exec >"$OUTPUT_FILE" 2>&1

DIRECT_DOMAIN="$(jq -r '.directDomain // empty' "$CONFIG_PATH")"
CDN_DOMAIN="$(jq -r '.cdnDomain // empty' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort // empty' "$CONFIG_PATH")"
XHTTP_PORT="$(jq -r '.xhttpPort // empty' "$CONSTANTS_PATH")"
SUBSCRIPTION_PORT="$(jq -r '.subscriptionPort // empty' "$CONSTANTS_PATH")"
PANEL_PORT="$(jq -r '."3xpanelPort" // empty' "$CONSTANTS_PATH")"
PANEL_URI_PATH="$(jq -r '."3xpanelUriPath" // empty' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort // empty' "$CONSTANTS_PATH")"
PANEL_URL_PATH="/$PANEL_URI_PATH/"
SUBSCRIPTION_URI_PATH="$(jq -r '.subscriptionUriPath // empty' "$PATHS_PATH")"
XHTTP_PATH="$(jq -r '.xhttpPath // empty' "$PATHS_PATH")"

printf '== 基本信息 ==\n'
date -Is
printf '工作目录: %s\n' "$SCRIPT_DIR"
printf '面板端口: %s\n' "$PANEL_PORT"
printf '面板路径: %s\n' "$PANEL_URI_PATH"
printf '面板本机URL: http://127.0.0.1:%s%s\n' "$PANEL_PORT" "$PANEL_URL_PATH"

printf '\n== 3x-ui服务状态 ==\n'
sudo -n systemctl --no-pager --full status x-ui 2>&1
sudo -n systemctl is-active --quiet x-ui

printf '\n== 3x-ui配置 ==\n'
sudo -n /usr/local/x-ui/x-ui setting -show true 2>&1

printf '\n== 3x-ui安装文件 ==\n'
sudo -n ls -l /usr/local/x-ui/x-ui /etc/systemd/system/x-ui.service 2>&1
sudo -n find /etc/x-ui /usr/local/x-ui -maxdepth 2 -type f -printf '%p %s bytes\n' 2>&1 | sort

printf '\n== 监听端口 ==\n'
PORT_PATTERN=":($CDN_PORT|$XHTTP_PORT|$SUBSCRIPTION_PORT|$PANEL_PORT)\\b"
sudo -n ss -lntp 2>&1 | grep -E "$PORT_PATTERN"

printf '\n== 3x-ui监听检查 ==\n'
sudo -n ss -lntp 2>&1 | grep -E "127\\.0\\.0\\.1:$PANEL_PORT\\b|\\[::1\\]:$PANEL_PORT\\b"
if sudo -n ss -lntp 2>&1 | grep -E "(0\\.0\\.0\\.0:$PANEL_PORT\\b|\\*:$PANEL_PORT\\b|\\[::\\]:$PANEL_PORT\\b)"; then
	printf '3x-ui面板正在公网监听\n' >&2
	exit 1
fi
sudo -n ss -lntp 2>&1 | grep -E "127\\.0\\.0\\.1:$SUBSCRIPTION_PORT\\b|\\[::1\\]:$SUBSCRIPTION_PORT\\b"

printf '\n== 3x-ui数据库 ==\n'
sudo -n ls -l /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db-shm /etc/x-ui/x-ui.db-wal 2>&1 || true
sudo -n sqlite3 /etc/x-ui/x-ui.db '.tables' 2>&1
sudo -n sqlite3 /etc/x-ui/x-ui.db 'select key,value from settings order by key;' 2>&1

printf '\n== Xray配置检查 ==\n'
sudo -n jq -e '
	any(
		.outbounds[]?;
		.protocol == "freedom"
		and .tag == "direct"
		and .streamSettings.sockopt.happyEyeballs == {
			tryDelayMs: 0,
			prioritizeIPv6: false,
			interleave: 1,
			maxConcurrentTry: 4
		}
	)
' /usr/local/x-ui/bin/config.json

printf '\n== 3x-ui面板探测 ==\n'
curl -sS -I --max-time 10 "http://127.0.0.1:$PANEL_PORT$PANEL_URL_PATH" 2>&1
curl -sS -I --max-time 10 "http://127.0.0.1:$PANEL_PORT${PANEL_URL_PATH}login" 2>&1

printf '\n== 订阅入口探测 ==\n'
curl -k -sS -I --max-time 10 --resolve "$CDN_DOMAIN:$CDN_PORT:127.0.0.1" "https://$CDN_DOMAIN:$CDN_PORT/$SUBSCRIPTION_URI_PATH/__check__" 2>&1 || true

printf '\n== CDN入口探测 ==\n'
curl -k -sS -I --max-time 10 --resolve "$CDN_DOMAIN:$CDN_PORT:127.0.0.1" "https://$CDN_DOMAIN:$CDN_PORT/$XHTTP_PATH" 2>&1 || true
curl -k -sS -I --max-time 10 --resolve "$CDN_DOMAIN:$CDN_PORT:127.0.0.1" "https://$CDN_DOMAIN:$CDN_PORT/" 2>&1 || true

printf '\n== directDomain证书入口探测 ==\n'
curl -k -sS -I --max-time 10 --resolve "$DIRECT_DOMAIN:$REALITY_TARGET_PORT:127.0.0.1" "https://$DIRECT_DOMAIN:$REALITY_TARGET_PORT/" 2>&1 || true

printf '\n== 3x-ui日志 ==\n'
sudo -n journalctl -u x-ui --no-pager -n 160 2>&1 || true
sudo -n tail -n 160 /var/log/x-ui/*.log 2>&1 || true

printf '\n== 失败单元 ==\n'
sudo -n systemctl --failed --no-pager 2>&1 || true

printf '\n== 完成 ==\n'

# 执行 3x-inbound-init.sh
chmod +x "$SCRIPT_DIR/3x-inbound-init.sh"
exec bash "$SCRIPT_DIR/3x-inbound-init.sh"

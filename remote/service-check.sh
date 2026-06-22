#!/bin/bash

# 检查通用服务状态

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
OUTPUT_FILE="$LOG_DIR/service-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"

rm -f "$OUTPUT_FILE"
exec >"$OUTPUT_FILE" 2>&1

SSH_PORT="$(jq -r '.sshPort // empty' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort // empty' "$CONFIG_PATH")"

printf '== 基本信息 ==\n'
date -Is
hostnamectl 2>/dev/null || true
id
printf '工作目录: %s\n' "$SCRIPT_DIR"

if sudo -n systemctl is-active --quiet ssh; then
	SSH_SERVICE="ssh"
elif sudo -n systemctl is-active --quiet sshd; then
	SSH_SERVICE="sshd"
else
	printf '\n== SSH服务状态 ==\n'
	sudo -n systemctl --no-pager --full status ssh 2>&1 || true
	sudo -n systemctl --no-pager --full status sshd 2>&1 || true
	exit 1
fi

printf '\n== SSH服务状态 ==\n'
sudo -n systemctl --no-pager --full status "$SSH_SERVICE" 2>&1

printf '\n== UFW状态 ==\n'
sudo -n ufw status verbose 2>&1
sudo -n ufw status verbose | grep -q '^Status: active'

printf '\n== CDN端口防火墙规则 ==\n'
sudo -n ufw status numbered 2>&1 | grep -E "($CDN_PORT/tcp|$CDN_PORT[[:space:]])"

printf '\n== Cloudflare UFW定时器 ==\n'
sudo -n systemctl --no-pager --full status 3x-cloudflare-ufw.timer 2>&1
sudo -n systemctl is-enabled --quiet 3x-cloudflare-ufw.timer
sudo -n systemctl is-active --quiet 3x-cloudflare-ufw.timer

printf '\n== BBR状态 ==\n'
sysctl net.ipv4.tcp_available_congestion_control 2>&1
sysctl net.ipv4.tcp_congestion_control 2>&1
sysctl net.core.default_qdisc 2>&1
sudo -n sed -n '1,20p' /etc/sysctl.d/99-3x-bbr.conf 2>&1
sysctl -n net.ipv4.tcp_congestion_control | grep -qx bbr
sysctl -n net.core.default_qdisc | grep -qx fq

printf '\n== 监听端口 ==\n'
PORT_PATTERN=":(80|443|$SSH_PORT|$CDN_PORT)\\b"
sudo -n ss -lntp 2>&1 | grep -E "$PORT_PATTERN"

printf '\n== 失败单元 ==\n'
sudo -n systemctl --failed --no-pager 2>&1 || true

printf '\n== 完成 ==\n'

# 执行 caddy-init.sh
chmod +x "$SCRIPT_DIR/caddy-init.sh"
exec bash "$SCRIPT_DIR/caddy-init.sh"

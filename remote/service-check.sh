#!/bin/bash

# 检查通用服务状态

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
	printf 'This script must be run as root\n' >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
OUTPUT_FILE="$LOG_DIR/service-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"

rm -f "$OUTPUT_FILE"
exec >"$OUTPUT_FILE" 2>&1
source "$SCRIPT_DIR/script-timing.sh"

SSH_PORT="$(jq -r '.sshPort // empty' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort // empty' "$CONFIG_PATH")"
DAILY_TASK_HOUR="$(jq -r '.dailyTaskHour // empty' "$CONSTANTS_PATH")"
printf -v DAILY_TASK_TIME '%02d:00:00' "$DAILY_TASK_HOUR"

printf '== 基本信息 ==\n'
date -Is
hostnamectl 2>/dev/null || true
id
printf '工作目录: %s\n' "$SCRIPT_DIR"
timedatectl 2>&1 || true

if systemctl is-active --quiet ssh; then
	SSH_SERVICE="ssh"
elif systemctl is-active --quiet sshd; then
	SSH_SERVICE="sshd"
else
	printf '\n== SSH服务状态 ==\n'
	systemctl --no-pager --full status ssh 2>&1 || true
	systemctl --no-pager --full status sshd 2>&1 || true
	exit 1
fi

printf '\n== SSH服务状态 ==\n'
systemctl --no-pager --full status "$SSH_SERVICE" 2>&1

printf '\n== root SSH公钥认证策略 ==\n'
source "$SCRIPT_DIR/check-common.sh"
assert_root_ssh_publickey_only

printf '\n== UFW状态 ==\n'
ufw status verbose 2>&1
ufw status verbose | grep -q '^Status: active'
ufw status verbose | grep -Eq '^443/tcp[[:space:]]+ALLOW IN'
ufw status verbose | grep -Eq '^443/udp[[:space:]]+ALLOW IN'

printf '\n== CDN端口防火墙规则 ==\n'
ufw status numbered 2>&1 | grep -E "(${CDN_PORT}/tcp|${CDN_PORT}[[:space:]])"

printf '\n== Cloudflare UFW定时器 ==\n'
systemctl --no-pager --full status 3x-cloudflare-ufw.timer 2>&1
systemctl is-enabled --quiet 3x-cloudflare-ufw.timer
systemctl is-active --quiet 3x-cloudflare-ufw.timer
systemctl cat 3x-cloudflare-ufw.timer 2>&1
systemctl cat 3x-cloudflare-ufw.timer | grep -Fqx "OnCalendar=*-*-* $DAILY_TASK_TIME"
systemctl cat 3x-cloudflare-ufw.timer | grep -Fqx 'RandomizedDelaySec=1h'

printf '\n== BBR状态 ==\n'
sysctl net.ipv4.tcp_available_congestion_control 2>&1
sysctl net.ipv4.tcp_congestion_control 2>&1
sysctl net.core.default_qdisc 2>&1
sed -n '1,20p' /etc/sysctl.d/99-3x-bbr.conf 2>&1
sysctl -n net.ipv4.tcp_congestion_control | grep -qx bbr
sysctl -n net.core.default_qdisc | grep -qx fq

printf '\n== 监听端口 ==\n'
PORT_PATTERN=":(80|443|$SSH_PORT|$CDN_PORT)\\b"
ss -lntup 2>&1 | grep -E "$PORT_PATTERN"

printf '\n== 失败单元 ==\n'
systemctl --failed --no-pager 2>&1 || true

printf '\n== 完成 ==\n'

# 执行 caddy-init.sh
chmod +x "$SCRIPT_DIR/caddy-init.sh"
script_timer_finish 0
exec bash "$SCRIPT_DIR/caddy-init.sh" "$@"

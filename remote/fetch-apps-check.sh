#!/bin/bash

# 检查代理客户端更新任务和静态文件

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
	printf 'This script must be run as root\n' >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
OUTPUT_FILE="$LOG_DIR/fetch-apps-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
STATE_PATH="/var/lib/3x-fetch-apps/state.json"

rm -f "$OUTPUT_FILE"
exec >"$OUTPUT_FILE" 2>&1
source "$SCRIPT_DIR/script-timing.sh"
source "$SCRIPT_DIR/check-common.sh"

CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort' "$CONFIG_PATH")"
SUBSCRIPTION_PATH="$(jq -r '.subscriptionPath' "$CONFIG_PATH")"
PROXY_CLIENTS_SUFFIX="$(jq -r '.proxyClientsSuffix' "$CONSTANTS_PATH")"
DAILY_TASK_HOUR="$(jq -r '.dailyTaskHour' "$CONSTANTS_PATH")"
printf -v DAILY_TASK_TIME '%02d:00:00' "$DAILY_TASK_HOUR"
PROXY_CLIENTS_PATH="${SUBSCRIPTION_PATH}${PROXY_CLIENTS_SUFFIX}"
TARGET_DIR="/var/www/3x-fake-site/$PROXY_CLIENTS_PATH"

printf '== Basic information ==\n'
date -Is
timedatectl 2>&1 || true
printf 'Daily task time: %s\n' "$DAILY_TASK_TIME"
printf 'Proxy clients path: %s\n' "$PROXY_CLIENTS_PATH"

printf '\n== Proxy client service ==\n'
systemctl --no-pager --full status 3x-fetch-apps.service 2>&1 || true
test "$(systemctl show 3x-fetch-apps.service --property=Result --value)" = success

printf '\n== Daily timers ==\n'
for TIMER_NAME in 3x-cloudflare-ufw.timer 3x-fetch-apps.timer; do
	systemctl --no-pager --full status "$TIMER_NAME" 2>&1
	systemctl is-enabled --quiet "$TIMER_NAME"
	systemctl is-active --quiet "$TIMER_NAME"
	systemctl cat "$TIMER_NAME" 2>&1
	systemctl cat "$TIMER_NAME" | grep -Fqx "OnCalendar=*-*-* $DAILY_TASK_TIME"
	systemctl cat "$TIMER_NAME" | grep -Fqx 'RandomizedDelaySec=1h'
done
systemctl list-timers 3x-cloudflare-ufw.timer 3x-fetch-apps.timer --all --no-pager 2>&1

printf '\n== Resource state ==\n'
jq . "$STATE_PATH"
test "$(jq '.resources | length' "$STATE_PATH")" = "$(jq '.proxyClientsFilenames | length' "$CONSTANTS_PATH")"

while IFS= read -r RESOURCE_ID; do
	FILENAME="$(jq -r --arg id "$RESOURCE_ID" '.proxyClientsFilenames[$id]' "$CONSTANTS_PATH")"
	FILE_PATH="$TARGET_DIR/$FILENAME"
	jq -e \
		--arg id "$RESOURCE_ID" \
		--arg filename "$FILENAME" \
		'.resources[$id].disabled == false
		and .resources[$id].failureCount == 0
		and .resources[$id].destinationName == $filename
		and (.resources[$id].assetId | type == "string")
		and (.resources[$id].tag | type == "string")' "$STATE_PATH" >/dev/null
	test -s "$FILE_PATH"
	test "$(stat -c '%U:%G' "$FILE_PATH")" = caddy:caddy
	test "$(stat -c '%a' "$FILE_PATH")" = 644
	curl \
		-kfsSI \
		--max-time 30 \
		--resolve "$CDN_DOMAIN:$CDN_PORT:127.0.0.1" \
		"https://$CDN_DOMAIN:$CDN_PORT/$PROXY_CLIENTS_PATH/$FILENAME" >/dev/null
	printf 'OK %s %s\n' "$RESOURCE_ID" "$FILENAME"
done < <(jq -r '.proxyClientsFilenames | keys[]' "$CONSTANTS_PATH")

printf '\n== Failed units ==\n'
systemctl --failed --no-pager 2>&1 || true
ensure_no_failed_units

printf '\n== Complete ==\n'

# 执行 direct-tls-init.sh
chmod +x "$SCRIPT_DIR/direct-tls-init.sh"
script_timer_finish 0
exec bash "$SCRIPT_DIR/direct-tls-init.sh" "$@"

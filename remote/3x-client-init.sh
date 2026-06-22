#!/bin/bash

# 配置3x-ui示例客户端

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/3x-client-init.log"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"

rm -f "$LOG_PATH"
exec >"$LOG_PATH" 2>&1

PANEL_USERNAME="$(jq -r '."3xusername"' "$CONSTANTS_PATH")"
PANEL_PASSWORD="$(jq -r '."3xpassword"' "$CONSTANTS_PATH")"
PANEL_PORT="$(jq -r '."3xpanelPort"' "$CONSTANTS_PATH")"
PANEL_URI_PATH="$(jq -r '."3xpanelUriPath"' "$CONSTANTS_PATH")"
INITIAL_CLIENT_EMAIL="$(jq -r '.initialClientEmail' "$CONSTANTS_PATH")"
INITIAL_CLIENT_SUB_ID="$(jq -r '.initialClientSubId' "$PATHS_PATH")"
PANEL_BASE_URL="http://127.0.0.1:$PANEL_PORT/$PANEL_URI_PATH"
PANEL_ROOT_URL="$PANEL_BASE_URL/"
REALITY_REMARK="Direct"
XHTTP_REMARK="CDN"

COOKIE_JAR="$(mktemp)"
LOGIN_PAGE_PATH="$(mktemp)"
LOGIN_RESPONSE_PATH="$(mktemp)"
INBOUNDS_RESPONSE_PATH="$(mktemp)"
CLIENT_PAYLOAD_PATH="$(mktemp)"
CLIENT_RESPONSE_PATH="$(mktemp)"
RESTART_RESPONSE_PATH="$(mktemp)"
STATUS_RESPONSE_PATH="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$LOGIN_PAGE_PATH" "$LOGIN_RESPONSE_PATH" "$INBOUNDS_RESPONSE_PATH" "$CLIENT_PAYLOAD_PATH" "$CLIENT_RESPONSE_PATH" "$RESTART_RESPONSE_PATH" "$STATUS_RESPONSE_PATH"' EXIT

login_panel() {
	# 登录3x-ui面板并设置会话Cookie和CSRF token
	curl -fsS -c "$COOKIE_JAR" "$PANEL_ROOT_URL" >"$LOGIN_PAGE_PATH"
	CSRF_TOKEN="$(sed -n 's/.*<meta name="csrf-token" content="\([^"]*\)".*/\1/p' "$LOGIN_PAGE_PATH")"
	if [ -z "$CSRF_TOKEN" ]; then
		printf '读取3x-ui CSRF token失败\n' >&2
		exit 1
	fi

	jq -n \
		--arg username "$PANEL_USERNAME" \
		--arg password "$PANEL_PASSWORD" \
		'{
			username: $username,
			password: $password,
			twoFactorCode: ""
		}' | curl -fsS \
		-b "$COOKIE_JAR" \
		-c "$COOKIE_JAR" \
		-H 'Content-Type: application/json' \
		-H "X-CSRF-Token: $CSRF_TOKEN" \
		-d @- \
		"$PANEL_BASE_URL/login" >"$LOGIN_RESPONSE_PATH"
	if ! jq -e '.success == true' "$LOGIN_RESPONSE_PATH" >/dev/null; then
		printf '3x-ui登录失败\n' >&2
		cat "$LOGIN_RESPONSE_PATH" >&2
		exit 1
	fi
}

api_get() {
	# 调用3x-ui GET API并保存响应
	local endpoint="$1"
	local output_path="$2"

	curl -fsS \
		-b "$COOKIE_JAR" \
		-H "X-CSRF-Token: $CSRF_TOKEN" \
		"$PANEL_BASE_URL$endpoint" >"$output_path"
}

api_post_file() {
	# 调用3x-ui POST API并保存响应
	local endpoint="$1"
	local payload_path="$2"
	local output_path="$3"

	curl -fsS \
		-b "$COOKIE_JAR" \
		-H 'Content-Type: application/json' \
		-H "X-CSRF-Token: $CSRF_TOKEN" \
		-d @"$payload_path" \
		"$PANEL_BASE_URL$endpoint" >"$output_path"
}

api_post_empty() {
	# 调用没有请求体的3x-ui POST API并保存响应
	local endpoint="$1"
	local output_path="$2"

	curl -fsS \
		-b "$COOKIE_JAR" \
		-H "X-CSRF-Token: $CSRF_TOKEN" \
		-X POST \
		"$PANEL_BASE_URL$endpoint" >"$output_path"
}

require_api_success() {
	# 要求3x-ui API响应success为true
	local response_path="$1"
	local message="$2"

	if ! jq -e '.success == true' "$response_path" >/dev/null; then
		printf '%s\n' "$message" >&2
		cat "$response_path" >&2
		exit 1
	fi
}

get_unique_inbound_id() {
	# 从入站列表按备注读取唯一入站ID
	local remark="$1"
	local count

	count="$(jq --arg remark "$remark" '[.obj[] | select(.remark == $remark)] | length' "$INBOUNDS_RESPONSE_PATH")"
	if [ "$count" != "1" ]; then
		printf '入站%s数量不是1，实际为%s\n' "$remark" "$count" >&2
		cat "$INBOUNDS_RESPONSE_PATH" >&2
		exit 1
	fi
	jq -r --arg remark "$remark" '.obj[] | select(.remark == $remark) | .id' "$INBOUNDS_RESPONSE_PATH"
}

wait_xray_running() {
	# 等待3x-ui报告Xray运行中
	local index

	for index in $(seq 1 30); do
		api_get "/panel/api/server/status" "$STATUS_RESPONSE_PATH"
		if jq -e '(.obj.xray.state // .obj.state // "") == "running"' "$STATUS_RESPONSE_PATH" >/dev/null; then
			return 0
		fi
		sleep 1
	done
	printf '等待Xray运行超时\n' >&2
	cat "$STATUS_RESPONSE_PATH" >&2
	exit 1
}

printf '== 基本信息 ==\n'
date -Is
printf '初始客户端: %s\n' "$INITIAL_CLIENT_EMAIL"
printf '初始订阅ID: %s\n' "$INITIAL_CLIENT_SUB_ID"

login_panel

printf '\n== 查找入站ID ==\n'
api_get "/panel/api/inbounds/list" "$INBOUNDS_RESPONSE_PATH"
require_api_success "$INBOUNDS_RESPONSE_PATH" "读取3x-ui入站列表失败"
REALITY_INBOUND_ID="$(get_unique_inbound_id "$REALITY_REMARK")"
XHTTP_INBOUND_ID="$(get_unique_inbound_id "$XHTTP_REMARK")"
printf 'Reality入站ID: %s\n' "$REALITY_INBOUND_ID"
printf 'XHTTP入站ID: %s\n' "$XHTTP_INBOUND_ID"

printf '\n== 创建初始客户端 ==\n'
jq -n \
	--arg email "$INITIAL_CLIENT_EMAIL" \
	--arg subId "$INITIAL_CLIENT_SUB_ID" \
	--arg realityInboundId "$REALITY_INBOUND_ID" \
	--arg xhttpInboundId "$XHTTP_INBOUND_ID" \
	'{
		client: {
			email: $email,
			subId: $subId,
			flow: "xtls-rprx-vision",
			security: "auto",
			totalGB: 0,
			expiryTime: 0,
			limitIp: 0,
			enable: true,
			tgId: 0,
			reset: 0,
			comment: ""
		},
		inboundIds: [
			($realityInboundId | tonumber),
			($xhttpInboundId | tonumber)
		]
	}' >"$CLIENT_PAYLOAD_PATH"
api_post_file "/panel/api/clients/add" "$CLIENT_PAYLOAD_PATH" "$CLIENT_RESPONSE_PATH"
require_api_success "$CLIENT_RESPONSE_PATH" "创建初始客户端失败"

printf '\n== 重启Xray ==\n'
api_post_empty "/panel/api/server/restartXrayService" "$RESTART_RESPONSE_PATH"
require_api_success "$RESTART_RESPONSE_PATH" "重启Xray失败"
wait_xray_running

printf '\n== 完成 ==\n'

# 执行 3x-client-check.sh
chmod +x "$SCRIPT_DIR/3x-client-check.sh"
exec bash "$SCRIPT_DIR/3x-client-check.sh"

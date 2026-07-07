#!/bin/bash

# 配置3x-ui客户端

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/3x-client-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"

rm -f "$LOG_PATH"
exec >"$LOG_PATH" 2>&1

PANEL_USERNAME="$(jq -r '."3xusername"' "$CONSTANTS_PATH")"
PANEL_PASSWORD="$(jq -r '."3xpassword"' "$CONSTANTS_PATH")"
PANEL_PORT="$(jq -r '."3xpanelPort"' "$CONSTANTS_PATH")"
PANEL_URI_PATH="$(jq -r '."3xpanelUriPath"' "$CONSTANTS_PATH")"
CLIENT_COUNT="$(jq -r '.clients | length' "$CONFIG_PATH")"
PANEL_BASE_URL="http://127.0.0.1:$PANEL_PORT/$PANEL_URI_PATH"
PANEL_ROOT_URL="$PANEL_BASE_URL/"
HY2_REMARK="QUIC"
REALITY_REMARK="TCP"
XHTTP_REMARK="Cloudflare"

COOKIE_JAR="$(mktemp)"
LOGIN_PAGE_PATH="$(mktemp)"
LOGIN_RESPONSE_PATH="$(mktemp)"
INBOUNDS_RESPONSE_PATH="$(mktemp)"
CLIENTS_RESPONSE_PATH="$(mktemp)"
DELETE_PAYLOAD_PATH="$(mktemp)"
DELETE_RESPONSE_PATH="$(mktemp)"
CLIENT_PAYLOAD_PATH="$(mktemp)"
CLIENT_RESPONSE_PATH="$(mktemp)"
RESTART_RESPONSE_PATH="$(mktemp)"
STATUS_RESPONSE_PATH="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$LOGIN_PAGE_PATH" "$LOGIN_RESPONSE_PATH" "$INBOUNDS_RESPONSE_PATH" "$CLIENTS_RESPONSE_PATH" "$DELETE_PAYLOAD_PATH" "$DELETE_RESPONSE_PATH" "$CLIENT_PAYLOAD_PATH" "$CLIENT_RESPONSE_PATH" "$RESTART_RESPONSE_PATH" "$STATUS_RESPONSE_PATH"' EXIT

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

require_config_clients_valid() {
	# 要求配置中的客户端名和订阅ID存在且不重复
	if ! jq -e '
		(.clients | length) > 0
		and all(.clients[]; ((.client // "") | type == "string" and length > 0) and ((.path // "") | type == "string" and length > 0))
		and all(.clients[]; ((.traffic // 0) | type == "number" and . >= 0 and . == floor))
		and ((.clients | map(.client) | unique | length) == (.clients | length))
		and ((.clients | map(.path) | unique | length) == (.clients | length))
	' "$CONFIG_PATH" >/dev/null; then
		printf 'config.json 中的 clients 无效，client 和 path 必须存在且不能重复，traffic 必须为非负整数\n' >&2
		cat "$CONFIG_PATH" >&2
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

print_panel_clients() {
	# 打印3x-ui当前客户端和订阅ID
	local count

	count="$(jq -r '(.obj // []) | length' "$CLIENTS_RESPONSE_PATH")"
	printf '3x-ui客户端数量: %s\n' "$count"
	jq -r '(.obj // [])[] | "3x-ui客户端: \(.email) path=\(.subId // "") totalGB=\(.totalGB // 0) reset=\(.reset // 0)"' "$CLIENTS_RESPONSE_PATH"
}

build_delete_payload() {
	# 生成需要删除的客户端列表
	jq -n \
		--slurpfile config "$CONFIG_PATH" \
		--slurpfile panel "$CLIENTS_RESPONSE_PATH" \
		'
			($config[0].clients | map({
				key: .client,
				value: {
					path: .path,
					totalGB: ((.traffic // 0) * 1073741824),
					reset: (if (.traffic // 0) > 0 then 30 else 0 end)
				}
			}) | from_entries) as $expected
			| ($panel[0].obj // [])
			| map(select(
				(.email // "") as $email
				| (($expected[$email] // null) == null)
					or ((.subId // "") != $expected[$email].path)
					or ((.totalGB // 0) != $expected[$email].totalGB)
					or ((.reset // 0) != $expected[$email].reset)
			))
			| map(.email)
			| unique
			| {
				emails: .,
				keepTraffic: false
			}
		' >"$DELETE_PAYLOAD_PATH"
}

delete_extra_clients() {
	# 删除不在config中或订阅ID不匹配的客户端
	local delete_count

	build_delete_payload
	delete_count="$(jq -r '.emails | length' "$DELETE_PAYLOAD_PATH")"
	printf '需要删除的客户端数量: %s\n' "$delete_count"
	if [ "$delete_count" = "0" ]; then
		return 0
	fi

	jq -r '.emails[] | "删除客户端: \(.)"' "$DELETE_PAYLOAD_PATH"
	api_post_file "/panel/api/clients/bulkDel" "$DELETE_PAYLOAD_PATH" "$DELETE_RESPONSE_PATH"
	require_api_success "$DELETE_RESPONSE_PATH" "删除客户端失败"
	api_get "/panel/api/clients/list" "$CLIENTS_RESPONSE_PATH"
	require_api_success "$CLIENTS_RESPONSE_PATH" "重新读取3x-ui客户端列表失败"
	print_panel_clients
}

client_exists() {
	# 判断3x-ui中是否已有指定客户端和订阅ID
	local client_email="$1"
	local client_sub_id="$2"

	jq -e \
		--arg email "$client_email" \
		--arg subId "$client_sub_id" \
		'(.obj // []) | any(.[]; (.email // "") == $email and (.subId // "") == $subId)' \
		"$CLIENTS_RESPONSE_PATH" >/dev/null
}

create_client() {
	# 创建一个3x-ui客户端
	local client_email="$1"
	local client_sub_id="$2"
	local client_traffic="$3"
	local hy2_auth

	hy2_auth="$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=')"
	jq -n \
		--arg email "$client_email" \
		--arg subId "$client_sub_id" \
		--arg hy2Auth "$hy2_auth" \
		--arg hy2InboundId "$HY2_INBOUND_ID" \
		--arg realityInboundId "$REALITY_INBOUND_ID" \
		--arg xhttpInboundId "$XHTTP_INBOUND_ID" \
		--argjson traffic "$client_traffic" \
		'{
			client: {
				email: $email,
				subId: $subId,
				auth: $hy2Auth,
				flow: "xtls-rprx-vision",
				security: "auto",
				totalGB: ($traffic * 1073741824),
				expiryTime: 0,
				limitIp: 0,
				enable: true,
				tgId: 0,
				reset: (if $traffic > 0 then 30 else 0 end),
				comment: ""
			},
			inboundIds: [
				($hy2InboundId | tonumber),
				($realityInboundId | tonumber),
				($xhttpInboundId | tonumber)
			]
		}' >"$CLIENT_PAYLOAD_PATH"
	api_post_file "/panel/api/clients/add" "$CLIENT_PAYLOAD_PATH" "$CLIENT_RESPONSE_PATH"
	require_api_success "$CLIENT_RESPONSE_PATH" "创建客户端 $client_email 失败"
}

add_missing_clients() {
	# 创建config中存在但3x-ui中缺失的客户端
	local create_count

	create_count=0
	while IFS= read -r CLIENT_ENTRY; do
		CLIENT_EMAIL="$(jq -r '.client' <<<"$CLIENT_ENTRY")"
		CLIENT_SUB_ID="$(jq -r '.path' <<<"$CLIENT_ENTRY")"
		CLIENT_TRAFFIC="$(jq -r '.traffic // 0' <<<"$CLIENT_ENTRY")"
		if client_exists "$CLIENT_EMAIL" "$CLIENT_SUB_ID"; then
			printf '保留客户端: %s path=%s traffic=%sGB\n' "$CLIENT_EMAIL" "$CLIENT_SUB_ID" "$CLIENT_TRAFFIC"
			continue
		fi
		printf '创建客户端: %s path=%s traffic=%sGB\n' "$CLIENT_EMAIL" "$CLIENT_SUB_ID" "$CLIENT_TRAFFIC"
		create_client "$CLIENT_EMAIL" "$CLIENT_SUB_ID" "$CLIENT_TRAFFIC"
		create_count=$((create_count + 1))
	done < <(jq -c '.clients[]' "$CONFIG_PATH")

	printf '已创建客户端数量: %s\n' "$create_count"
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
printf '客户端数量: %s\n' "$CLIENT_COUNT"
require_config_clients_valid

login_panel

printf '\n== 查找入站ID ==\n'
api_get "/panel/api/inbounds/list" "$INBOUNDS_RESPONSE_PATH"
require_api_success "$INBOUNDS_RESPONSE_PATH" "读取3x-ui入站列表失败"
HY2_INBOUND_ID="$(get_unique_inbound_id "$HY2_REMARK")"
REALITY_INBOUND_ID="$(get_unique_inbound_id "$REALITY_REMARK")"
XHTTP_INBOUND_ID="$(get_unique_inbound_id "$XHTTP_REMARK")"
printf 'Hysteria2入站ID: %s\n' "$HY2_INBOUND_ID"
printf 'Reality入站ID: %s\n' "$REALITY_INBOUND_ID"
printf 'XHTTP入站ID: %s\n' "$XHTTP_INBOUND_ID"

printf '\n== 读取3x-ui客户端 ==\n'
api_get "/panel/api/clients/list" "$CLIENTS_RESPONSE_PATH"
require_api_success "$CLIENTS_RESPONSE_PATH" "读取3x-ui客户端列表失败"
print_panel_clients

printf '\n== 删除多余客户端 ==\n'
delete_extra_clients

printf '\n== 补齐缺失客户端 ==\n'
add_missing_clients

printf '\n== 重启Xray ==\n'
api_post_empty "/panel/api/server/restartXrayService" "$RESTART_RESPONSE_PATH"
require_api_success "$RESTART_RESPONSE_PATH" "重启Xray失败"
wait_xray_running

printf '\n== 完成 ==\n'

# 执行 3x-client-check.sh
chmod +x "$SCRIPT_DIR/3x-client-check.sh"
exec bash "$SCRIPT_DIR/3x-client-check.sh" "$@"

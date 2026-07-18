#!/bin/bash

# 检查3x-ui入站

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
OUTPUT_FILE="$LOG_DIR/3x-inbound-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"
DIRECT_CERT_FILE="/etc/caddy/3x-direct-cert.pem"
DIRECT_KEY_FILE="/etc/caddy/3x-direct-key.pem"
NO_TLS=0

rm -f "$OUTPUT_FILE"
exec >"$OUTPUT_FILE" 2>&1

parse_args() {
	# 解析传入参数
	local arg

	for arg in "$@"; do
		case "$arg" in
		--noTLS)
			NO_TLS=1
			;;
		--noAPP)
			;;
		*)
			printf '未知参数: %s\n' "$arg" >&2
			exit 1
			;;
		esac
	done
}

parse_args "$@"

DIRECT_DOMAIN="$(jq -r '.directDomain' "$CONFIG_PATH")"
PANEL_USERNAME="$(jq -r '."3xusername"' "$CONSTANTS_PATH")"
PANEL_PASSWORD="$(jq -r '."3xpassword"' "$CONSTANTS_PATH")"
PANEL_PORT="$(jq -r '."3xpanelPort"' "$CONSTANTS_PATH")"
PANEL_URI_PATH="$(jq -r '."3xpanelUriPath"' "$CONSTANTS_PATH")"
XHTTP_PORT="$(jq -r '.xhttpPort' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort' "$CONSTANTS_PATH")"
XHTTP_PATH="$(jq -r '.xhttpPath' "$PATHS_PATH")"
PANEL_BASE_URL="http://127.0.0.1:$PANEL_PORT/$PANEL_URI_PATH"
PANEL_ROOT_URL="$PANEL_BASE_URL/"
HY2_REMARK="QUIC"
REALITY_REMARK="TCP"
XHTTP_REMARK="Cloudflare"

COOKIE_JAR="$(mktemp)"
LOGIN_PAGE_PATH="$(mktemp)"
LOGIN_RESPONSE_PATH="$(mktemp)"
INBOUNDS_RESPONSE_PATH="$(mktemp)"
STATUS_RESPONSE_PATH="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$LOGIN_PAGE_PATH" "$LOGIN_RESPONSE_PATH" "$INBOUNDS_RESPONSE_PATH" "$STATUS_RESPONSE_PATH"' EXIT

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

require_jq() {
	# 要求jq表达式验证通过
	local response_path="$1"
	local message="$2"
	local expression="$3"

	if ! jq -e "$expression" "$response_path" >/dev/null; then
		printf '%s\n' "$message" >&2
		cat "$response_path" >&2
		exit 1
	fi
}

ensure_no_failed_units() {
	# 确认systemd没有失败单元
	local failed_units

	failed_units="$(sudo -n systemctl --failed --no-legend --plain 2>/dev/null || true)"
	if [ -n "$failed_units" ]; then
		printf '%s\n' "$failed_units" >&2
		exit 1
	fi
}

printf '== 基本信息 ==\n'
date -Is
printf '工作目录: %s\n' "$SCRIPT_DIR"
printf 'Hysteria2入站: %s\n' "$HY2_REMARK"
printf 'Reality入站: %s\n' "$REALITY_REMARK"
printf 'XHTTP入站: %s\n' "$XHTTP_REMARK"
printf '跳过公信TLS: %s\n' "$NO_TLS"

login_panel

printf '\n== 入站列表 ==\n'
api_get "/panel/api/inbounds/list" "$INBOUNDS_RESPONSE_PATH"
require_api_success "$INBOUNDS_RESPONSE_PATH" "读取3x-ui入站列表失败"
jq -r '.obj[] | [.id, .remark, .listen, .port, .protocol, .enable] | @tsv' "$INBOUNDS_RESPONSE_PATH"

printf '\n== Hysteria2入站检查 ==\n'
require_jq "$INBOUNDS_RESPONSE_PATH" "Hysteria2入站配置不符合预期" '
	def decoded: if type == "string" then fromjson else . end;
	[.obj[] | select(.remark == "'"$HY2_REMARK"'")] as $items
	| ($items | length == 1)
	and ($items[0].enable == true)
	and ($items[0].port == 443)
	and ($items[0].protocol == "hysteria")
	and ($items[0].shareAddrStrategy == "custom")
	and ($items[0].shareAddr == "'"$DIRECT_DOMAIN"'")
	and ($items[0].subSortIndex == 1)
	and (($items[0].settings | decoded) as $settings
		| $settings.version == 2
		and $settings.address == "'"$DIRECT_DOMAIN"'"
		and $settings.port == 443)
	and (($items[0].streamSettings | decoded) as $stream
		| $stream.network == "hysteria"
		and $stream.security == "tls"
		and $stream.hysteriaSettings.version == 2
		and $stream.hysteriaSettings.udpIdleTimeout == 60
		and $stream.tlsSettings.serverName == "'"$DIRECT_DOMAIN"'"
		and ($stream.tlsSettings.alpn | index("h3") != null)
		and $stream.tlsSettings.certificates[0].certificateFile == "'"$DIRECT_CERT_FILE"'"
		and $stream.tlsSettings.certificates[0].keyFile == "'"$DIRECT_KEY_FILE"'"
		and $stream.tlsSettings.certificates[0].usage == "encipherment"
		and $stream.finalmask.udp[0].type == "salamander"
		and (($stream.finalmask.udp[0].settings.password // "") | length >= 16))
	and (($items[0].sniffing | decoded).enabled == false)
'
sudo -n test -s "$DIRECT_CERT_FILE"
sudo -n test -s "$DIRECT_KEY_FILE"
printf 'Hysteria2入站OK\n'

printf '\n== Reality入站检查 ==\n'
require_jq "$INBOUNDS_RESPONSE_PATH" "Reality入站配置不符合预期" '
	def decoded: if type == "string" then fromjson else . end;
	[.obj[] | select(.remark == "'"$REALITY_REMARK"'")] as $items
	| ($items | length == 1)
	and ($items[0].enable == true)
	and ($items[0].port == 443)
	and ($items[0].protocol == "vless")
	and ($items[0].shareAddrStrategy == "custom")
	and ($items[0].shareAddr == "'"$DIRECT_DOMAIN"'")
	and ($items[0].subSortIndex == 2)
	and (($items[0].streamSettings | decoded) as $stream
		| $stream.network == "tcp"
		and $stream.security == "reality"
		and (($stream.realitySettings.target // $stream.realitySettings.dest) == "127.0.0.1:'"$REALITY_TARGET_PORT"'")
		and ($stream.realitySettings.serverNames | index("'"$DIRECT_DOMAIN"'") != null)
		and (($stream.realitySettings.privateKey // "") != "")
		and (($stream.realitySettings.settings.publicKey // "") != "")
		and (($stream.realitySettings.shortIds // []) | length >= 1))
'

printf 'Reality入站OK\n'

printf '\n== XHTTP入站检查 ==\n'
require_jq "$INBOUNDS_RESPONSE_PATH" "XHTTP入站配置不符合预期" '
	def decoded: if type == "string" then fromjson else . end;
	[.obj[] | select(.remark == "'"$XHTTP_REMARK"'")] as $items
	| ($items | length == 1)
	and ($items[0].enable == true)
	and ($items[0].listen == "127.0.0.1")
	and ($items[0].port == ('"$XHTTP_PORT"'))
	and ($items[0].protocol == "vless")
	and ($items[0].shareAddrStrategy == "listen")
	and (($items[0].shareAddr // "") == "")
	and ($items[0].subSortIndex == 3)
	and (($items[0].streamSettings | decoded) as $stream
		| $stream.network == "xhttp"
		and $stream.security == "none"
		and $stream.xhttpSettings.path == "/'"$XHTTP_PATH"'"
		and (($stream.externalProxy // []) | length == 0))
'
printf 'XHTTP入站OK\n'

printf '\n== Xray重启说明 ==\n'
printf '客户端创建后统一重启Xray并检查监听端口\n'

printf '\n== 失败单元 ==\n'
sudo -n systemctl --failed --no-pager 2>&1 || true
ensure_no_failed_units

printf '\n== 完成 ==\n'

# 执行 cf-host-init.sh
chmod +x "$SCRIPT_DIR/cf-host-init.sh"
exec bash "$SCRIPT_DIR/cf-host-init.sh" "$@"

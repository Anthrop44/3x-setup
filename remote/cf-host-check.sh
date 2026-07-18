#!/bin/bash

# 检查3x-ui订阅主机

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
OUTPUT_FILE="$LOG_DIR/cf-host-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
XHTTP_REMARK="Cloudflare"
VANILLA_GROUP_ID_PREFIX="3xsetupxhttpcdn1"

rm -f "$OUTPUT_FILE"
exec >"$OUTPUT_FILE" 2>&1

parse_args() {
	# 解析传入参数
	local arg

	for arg in "$@"; do
		case "$arg" in
		--noTLS | --noAPP)
			;;
		*)
			printf '未知参数: %s\n' "$arg" >&2
			exit 1
			;;
		esac
	done
}

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

parse_args "$@"

CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
CDN_OPT_DOMAINS="$(jq -c '.cdnOptDomains // []' "$CONFIG_PATH")"
OPT_DOMAIN_COUNT="$(jq -r 'length' <<<"$CDN_OPT_DOMAINS")"
PANEL_USERNAME="$(jq -r '."3xusername"' "$CONSTANTS_PATH")"
PANEL_PASSWORD="$(jq -r '."3xpassword"' "$CONSTANTS_PATH")"
PANEL_PORT="$(jq -r '."3xpanelPort"' "$CONSTANTS_PATH")"
PANEL_URI_PATH="$(jq -r '."3xpanelUriPath"' "$CONSTANTS_PATH")"
FINGERPRINT="$(jq -r '.fingerprint' "$CONSTANTS_PATH")"
PANEL_BASE_URL="http://127.0.0.1:$PANEL_PORT/$PANEL_URI_PATH"
PANEL_ROOT_URL="$PANEL_BASE_URL/"

COOKIE_JAR="$(mktemp)"
LOGIN_PAGE_PATH="$(mktemp)"
LOGIN_RESPONSE_PATH="$(mktemp)"
INBOUNDS_RESPONSE_PATH="$(mktemp)"
HOSTS_RESPONSE_PATH="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$LOGIN_PAGE_PATH" "$LOGIN_RESPONSE_PATH" "$INBOUNDS_RESPONSE_PATH" "$HOSTS_RESPONSE_PATH"' EXIT

printf '== 基本信息 ==\n'
date -Is
printf 'CDN域名: %s\n' "$CDN_DOMAIN"
printf '优选域名数量: %s\n' "$OPT_DOMAIN_COUNT"

login_panel

printf '\n== 查找XHTTP入站 ==\n'
api_get "/panel/api/inbounds/list" "$INBOUNDS_RESPONSE_PATH"
require_api_success "$INBOUNDS_RESPONSE_PATH" "读取3x-ui入站列表失败"
XHTTP_INBOUND_ID="$(get_unique_inbound_id "$XHTTP_REMARK")"
printf 'XHTTP入站ID: %s\n' "$XHTTP_INBOUND_ID"

printf '\n== XHTTP Host列表 ==\n'
api_get "/panel/api/hosts/byInbound/$XHTTP_INBOUND_ID" "$HOSTS_RESPONSE_PATH"
require_api_success "$HOSTS_RESPONSE_PATH" "读取XHTTP Host失败"
jq -r '(.obj // [])[] | [.groupId, .remark, (.hosts | join(",")), .port, .security, .sni, ((.alpn // []) | join(",")), .fingerprint] | @tsv' "$HOSTS_RESPONSE_PATH"

if ! jq -e \
	--arg cdnDomain "$CDN_DOMAIN" \
	--arg fingerprint "$FINGERPRINT" \
	--arg vanillaGroupIdPrefix "$VANILLA_GROUP_ID_PREFIX" \
	--argjson cdnOptDomains "$CDN_OPT_DOMAINS" \
	'
		def common($group; $remark; $sortOrder; $alpn):
			$group.remark == $remark
			and $group.sortOrder == $sortOrder
			and $group.isDisabled == false
			and $group.isHidden == false
			and $group.port == 443
			and $group.security == "tls"
			and $group.sni == $cdnDomain
			and $group.alpn == [$alpn]
			and $group.fingerprint == $fingerprint;
		def matches($groups; $groupId; $remark; $sortOrder; $host; $alpn):
			([ $groups[] | select(.groupId == $groupId) ] | length == 1)
			and ([ $groups[] | select(.groupId == $groupId) ][0] as $group
				| common($group; $remark; $sortOrder; $alpn)
				and $group.hosts == [($host + ":443")]);
		(.obj // []) as $groups
		| ($groups | length) == (2 * (1 + ($cdnOptDomains | length)))
		and matches($groups; ($vanillaGroupIdPrefix + "h2"); "Cloudflare Vanilla h2"; 0; $cdnDomain; "h2")
		and matches($groups; ($vanillaGroupIdPrefix + "h3"); "Cloudflare Vanilla h3"; 1; $cdnDomain; "h3")
		and all($cdnOptDomains | to_entries[];
			. as $entry
			| (($entry.key + 1) | tostring) as $index
			| ("3xsetupxhttpopt" + $index) as $groupIdPrefix
			| (($entry.key + 1) * 2) as $sortOrder
			| matches($groups; ($groupIdPrefix + "h2"); ("Cloudflare OPT " + $index + " h2"); $sortOrder; $entry.value; "h2")
			and matches($groups; ($groupIdPrefix + "h3"); ("Cloudflare OPT " + $index + " h3"); ($sortOrder + 1); $entry.value; "h3"))
	' "$HOSTS_RESPONSE_PATH" >/dev/null; then
	printf 'XHTTP Host配置不符合预期\n' >&2
	cat "$HOSTS_RESPONSE_PATH" >&2
	exit 1
fi
printf 'XHTTP Host配置OK\n'

printf '\n== 完成 ==\n'

# 执行3x-client-init.sh
chmod +x "$SCRIPT_DIR/3x-client-init.sh"
exec bash "$SCRIPT_DIR/3x-client-init.sh" "$@"

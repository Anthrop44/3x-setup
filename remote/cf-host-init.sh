#!/bin/bash

# 配置3x-ui订阅主机

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/cf-host-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
XHTTP_REMARK="Cloudflare"
VANILLA_GROUP_ID_PREFIX="3xsetupxhttpcdn1"

rm -f "$LOG_PATH"
exec >"$LOG_PATH" 2>&1

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

require_config_valid() {
	# 要求CDN主机配置存在且不重复
	if ! jq -e '
		. as $config
		| ($config.cdnOptDomains // []) as $domains
		| ($config.cdnDomain | type == "string" and length > 0)
		and ($domains | type == "array")
		and all($domains[]; type == "string" and length > 0)
		and (($domains | map(ascii_downcase) | unique | length) == ($domains | length))
		and all($domains[]; ascii_downcase != ($config.cdnDomain | ascii_downcase))
	' "$CONFIG_PATH" >/dev/null; then
		printf 'config.json 中的cdnDomain或cdnOptDomains无效\n' >&2
		exit 1
	fi
}

source "$SCRIPT_DIR/3x-ui-api.sh"

build_host_payload() {
	# 生成3x-ui Host组请求体
	local group_id="$1"
	local hosts_json="$2"
	local sort_order="$3"
	local remark="$4"
	local alpn="$5"

	jq -n \
		--arg groupId "$group_id" \
		--arg inboundId "$XHTTP_INBOUND_ID" \
		--argjson hosts "$hosts_json" \
		--argjson sortOrder "$sort_order" \
		--arg remark "$remark" \
		--arg alpn "$alpn" \
		--arg cdnDomain "$CDN_DOMAIN" \
		--arg fingerprint "$FINGERPRINT" \
		'{
			groupId: $groupId,
			inboundIds: [($inboundId | tonumber)],
			hosts: $hosts,
			sortOrder: $sortOrder,
			remark: $remark,
			isDisabled: false,
			isHidden: false,
			port: 443,
			security: "tls",
			sni: $cdnDomain,
			alpn: [$alpn],
			fingerprint: $fingerprint
		}' >"$HOST_PAYLOAD_PATH"
}

upsert_host_group() {
	# 新增或更新一个3x-ui Host组
	local group_id="$1"
	local label="$2"
	local endpoint

	if jq -e --arg groupId "$group_id" '(.obj // []) | any(.groupId == $groupId)' "$HOSTS_RESPONSE_PATH" >/dev/null; then
		endpoint="/panel/api/hosts/update/$group_id"
		printf '更新Host组: %s\n' "$label"
	else
		endpoint="/panel/api/hosts/bulk/add"
		printf '创建Host组: %s\n' "$label"
	fi
	api_post_file "$endpoint" "$HOST_PAYLOAD_PATH" "$HOST_RESPONSE_PATH"
	require_api_success "$HOST_RESPONSE_PATH" "同步Host组 $label 失败"
}

sync_host_pair() {
	# 为同一地址同步独立的H2和H3 Host组
	local group_id_prefix="$1"
	local domain="$2"
	local sort_order="$3"
	local remark="$4"
	local hosts_json

	hosts_json="$(jq -cn --arg domain "$domain" '[$domain]')"
	build_host_payload "${group_id_prefix}h2" "$hosts_json" "$sort_order" "$remark h2" "h2"
	upsert_host_group "${group_id_prefix}h2" "$remark h2"
	build_host_payload "${group_id_prefix}h3" "$hosts_json" "$((sort_order + 1))" "$remark h3" "h3"
	upsert_host_group "${group_id_prefix}h3" "$remark h3"
}

delete_extra_host_groups() {
	# 删除配置未定义的XHTTP Host组
	local extra_count

	api_get "/panel/api/hosts/byInbound/$XHTTP_INBOUND_ID" "$HOSTS_RESPONSE_PATH"
	require_api_success "$HOSTS_RESPONSE_PATH" "重新读取XHTTP Host失败"
	jq -n \
		--slurpfile response "$HOSTS_RESPONSE_PATH" \
		--argjson expectedGroupIds "$EXPECTED_GROUP_IDS" \
		'{
			ids: [
				($response[0].obj // [])[]
				| select(.groupId as $groupId | $expectedGroupIds | index($groupId) == null)
				| .groupId
			]
		}' >"$DELETE_PAYLOAD_PATH"
	extra_count="$(jq -r '.ids | length' "$DELETE_PAYLOAD_PATH")"
	printf '删除额外Host组数量: %s\n' "$extra_count"
	if [ "$extra_count" = "0" ]; then
		return 0
	fi
	api_post_file "/panel/api/hosts/bulk/del" "$DELETE_PAYLOAD_PATH" "$HOST_RESPONSE_PATH"
	require_api_success "$HOST_RESPONSE_PATH" "删除额外XHTTP Host组失败"
}

parse_args "$@"
require_config_valid

CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
CDN_OPT_DOMAINS="$(jq -c '.cdnOptDomains // []' "$CONFIG_PATH")"
OPT_DOMAIN_COUNT="$(jq -r 'length' <<<"$CDN_OPT_DOMAINS")"
EXPECTED_GROUP_IDS="$(jq -cn \
	--arg vanillaGroupIdPrefix "$VANILLA_GROUP_ID_PREFIX" \
	--argjson domains "$CDN_OPT_DOMAINS" \
	'[($vanillaGroupIdPrefix + "h2"), ($vanillaGroupIdPrefix + "h3")] + ($domains | to_entries | map(("3xsetupxhttpopt" + ((.key + 1) | tostring)) as $prefix | [($prefix + "h2"), ($prefix + "h3")]) | flatten)')"
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
HOST_PAYLOAD_PATH="$(mktemp)"
HOST_RESPONSE_PATH="$(mktemp)"
DELETE_PAYLOAD_PATH="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$LOGIN_PAGE_PATH" "$LOGIN_RESPONSE_PATH" "$INBOUNDS_RESPONSE_PATH" "$HOSTS_RESPONSE_PATH" "$HOST_PAYLOAD_PATH" "$HOST_RESPONSE_PATH" "$DELETE_PAYLOAD_PATH"' EXIT

printf '== 基本信息 ==\n'
date -Is
printf 'CDN域名: %s\n' "$CDN_DOMAIN"
printf '优选域名数量: %s\n' "$OPT_DOMAIN_COUNT"
jq -r '.[] | "优选域名: \(.)"' <<<"$CDN_OPT_DOMAINS"

login_panel

printf '\n== 查找XHTTP入站 ==\n'
api_get "/panel/api/inbounds/list" "$INBOUNDS_RESPONSE_PATH"
require_api_success "$INBOUNDS_RESPONSE_PATH" "读取3x-ui入站列表失败"
XHTTP_INBOUND_ID="$(get_unique_inbound_id "$XHTTP_REMARK")"
printf 'XHTTP入站ID: %s\n' "$XHTTP_INBOUND_ID"

printf '\n== 读取XHTTP Host ==\n'
api_get "/panel/api/hosts/byInbound/$XHTTP_INBOUND_ID" "$HOSTS_RESPONSE_PATH"
require_api_success "$HOSTS_RESPONSE_PATH" "读取XHTTP Host失败"
jq -r '(.obj // [])[] | [.groupId, .remark, (.hosts | join(",")), .port, .security, .sni, ((.alpn // []) | join(","))] | @tsv' "$HOSTS_RESPONSE_PATH"

printf '\n== 同步普通CDN Host ==\n'
sync_host_pair "$VANILLA_GROUP_ID_PREFIX" "$CDN_DOMAIN" 0 "Cloudflare Vanilla"

printf '\n== 同步优选CDN Host ==\n'
while IFS=$'\t' read -r OPT_INDEX OPT_DOMAIN; do
	OPT_GROUP_ID_PREFIX="3xsetupxhttpopt$OPT_INDEX"
	OPT_REMARK="Cloudflare OPT $OPT_INDEX"
	sync_host_pair "$OPT_GROUP_ID_PREFIX" "$OPT_DOMAIN" "$((OPT_INDEX * 2))" "$OPT_REMARK"
done < <(jq -r 'to_entries[] | [(.key + 1), .value] | @tsv' <<<"$CDN_OPT_DOMAINS")

printf '\n== 清理额外XHTTP Host ==\n'
delete_extra_host_groups

printf '\n== 完成 ==\n'

# 执行cf-host-check.sh
chmod +x "$SCRIPT_DIR/cf-host-check.sh"
exec bash "$SCRIPT_DIR/cf-host-check.sh" "$@"

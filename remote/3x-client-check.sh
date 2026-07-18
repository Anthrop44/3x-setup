#!/bin/bash

# 检查3x-ui客户端

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
OUTPUT_FILE="$LOG_DIR/3x-client-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"

rm -f "$OUTPUT_FILE"
exec >"$OUTPUT_FILE" 2>&1

DIRECT_DOMAIN="$(jq -r '.directDomain' "$CONFIG_PATH")"
CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
CDN_OPT_DOMAINS="$(jq -c '.cdnOptDomains // []' "$CONFIG_PATH")"
PANEL_USERNAME="$(jq -r '."3xusername"' "$CONSTANTS_PATH")"
PANEL_PASSWORD="$(jq -r '."3xpassword"' "$CONSTANTS_PATH")"
PANEL_PORT="$(jq -r '."3xpanelPort"' "$CONSTANTS_PATH")"
PANEL_URI_PATH="$(jq -r '."3xpanelUriPath"' "$CONSTANTS_PATH")"
FAKE_SITE_PORT="$(jq -r '.fakeSitePort' "$CONSTANTS_PATH")"
CDN_PORT="$(jq -r '.cdnPort' "$CONFIG_PATH")"
XHTTP_PORT="$(jq -r '.xhttpPort' "$CONSTANTS_PATH")"
FINGERPRINT="$(jq -r '.fingerprint' "$CONSTANTS_PATH")"
CLIENT_COUNT="$(jq -r '.clients | length' "$CONFIG_PATH")"
TEST_CLIENT_EMAIL="$(jq -r '.clients[0].client' "$CONFIG_PATH")"
TEST_CLIENT_SUB_ID="$(jq -r '.clients[0].path' "$CONFIG_PATH")"
XHTTP_PATH="$(jq -r '.xhttpPath' "$PATHS_PATH")"
PANEL_BASE_URL="http://127.0.0.1:$PANEL_PORT/$PANEL_URI_PATH"
PANEL_ROOT_URL="$PANEL_BASE_URL/"
HY2_REMARK="QUIC"
REALITY_REMARK="TCP"
XHTTP_REMARK="Cloudflare"
REALITY_SOCKS_PORT="12080"
XHTTP_SOCKS_PORT="12081"
PROXY_TEST_URL="https://www.cloudflare.com/cdn-cgi/trace"
TEST_XRAY_PIDS=""
CLIENT_UUID=""

COOKIE_JAR="$(mktemp)"
LOGIN_PAGE_PATH="$(mktemp)"
LOGIN_RESPONSE_PATH="$(mktemp)"
INBOUNDS_RESPONSE_PATH="$(mktemp)"
CLIENT_RESPONSE_PATH="$(mktemp)"
LINKS_RESPONSE_PATH="$(mktemp)"
SUB_LINKS_RESPONSE_PATH="$(mktemp)"
STATUS_RESPONSE_PATH="$(mktemp)"
REALITY_CONFIG_PATH="$(mktemp --suffix=.json)"
XHTTP_CONFIG_PATH="$(mktemp --suffix=.json)"
REALITY_LOG_PATH="$(mktemp)"
XHTTP_LOG_PATH="$(mktemp)"

cleanup() {
	# 清理临时文件和测试Xray进程
	local pid

	for pid in $TEST_XRAY_PIDS; do
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	done
	rm -f "$COOKIE_JAR" "$LOGIN_PAGE_PATH" "$LOGIN_RESPONSE_PATH" "$INBOUNDS_RESPONSE_PATH" "$CLIENT_RESPONSE_PATH" "$LINKS_RESPONSE_PATH" "$SUB_LINKS_RESPONSE_PATH" "$STATUS_RESPONSE_PATH" "$REALITY_CONFIG_PATH" "$XHTTP_CONFIG_PATH" "$REALITY_LOG_PATH" "$XHTTP_LOG_PATH"
}
trap cleanup EXIT

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

find_xray_bin() {
	# 查找3x-ui安装的Xray二进制
	local candidate

	for candidate in \
		"/usr/local/x-ui/bin/xray-linux-amd64" \
		"/usr/local/x-ui/bin/xray-linux-64" \
		"/usr/local/x-ui/bin/xray"; do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	candidate="$(sudo -n find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -perm -111 2>/dev/null | head -n 1)"
	if [ -n "$candidate" ]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	printf '找不到Xray二进制\n' >&2
	exit 1
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

require_links_valid() {
	# 要求客户端分享或订阅链接符合预期
	local response_path="$1"
	local message="$2"

	jq -r 'def links: if (.obj | type) == "array" then .obj elif (.obj.externalLinks? | type) == "array" then .obj.externalLinks elif (.obj | type) == "string" then (.obj | split("\n") | map(select(length > 0))) else [] end; links[]' "$response_path"
	if ! jq -e \
		--arg directDomain "$DIRECT_DOMAIN" \
		--arg cdnDomain "$CDN_DOMAIN" \
		--argjson cdnOptDomains "$CDN_OPT_DOMAINS" \
		--arg cdnPort "$CDN_PORT" \
		--arg xhttpPort "$XHTTP_PORT" \
		--arg hy2Remark "$HY2_REMARK" \
		--arg realityRemark "$REALITY_REMARK" \
		'
			def links: if (.obj | type) == "array" then .obj elif (.obj.externalLinks? | type) == "array" then .obj.externalLinks elif (.obj | type) == "string" then (.obj | split("\n") | map(select(length > 0))) else [] end;
			def encoded_remark($remark): ($remark | @uri);
			def xhttp_link($link; $domain; $alpn):
				($link | startswith("vless://"))
				and ($link | contains("@" + $domain + ":443"))
				and ($link | contains("type=xhttp"))
				and ($link | contains("alpn=" + $alpn));
			links as $links
			| ($cdnOptDomains | length) as $optCount
			| ($links | length == (4 + (2 * $optCount)))
			and any($links[]; startswith("hysteria2://") and contains("@" + $directDomain + ":443") and (contains($hy2Remark) or contains(encoded_remark($hy2Remark))))
			and any($links[]; startswith("vless://") and contains("@" + $directDomain + ":443") and contains("flow=xtls-rprx-vision") and (contains($realityRemark) or contains(encoded_remark($realityRemark))))
			and ([ $links[] | select(xhttp_link(.; $cdnDomain; "h2")) ] | length == 1)
			and ([ $links[] | select(xhttp_link(.; $cdnDomain; "h3")) ] | length == 1)
			and all($cdnOptDomains[]; . as $domain
				| ([ $links[] | select(xhttp_link(.; $domain; "h2")) ] | length == 1)
				and ([ $links[] | select(xhttp_link(.; $domain; "h3")) ] | length == 1))
			and all($links[]; test("^(vless|hysteria2)://[^@]+@[^:/?#]+:443([/?#]|$)"))
			and all($links[]; (contains(":" + $cdnPort) | not) and (contains(":" + $xhttpPort) | not))
		' "$response_path" >/dev/null; then
		printf '%s\n' "$message" >&2
		cat "$response_path" >&2
		exit 1
	fi
}

check_client() {
	# 检查一个3x-ui客户端
	local client_email="$1"
	local client_sub_id="$2"
	local client_traffic="$3"
	local client_uuid
	local expected_total_gb
	local expected_reset

	expected_total_gb=$((client_traffic * 1024 * 1024 * 1024))
	if [ "$client_traffic" -gt 0 ]; then
		expected_reset=30
	else
		expected_reset=0
	fi

	printf '\n== 检查客户端 %s ==\n' "$client_email"
	printf '预期流量: %sGB totalGB=%s reset=%s\n' "$client_traffic" "$expected_total_gb" "$expected_reset"
	api_get "/panel/api/clients/get/$client_email" "$CLIENT_RESPONSE_PATH"
	require_api_success "$CLIENT_RESPONSE_PATH" "读取客户端 $client_email 失败"
	if ! jq -e \
		--arg email "$client_email" \
		--arg subId "$client_sub_id" \
		--arg hy2InboundId "$HY2_INBOUND_ID" \
		--arg realityInboundId "$REALITY_INBOUND_ID" \
		--arg xhttpInboundId "$XHTTP_INBOUND_ID" \
		--argjson expectedTotalGB "$expected_total_gb" \
		--argjson expectedReset "$expected_reset" \
		'
			.obj.client.email == $email
			and .obj.client.subId == $subId
			and ((.obj.client.totalGB // 0) == $expectedTotalGB)
			and ((.obj.client.reset // 0) == $expectedReset)
			and ((.obj.client.comment // "") == "")
			and .obj.client.enable == true
			and ((.obj.client.auth // "") | length >= 16)
			and (.obj.inboundIds | index($hy2InboundId | tonumber) != null)
			and (.obj.inboundIds | index($realityInboundId | tonumber) != null)
			and (.obj.inboundIds | index($xhttpInboundId | tonumber) != null)
		' "$CLIENT_RESPONSE_PATH" >/dev/null; then
		printf '客户端 %s 配置不符合预期\n' "$client_email" >&2
		cat "$CLIENT_RESPONSE_PATH" >&2
		exit 1
	fi

	client_uuid="$(jq -r '.obj.client.uuid // .obj.client.id // empty' "$CLIENT_RESPONSE_PATH")"
	if [ -z "$client_uuid" ]; then
		printf '客户端 %s 缺少UUID\n' "$client_email" >&2
		cat "$CLIENT_RESPONSE_PATH" >&2
		exit 1
	fi
	printf '客户端UUID: %s\n' "$client_uuid"
	if [ "$client_email" = "$TEST_CLIENT_EMAIL" ]; then
		CLIENT_UUID="$client_uuid"
	fi

	printf '\n== 读取客户端 %s 分享链接 ==\n' "$client_email"
	api_get "/panel/api/clients/links/$client_email" "$LINKS_RESPONSE_PATH"
	require_api_success "$LINKS_RESPONSE_PATH" "读取客户端 $client_email 分享链接失败"
	jq -r 'def links: if (.obj | type) == "array" then .obj elif (.obj.externalLinks? | type) == "array" then .obj.externalLinks elif (.obj | type) == "string" then (.obj | split("\n") | map(select(length > 0))) else [] end; links[]' "$LINKS_RESPONSE_PATH"
	printf '3X-UI客户端分享链接不应用Host，XHTTP会保留入站监听端口\n'

	printf '\n== 读取客户端 %s 订阅链接 ==\n' "$client_email"
	api_get "/panel/api/clients/subLinks/$client_sub_id" "$SUB_LINKS_RESPONSE_PATH"
	require_api_success "$SUB_LINKS_RESPONSE_PATH" "读取客户端 $client_email 订阅链接失败"
	require_links_valid "$SUB_LINKS_RESPONSE_PATH" "客户端 $client_email 订阅链接没有全部使用443"
}

build_reality_client_config() {
	# 生成Reality临时客户端配置
	jq -n \
		--arg uuid "$CLIENT_UUID" \
		--arg directDomain "$DIRECT_DOMAIN" \
		--arg fingerprint "$FINGERPRINT" \
		--arg publicKey "$REALITY_PUBLIC_KEY" \
		--arg shortId "$REALITY_SHORT_ID" \
		--arg socksPort "$REALITY_SOCKS_PORT" \
		'{
			log: {
				loglevel: "warning"
			},
			inbounds: [
				{
					tag: "socks",
					listen: "127.0.0.1",
					port: ($socksPort | tonumber),
					protocol: "socks",
					settings: {
						auth: "noauth",
						udp: false
					}
				}
			],
			outbounds: [
				{
					tag: "proxy",
					protocol: "vless",
					settings: {
						vnext: [
							{
								address: "127.0.0.1",
								port: 443,
								users: [
									{
										id: $uuid,
										encryption: "none",
										flow: "xtls-rprx-vision"
									}
								]
							}
						]
					},
					streamSettings: {
						network: "tcp",
						security: "reality",
						realitySettings: {
							serverName: $directDomain,
							fingerprint: $fingerprint,
							publicKey: $publicKey,
							shortId: $shortId,
							spiderX: "/"
						}
					}
				}
			]
		}' >"$REALITY_CONFIG_PATH"
}

build_xhttp_client_config() {
	# 生成XHTTP临时客户端配置
	jq -n \
		--arg uuid "$CLIENT_UUID" \
		--arg xhttpPort "$XHTTP_PORT" \
		--arg xhttpPath "$XHTTP_PATH" \
		--arg socksPort "$XHTTP_SOCKS_PORT" \
		'{
			log: {
				loglevel: "warning"
			},
			inbounds: [
				{
					tag: "socks",
					listen: "127.0.0.1",
					port: ($socksPort | tonumber),
					protocol: "socks",
					settings: {
						auth: "noauth",
						udp: false
					}
				}
			],
			outbounds: [
				{
					tag: "proxy",
					protocol: "vless",
					settings: {
						vnext: [
							{
								address: "127.0.0.1",
								port: ($xhttpPort | tonumber),
								users: [
									{
										id: $uuid,
										encryption: "none"
									}
								]
							}
						]
					},
					streamSettings: {
						network: "xhttp",
						security: "none",
						xhttpSettings: {
							path: ("/" + $xhttpPath),
							host: "",
							mode: "auto"
						}
					}
				}
			]
		}' >"$XHTTP_CONFIG_PATH"
}

run_xray_proxy_test() {
	# 通过临时SOCKS代理验证Xray客户端可用
	local name="$1"
	local config_path="$2"
	local socks_port="$3"
	local log_path="$4"
	local xray_pid
	local index

	if ss -lnt 2>&1 | awk '{print $4}' | grep -E "^(127\\.0\\.0\\.1|\\[::1\\]):$socks_port$" >/dev/null; then
		printf '测试端口%s已被占用\n' "$socks_port" >&2
		exit 1
	fi

	"$XRAY_BIN" run -config "$config_path" >"$log_path" 2>&1 &
	xray_pid="$!"
	TEST_XRAY_PIDS="$TEST_XRAY_PIDS $xray_pid"

	for index in $(seq 1 20); do
		if ss -lnt 2>&1 | awk '{print $4}' | grep -E "^(127\\.0\\.0\\.1|\\[::1\\]):$socks_port$" >/dev/null; then
			break
		fi
		if ! kill -0 "$xray_pid" 2>/dev/null; then
			printf '%s测试Xray提前退出\n' "$name" >&2
			cat "$log_path" >&2
			exit 1
		fi
		if [ "$index" -eq 20 ]; then
			printf '%s测试SOCKS端口启动超时\n' "$name" >&2
			cat "$log_path" >&2
			exit 1
		fi
		sleep 1
	done

	if ! curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:$socks_port" "$PROXY_TEST_URL" >/dev/null; then
		printf '%s代理请求失败\n' "$name" >&2
		cat "$log_path" >&2
		exit 1
	fi

	kill "$xray_pid" 2>/dev/null || true
	wait "$xray_pid" 2>/dev/null || true
	printf '%s代理测试OK\n' "$name"
}

printf '== 基本信息 ==\n'
date -Is
printf '客户端数量: %s\n' "$CLIENT_COUNT"
printf '测试客户端: %s\n' "$TEST_CLIENT_EMAIL"
printf '测试订阅ID: %s\n' "$TEST_CLIENT_SUB_ID"
printf 'Reality域名: %s\n' "$DIRECT_DOMAIN"
printf 'CDN域名: %s\n' "$CDN_DOMAIN"

login_panel

printf '\n== 读取入站和客户端 ==\n'
api_get "/panel/api/inbounds/list" "$INBOUNDS_RESPONSE_PATH"
require_api_success "$INBOUNDS_RESPONSE_PATH" "读取3x-ui入站列表失败"
HY2_INBOUND_ID="$(get_unique_inbound_id "$HY2_REMARK")"
REALITY_INBOUND_ID="$(get_unique_inbound_id "$REALITY_REMARK")"
XHTTP_INBOUND_ID="$(get_unique_inbound_id "$XHTTP_REMARK")"

while IFS= read -r CLIENT_ENTRY; do
	CLIENT_EMAIL="$(jq -r '.client' <<<"$CLIENT_ENTRY")"
	CLIENT_SUB_ID="$(jq -r '.path' <<<"$CLIENT_ENTRY")"
	CLIENT_TRAFFIC="$(jq -r '.traffic // 0' <<<"$CLIENT_ENTRY")"
	check_client "$CLIENT_EMAIL" "$CLIENT_SUB_ID" "$CLIENT_TRAFFIC"
done < <(jq -c '.clients[]' "$CONFIG_PATH")

if [ -z "$CLIENT_UUID" ]; then
	printf '测试客户端 %s 缺少UUID\n' "$TEST_CLIENT_EMAIL" >&2
	exit 1
fi

printf '\n== Xray状态 ==\n'
api_get "/panel/api/server/status" "$STATUS_RESPONSE_PATH"
require_api_success "$STATUS_RESPONSE_PATH" "读取Xray状态失败"
cat "$STATUS_RESPONSE_PATH"
require_jq "$STATUS_RESPONSE_PATH" "Xray没有运行" '(.obj.xray.state // .obj.state // "") == "running"'

printf '\n== 监听端口 ==\n'
sudo -n ss -lntup 2>&1 | grep -E ":(443|$XHTTP_PORT)\\b"
sudo -n ss -H -lnup 2>&1 | grep -E "[[:space:]]([^[:space:]]+:)?443[[:space:]]" >/dev/null
sudo -n ss -H -lntp 2>&1 | grep -E "[[:space:]]([^[:space:]]+:)?443[[:space:]]" >/dev/null
sudo -n ss -H -lntp 2>&1 | grep -E "[[:space:]](127\\.0\\.0\\.1|\\[::1\\]):$XHTTP_PORT[[:space:]]" >/dev/null
if sudo -n ss -H -lntp 2>&1 | grep -E "[[:space:]](0\\.0\\.0\\.0|\\*|\\[::\\]):$XHTTP_PORT[[:space:]]" >/dev/null; then
	printf 'XHTTP入站正在公网监听\n' >&2
	exit 1
fi
sudo -n ufw status verbose | grep -Eq '^443/tcp[[:space:]]+ALLOW IN'
sudo -n ufw status verbose | grep -Eq '^443/udp[[:space:]]+ALLOW IN'

printf '\n== 准备端到端测试 ==\n'
XRAY_BIN="$(find_xray_bin)"
REALITY_PUBLIC_KEY="$(jq -r --arg remark "$REALITY_REMARK" 'def decoded: if type == "string" then fromjson else . end; .obj[] | select(.remark == $remark) | (.streamSettings | decoded) | .realitySettings.settings.publicKey // empty' "$INBOUNDS_RESPONSE_PATH")"
REALITY_SHORT_ID="$(jq -r --arg remark "$REALITY_REMARK" 'def decoded: if type == "string" then fromjson else . end; .obj[] | select(.remark == $remark) | (.streamSettings | decoded) | .realitySettings.shortIds[0] // empty' "$INBOUNDS_RESPONSE_PATH")"
if [ -z "$REALITY_PUBLIC_KEY" ] || [ -z "$REALITY_SHORT_ID" ]; then
	printf 'Reality入站缺少客户端测试所需publicKey或shortId\n' >&2
	cat "$INBOUNDS_RESPONSE_PATH" >&2
	exit 1
fi
printf 'Xray二进制: %s\n' "$XRAY_BIN"

build_reality_client_config
build_xhttp_client_config

printf '\n== Reality代理测试 ==\n'
run_xray_proxy_test "Reality" "$REALITY_CONFIG_PATH" "$REALITY_SOCKS_PORT" "$REALITY_LOG_PATH"

printf '\n== XHTTP代理测试 ==\n'
run_xray_proxy_test "XHTTP" "$XHTTP_CONFIG_PATH" "$XHTTP_SOCKS_PORT" "$XHTTP_LOG_PATH"

printf '\n== 失败单元 ==\n'
sudo -n systemctl --failed --no-pager 2>&1 || true
ensure_no_failed_units

printf '\n== 完成 ==\n'

# 执行后续初始化脚本
for arg in "$@"; do
	if [ "$arg" = "--noAPP" ]; then
		printf '收到--noAPP，跳过代理客户端静态分发\n'
		chmod +x "$SCRIPT_DIR/direct-tls-init.sh"
		next_args=()
		for next_arg in "$@"; do
			if [ "$next_arg" != "--noAPP" ]; then
				next_args+=("$next_arg")
			fi
		done
		exec bash "$SCRIPT_DIR/direct-tls-init.sh" "${next_args[@]}"
	fi
done

chmod +x "$SCRIPT_DIR/fetch-apps-init.sh"
exec bash "$SCRIPT_DIR/fetch-apps-init.sh" "$@"

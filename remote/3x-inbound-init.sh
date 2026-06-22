#!/bin/bash

# 配置3x-ui入站

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/3x-inbound-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"

rm -f "$LOG_PATH"
exec >"$LOG_PATH" 2>&1

DIRECT_DOMAIN="$(jq -r '.directDomain' "$CONFIG_PATH")"
CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
PANEL_USERNAME="$(jq -r '."3xusername"' "$CONSTANTS_PATH")"
PANEL_PASSWORD="$(jq -r '."3xpassword"' "$CONSTANTS_PATH")"
PANEL_PORT="$(jq -r '."3xpanelPort"' "$CONSTANTS_PATH")"
PANEL_URI_PATH="$(jq -r '."3xpanelUriPath"' "$CONSTANTS_PATH")"
XHTTP_PORT="$(jq -r '.xhttpPort' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort' "$CONSTANTS_PATH")"
XHTTP_PATH="$(jq -r '.xhttpPath' "$PATHS_PATH")"
PANEL_BASE_URL="http://127.0.0.1:$PANEL_PORT/$PANEL_URI_PATH"
PANEL_ROOT_URL="$PANEL_BASE_URL/"
REALITY_REMARK="Direct"
XHTTP_REMARK="CDN"

COOKIE_JAR="$(mktemp)"
LOGIN_PAGE_PATH="$(mktemp)"
LOGIN_RESPONSE_PATH="$(mktemp)"
CERT_RESPONSE_PATH="$(mktemp)"
REALITY_PAYLOAD_PATH="$(mktemp)"
REALITY_RESPONSE_PATH="$(mktemp)"
XHTTP_PAYLOAD_PATH="$(mktemp)"
XHTTP_RESPONSE_PATH="$(mktemp)"
RESTART_RESPONSE_PATH="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$LOGIN_PAGE_PATH" "$LOGIN_RESPONSE_PATH" "$CERT_RESPONSE_PATH" "$REALITY_PAYLOAD_PATH" "$REALITY_RESPONSE_PATH" "$XHTTP_PAYLOAD_PATH" "$XHTTP_RESPONSE_PATH" "$RESTART_RESPONSE_PATH"' EXIT

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

wait_any_listen_port() {
	# 等待任意地址开始监听指定端口
	local port="$1"
	local label="$2"
	local index

	for index in $(seq 1 30); do
		if sudo -n ss -lntp 2>&1 | awk '{print $4}' | grep -E "[:.]$port$" >/dev/null; then
			return 0
		fi
		sleep 1
	done
	printf '等待%s监听端口%s超时\n' "$label" "$port" >&2
	exit 1
}

wait_local_listen_port() {
	# 等待本机地址开始监听指定端口
	local port="$1"
	local label="$2"
	local index

	for index in $(seq 1 30); do
		if sudo -n ss -lntp 2>&1 | awk '{print $4}' | grep -E "^(127\\.0\\.0\\.1|\\[::1\\]):$port$" >/dev/null; then
			return 0
		fi
		sleep 1
	done
	printf '等待%s监听本机端口%s超时\n' "$label" "$port" >&2
	exit 1
}

printf '== 基本信息 ==\n'
date -Is
printf 'Reality入站: %s -> %s:443\n' "$REALITY_REMARK" "$DIRECT_DOMAIN"
printf 'XHTTP入站: %s -> %s:443\n' "$XHTTP_REMARK" "$CDN_DOMAIN"

login_panel

printf '\n== 生成Reality密钥 ==\n'
api_get "/panel/api/server/getNewX25519Cert" "$CERT_RESPONSE_PATH"
require_api_success "$CERT_RESPONSE_PATH" "生成Reality密钥失败"
REALITY_PRIVATE_KEY="$(jq -r '.obj.privateKey // empty' "$CERT_RESPONSE_PATH")"
REALITY_PUBLIC_KEY="$(jq -r '.obj.publicKey // empty' "$CERT_RESPONSE_PATH")"
REALITY_SHORT_ID="$(openssl rand -hex 8)"
if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
	printf 'Reality密钥响应缺少privateKey或publicKey\n' >&2
	cat "$CERT_RESPONSE_PATH" >&2
	exit 1
fi

printf '\n== 创建Reality入站 ==\n'
jq -n \
	--arg remark "$REALITY_REMARK" \
	--arg directDomain "$DIRECT_DOMAIN" \
	--arg realityTargetPort "$REALITY_TARGET_PORT" \
	--arg privateKey "$REALITY_PRIVATE_KEY" \
	--arg publicKey "$REALITY_PUBLIC_KEY" \
	--arg shortId "$REALITY_SHORT_ID" \
	'{
		enable: true,
		remark: $remark,
		listen: "",
		port: 443,
		protocol: "vless",
		expiryTime: 0,
		total: 0,
		trafficReset: "never",
		shareAddrStrategy: "custom",
		shareAddr: $directDomain,
		subSortIndex: 1,
		settings: {
			clients: [],
			decryption: "none",
			encryption: "none",
			fallbacks: []
		},
		streamSettings: {
			network: "tcp",
			security: "reality",
			tcpSettings: {
				acceptProxyProtocol: false,
				header: {
					type: "none"
				}
			},
			realitySettings: {
				show: false,
				xver: 0,
				target: ("127.0.0.1:" + $realityTargetPort),
				serverNames: [
					$directDomain
				],
				privateKey: $privateKey,
				minClientVer: "",
				maxClientVer: "",
				maxTimediff: 0,
				shortIds: [
					$shortId
				],
				mldsa65Seed: "",
				settings: {
					publicKey: $publicKey,
					fingerprint: "chrome",
					serverName: $directDomain,
					spiderX: "/",
					mldsa65Verify: ""
				}
			}
		},
		sniffing: {
			enabled: true,
			destOverride: [
				"http",
				"tls",
				"quic"
			],
			metadataOnly: false,
			routeOnly: false,
			ipsExcluded: [],
			domainsExcluded: []
		}
	}' >"$REALITY_PAYLOAD_PATH"
api_post_file "/panel/api/inbounds/add" "$REALITY_PAYLOAD_PATH" "$REALITY_RESPONSE_PATH"
require_api_success "$REALITY_RESPONSE_PATH" "创建Reality入站失败"

printf '\n== 创建XHTTP入站 ==\n'
jq -n \
	--arg remark "$XHTTP_REMARK" \
	--arg cdnDomain "$CDN_DOMAIN" \
	--arg xhttpPort "$XHTTP_PORT" \
	--arg xhttpPath "$XHTTP_PATH" \
	'{
		enable: true,
		remark: $remark,
		listen: "127.0.0.1",
		port: ($xhttpPort | tonumber),
		protocol: "vless",
		expiryTime: 0,
		total: 0,
		trafficReset: "never",
		shareAddrStrategy: "listen",
		shareAddr: "",
		subSortIndex: 2,
		settings: {
			clients: [],
			decryption: "none",
			encryption: "none",
			fallbacks: []
		},
		streamSettings: {
			network: "xhttp",
			security: "none",
			xhttpSettings: {
				path: ("/" + $xhttpPath),
				host: "",
				mode: "auto",
				xPaddingBytes: "100-1000",
				xPaddingObfsMode: false,
				xPaddingKey: "",
				xPaddingHeader: "",
				xPaddingPlacement: "",
				xPaddingMethod: "",
				sessionPlacement: "",
				sessionKey: "",
				seqPlacement: "",
				seqKey: "",
				uplinkDataPlacement: "",
				uplinkDataKey: "",
				scMaxEachPostBytes: "",
				noSSEHeader: false,
				scMaxBufferedPosts: 30,
				scStreamUpServerSecs: "20-80",
				serverMaxHeaderBytes: 0,
				uplinkHTTPMethod: "",
				headers: {},
				scMinPostsIntervalMs: "",
				uplinkChunkSize: 0,
				noGRPCHeader: false
			},
			externalProxy: [
				{
					forceTls: "tls",
					dest: $cdnDomain,
					port: 443,
					remark: "",
					sni: $cdnDomain
				}
			]
		},
		sniffing: {
			enabled: true,
			destOverride: [
				"http",
				"tls",
				"quic"
			],
			metadataOnly: false,
			routeOnly: false,
			ipsExcluded: [],
			domainsExcluded: []
		}
	}' >"$XHTTP_PAYLOAD_PATH"
api_post_file "/panel/api/inbounds/add" "$XHTTP_PAYLOAD_PATH" "$XHTTP_RESPONSE_PATH"
require_api_success "$XHTTP_RESPONSE_PATH" "创建XHTTP入站失败"

printf '\n== 重启Xray ==\n'
api_post_empty "/panel/api/server/restartXrayService" "$RESTART_RESPONSE_PATH"
require_api_success "$RESTART_RESPONSE_PATH" "重启Xray失败"
wait_any_listen_port "443" "Reality"
wait_local_listen_port "$XHTTP_PORT" "XHTTP"

printf '\n== 完成 ==\n'

# 执行 3x-inbound-check.sh
chmod +x "$SCRIPT_DIR/3x-inbound-check.sh"
exec bash "$SCRIPT_DIR/3x-inbound-check.sh"

#!/bin/bash

# 安装并配置3x-ui panel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/3x-panel-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"

exec >>"$LOG_PATH" 2>&1

# 读取 config.json、constants.json 和 paths.json
CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
PANEL_USERNAME="$(jq -r '."3xusername"' "$CONSTANTS_PATH")"
PANEL_PASSWORD="$(jq -r '."3xpassword"' "$CONSTANTS_PATH")"
PANEL_PORT="$(jq -r '."3xpanelPort"' "$CONSTANTS_PATH")"
PANEL_URI_PATH="$(jq -r '."3xpanelUriPath"' "$CONSTANTS_PATH")"
SUBSCRIPTION_PORT="$(jq -r '.subscriptionPort' "$CONSTANTS_PATH")"
SUBSCRIPTION_URI_PATH="$(jq -r '.subscriptionUriPath' "$PATHS_PATH")"
REVERSE_PROXY_URI="$(jq -r '.reverseProxyUri' "$PATHS_PATH")"

# 非交互式安装3x-ui
if curl -fsSL --retry 3 --connect-timeout 20 --max-time 900 \
	https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh | sudo env \
	XUI_NONINTERACTIVE=1 \
	XUI_USERNAME="$PANEL_USERNAME" \
	XUI_PASSWORD="$PANEL_PASSWORD" \
	XUI_PANEL_PORT="$PANEL_PORT" \
	XUI_WEB_BASE_PATH="$PANEL_URI_PATH" \
	XUI_SSL_MODE=none \
	XUI_DB_TYPE=sqlite \
	bash; then
	sudo /usr/local/x-ui/x-ui setting -port "$PANEL_PORT" -username "$PANEL_USERNAME" -password "$PANEL_PASSWORD" -webBasePath "$PANEL_URI_PATH"
	sudo /usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
	sudo systemctl restart x-ui
else
	echo "3x-ui安装失败" >&2
	exit 1
fi

# 配置订阅设置
PANEL_BASE_URL="http://127.0.0.1:$PANEL_PORT/$PANEL_URI_PATH"
PANEL_ROOT_URL="$PANEL_BASE_URL/"
for PANEL_WAIT_INDEX in $(seq 1 30); do
	if curl -fsS --max-time 5 "$PANEL_ROOT_URL" >/dev/null 2>&1; then
		break
	fi
	if [ "$PANEL_WAIT_INDEX" -eq 30 ]; then
		printf '等待3x-ui面板启动超时\n' >&2
		exit 1
	fi
	sleep 2
done

SUBSCRIPTION_PATH="/$SUBSCRIPTION_URI_PATH/"
COOKIE_JAR="$(mktemp)"
LOGIN_PAGE_PATH="$(mktemp)"
LOGIN_RESPONSE_PATH="$(mktemp)"
SETTINGS_RESPONSE_PATH="$(mktemp)"
SETTINGS_UPDATE_PATH="$(mktemp)"
SETTINGS_UPDATE_RESPONSE_PATH="$(mktemp)"
XRAY_RESPONSE_PATH="$(mktemp)"
XRAY_OBJECT_PATH="$(mktemp)"
XRAY_UPDATE_PATH="$(mktemp)"
XRAY_UPDATE_RESPONSE_PATH="$(mktemp)"
XRAY_RESTART_RESPONSE_PATH="$(mktemp)"
RESTART_PANEL_RESPONSE_PATH="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$LOGIN_PAGE_PATH" "$LOGIN_RESPONSE_PATH" "$SETTINGS_RESPONSE_PATH" "$SETTINGS_UPDATE_PATH" "$SETTINGS_UPDATE_RESPONSE_PATH" "$XRAY_RESPONSE_PATH" "$XRAY_OBJECT_PATH" "$XRAY_UPDATE_PATH" "$XRAY_UPDATE_RESPONSE_PATH" "$XRAY_RESTART_RESPONSE_PATH" "$RESTART_PANEL_RESPONSE_PATH"' EXIT

curl -fsS \
	-c "$COOKIE_JAR" \
	"$PANEL_ROOT_URL" >"$LOGIN_PAGE_PATH"
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

curl -fsS \
	-b "$COOKIE_JAR" \
	-H "X-CSRF-Token: $CSRF_TOKEN" \
	-X POST \
	"$PANEL_BASE_URL/panel/api/setting/all" >"$SETTINGS_RESPONSE_PATH"
if ! jq -e '.success == true and (.obj | type == "object")' "$SETTINGS_RESPONSE_PATH" >/dev/null; then
	printf '读取3x-ui设置失败\n' >&2
	cat "$SETTINGS_RESPONSE_PATH" >&2
	exit 1
fi

jq \
	--arg subListen "127.0.0.1" \
	--arg subPort "$SUBSCRIPTION_PORT" \
	--arg subPath "$SUBSCRIPTION_PATH" \
	--arg subDomain "$CDN_DOMAIN" \
	--arg subURI "$REVERSE_PROXY_URI" \
	--arg subTitle "$CDN_DOMAIN" \
	'.obj
	| .subEnable = true
	| .subJsonEnable = false
	| .subClashEnable = false
	| .subListen = $subListen
	| .subPort = ($subPort | tonumber)
	| .subPath = $subPath
	| .subDomain = $subDomain
	| .subURI = $subURI
	| .subCertFile = ""
	| .subKeyFile = ""
	| .subEncrypt = true
	| .subShowInfo = true
	| .subEmailInRemark = true
	| .remarkModel = (if (.remarkModel // "") == "" then "-ieo" else .remarkModel end)
	| .subUpdates = 120
	| .subTitle = $subTitle
	| .subSupportUrl = ""
	| .subProfileUrl = ""
	| .subAnnounce = "请勿将此订阅分享给任何人！"
	| .subThemeDir = ""' \
	"$SETTINGS_RESPONSE_PATH" >"$SETTINGS_UPDATE_PATH"

curl -fsS \
	-b "$COOKIE_JAR" \
	-H 'Content-Type: application/json' \
	-H "X-CSRF-Token: $CSRF_TOKEN" \
	-d @"$SETTINGS_UPDATE_PATH" \
	"$PANEL_BASE_URL/panel/api/setting/update" >"$SETTINGS_UPDATE_RESPONSE_PATH"
if ! jq -e '.success == true' "$SETTINGS_UPDATE_RESPONSE_PATH" >/dev/null; then
	printf '更新3x-ui订阅设置失败\n' >&2
	cat "$SETTINGS_UPDATE_RESPONSE_PATH" >&2
	exit 1
fi

curl -fsS \
	-b "$COOKIE_JAR" \
	-H "X-CSRF-Token: $CSRF_TOKEN" \
	-X POST \
	"$PANEL_BASE_URL/panel/api/xray/" >"$XRAY_RESPONSE_PATH"
if ! jq -e '.success == true' "$XRAY_RESPONSE_PATH" >/dev/null; then
	printf '读取Xray模板失败\n' >&2
	cat "$XRAY_RESPONSE_PATH" >&2
	exit 1
fi

jq 'if (.obj | type) == "string" then (.obj | fromjson) else .obj end' "$XRAY_RESPONSE_PATH" >"$XRAY_OBJECT_PATH"
if ! jq -e '(.xraySetting | type) == "object" or (.xraySetting | type) == "string"' "$XRAY_OBJECT_PATH" >/dev/null; then
	printf 'Xray模板响应缺少xraySetting\n' >&2
	cat "$XRAY_RESPONSE_PATH" >&2
	exit 1
fi

jq '.xraySetting | if type == "string" then fromjson else . end' "$XRAY_OBJECT_PATH" | jq '
	def happyEyeballs: {
		tryDelayMs: 0,
		prioritizeIPv6: false,
		interleave: 1,
		maxConcurrentTry: 4
	};
	.outbounds = (.outbounds // [])
	| if any(.outbounds[]?; .protocol == "freedom" and .tag == "direct") then
		.outbounds |= map(
			if .protocol == "freedom" and .tag == "direct" then
				.streamSettings = ((.streamSettings // {}) | .sockopt = ((.sockopt // {}) | .happyEyeballs = happyEyeballs))
			else
				.
			end
		)
	else
		.outbounds += [
			{
				protocol: "freedom",
				tag: "direct",
				settings: {},
				streamSettings: {
					sockopt: {
						happyEyeballs: happyEyeballs
					}
				}
			}
		]
	end' >"$XRAY_UPDATE_PATH"

OUTBOUND_TEST_URL="$(jq -r '.outboundTestUrl // ""' "$XRAY_OBJECT_PATH")"
curl -fsS \
	-b "$COOKIE_JAR" \
	-H "X-CSRF-Token: $CSRF_TOKEN" \
	--data-urlencode "xraySetting@$XRAY_UPDATE_PATH" \
	--data-urlencode "outboundTestUrl=$OUTBOUND_TEST_URL" \
	"$PANEL_BASE_URL/panel/api/xray/update" >"$XRAY_UPDATE_RESPONSE_PATH"
if ! jq -e '.success == true' "$XRAY_UPDATE_RESPONSE_PATH" >/dev/null; then
	printf '更新Xray模板失败\n' >&2
	cat "$XRAY_UPDATE_RESPONSE_PATH" >&2
	exit 1
fi

curl -fsS \
	-b "$COOKIE_JAR" \
	-H "X-CSRF-Token: $CSRF_TOKEN" \
	-X POST \
	"$PANEL_BASE_URL/panel/api/server/restartXrayService" >"$XRAY_RESTART_RESPONSE_PATH"
if ! jq -e '.success == true' "$XRAY_RESTART_RESPONSE_PATH" >/dev/null; then
	printf '重启Xray失败\n' >&2
	cat "$XRAY_RESTART_RESPONSE_PATH" >&2
	exit 1
fi

curl -fsS \
	-b "$COOKIE_JAR" \
	-H "X-CSRF-Token: $CSRF_TOKEN" \
	-X POST \
	"$PANEL_BASE_URL/panel/api/setting/restartPanel" >"$RESTART_PANEL_RESPONSE_PATH"
if ! jq -e '.success == true' "$RESTART_PANEL_RESPONSE_PATH" >/dev/null; then
	printf '重启3x-ui面板失败\n' >&2
	cat "$RESTART_PANEL_RESPONSE_PATH" >&2
	exit 1
fi

sleep 5
for PANEL_CHECK_INDEX in $(seq 1 30); do
	if curl -fsS --max-time 5 "$PANEL_ROOT_URL" >/dev/null 2>&1; then
		break
	fi
	if [ "$PANEL_CHECK_INDEX" -eq 30 ]; then
		printf '等待3x-ui面板恢复超时\n' >&2
		exit 1
	fi
	sleep 2
done

# 执行 3x-panel-check.sh
chmod +x "$SCRIPT_DIR/3x-panel-check.sh"
exec bash "$SCRIPT_DIR/3x-panel-check.sh"

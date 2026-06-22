#!/bin/bash

# 检查{directDomain}的TLS状态

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/direct-tls-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
FAKE_SITE_INDEX_PATH="/var/www/3x-fake-site/index.html"

rm -f "$LOG_PATH"
exec >"$LOG_PATH" 2>&1

DIRECT_DOMAIN="$(jq -r '.directDomain // empty' "$CONFIG_PATH")"
CDN_DOMAIN="$(jq -r '.cdnDomain // empty' "$CONFIG_PATH")"
IP_ADDRESS="$(jq -r '.ip // empty' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort // empty' "$CONFIG_PATH")"
FAKE_SITE_PORT="$(jq -r '.fakeSitePort // empty' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort // empty' "$CONSTANTS_PATH")"

require_fake_site_index() {
	# 要求本机已安装伪装站首页可读
	if [ ! -r "$FAKE_SITE_INDEX_PATH" ]; then
		printf '伪装站首页不可读: %s\n' "$FAKE_SITE_INDEX_PATH" >&2
		exit 1
	fi
}

require_fake_site() {
	# 要求指定URL返回已安装伪装站首页
	local label="$1"
	local url="$2"
	shift 2
	local body_path
	local actual_size
	local expected_size

	body_path="$(mktemp)"
	if ! curl -k -fsS --max-time 30 "$@" "$url" >"$body_path"; then
		printf '%s请求失败: %s\n' "$label" "$url" >&2
		rm -f "$body_path"
		exit 1
	fi
	if ! cmp -s "$FAKE_SITE_INDEX_PATH" "$body_path"; then
		expected_size="$(wc -c <"$FAKE_SITE_INDEX_PATH")"
		actual_size="$(wc -c <"$body_path")"
		printf '%s没有返回伪装站: %s\n' "$label" "$url" >&2
		printf '预期大小: %s bytes\n' "$expected_size" >&2
		printf '实际大小: %s bytes\n' "$actual_size" >&2
		rm -f "$body_path"
		exit 1
	fi
	printf '%s OK: %s\n' "$label" "$url"
	rm -f "$body_path"
}

require_http_redirect() {
	# 要求HTTP入口跳转到同Host的HTTPS
	local host_name="$1"
	local location

	location="$(curl -fsS -I --max-time 20 --resolve "$host_name:80:127.0.0.1" "http://$host_name/" 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^Location:/ {gsub("\r", "", $0); print $2; exit}')"
	if [ "$location" != "https://$host_name/" ]; then
		printf 'HTTP跳转不符合预期: %s -> %s\n' "$host_name" "$location" >&2
		exit 1
	fi
	printf 'HTTP跳转OK: %s -> %s\n' "$host_name" "$location"
}

require_public_direct_tls() {
	# 要求 directDomain 使用非Cloudflare源站证书
	local cert_info_path

	cert_info_path="$(mktemp)"
	if ! openssl s_client -connect "127.0.0.1:$REALITY_TARGET_PORT" -servername "$DIRECT_DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates -ext subjectAltName >"$cert_info_path" 2>/dev/null; then
		printf '读取 directDomain 证书失败\n' >&2
		rm -f "$cert_info_path"
		exit 1
	fi
	cat "$cert_info_path"
	if grep -qi 'CloudFlare Origin' "$cert_info_path"; then
		printf 'directDomain 仍在使用Cloudflare源站证书\n' >&2
		rm -f "$cert_info_path"
		exit 1
	fi
	rm -f "$cert_info_path"
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
printf '服务器IP: %s\n' "$IP_ADDRESS"
printf 'directDomain: %s\n' "$DIRECT_DOMAIN"
printf 'cdnDomain: %s\n' "$CDN_DOMAIN"
printf 'CDN端口: %s\n' "$CDN_PORT"
printf '伪装站端口: %s\n' "$FAKE_SITE_PORT"
printf '伪装站首页: %s\n' "$FAKE_SITE_INDEX_PATH"
printf 'Reality目标端口: %s\n' "$REALITY_TARGET_PORT"

printf '\n== Caddy服务状态 ==\n'
sudo -n systemctl --no-pager --full status caddy 2>&1
sudo -n systemctl is-active --quiet caddy

printf '\n== x-ui服务状态 ==\n'
sudo -n systemctl --no-pager --full status x-ui 2>&1
sudo -n systemctl is-active --quiet x-ui

printf '\n== Caddyfile ==\n'
sudo -n sed -n '1,260p' /etc/caddy/Caddyfile 2>&1

printf '\n== Caddy校验 ==\n'
sudo -n caddy validate --config /etc/caddy/Caddyfile 2>&1

printf '\n== directDomain 证书 ==\n'
sudo -n find /var/lib/caddy/.local/share/caddy/certificates -type f -path "*$DIRECT_DOMAIN*" -printf '%p %s bytes\n' 2>&1 | sort || true
sudo -n find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$DIRECT_DOMAIN.crt" -exec openssl x509 -in '{}' -noout -subject -issuer -dates -ext subjectAltName ';' 2>&1
require_public_direct_tls

printf '\n== 监听端口 ==\n'
sudo -n ss -lntp 2>&1 | grep -E ":(80|443|$CDN_PORT|$FAKE_SITE_PORT|$REALITY_TARGET_PORT)\\b"

printf '\n== 响应头探测 ==\n'
curl -k -fsS -I --max-time 20 --resolve "$DIRECT_DOMAIN:80:127.0.0.1" "http://$DIRECT_DOMAIN/" 2>&1
curl -k -fsS -I --max-time 20 "http://127.0.0.1:$FAKE_SITE_PORT/" 2>&1
curl -k -fsS -I --max-time 20 --resolve "$DIRECT_DOMAIN:$REALITY_TARGET_PORT:127.0.0.1" "https://$DIRECT_DOMAIN:$REALITY_TARGET_PORT/" 2>&1
curl -k -fsS -I --max-time 20 --resolve "$DIRECT_DOMAIN:443:127.0.0.1" "https://$DIRECT_DOMAIN/" 2>&1
curl -k -fsS -I --max-time 20 --resolve "probe.invalid:$CDN_PORT:127.0.0.1" "https://probe.invalid:$CDN_PORT/" 2>&1

printf '\n== 伪装站正文探测 ==\n'
require_fake_site_index
require_http_redirect "$DIRECT_DOMAIN"
require_fake_site "本机伪装站入口" "http://127.0.0.1:$FAKE_SITE_PORT/"
require_fake_site "directDomain 证书入口" "https://$DIRECT_DOMAIN:$REALITY_TARGET_PORT/" --resolve "$DIRECT_DOMAIN:$REALITY_TARGET_PORT:127.0.0.1"
require_fake_site "Reality公网fallback入口" "https://$DIRECT_DOMAIN/" --resolve "$DIRECT_DOMAIN:443:127.0.0.1"
require_fake_site "CDN回源默认入口" "https://probe.invalid:$CDN_PORT/" --resolve "probe.invalid:$CDN_PORT:127.0.0.1"
require_fake_site "CDN域名回源入口" "https://$CDN_DOMAIN:$CDN_PORT/" --resolve "$CDN_DOMAIN:$CDN_PORT:127.0.0.1"

printf '\n== 失败单元 ==\n'
sudo -n systemctl --failed --no-pager 2>&1 || true
ensure_no_failed_units

printf '\n== Caddy日志 ==\n'
sudo -n journalctl -u caddy --no-pager -n 160 2>&1 || true

printf '\n== x-ui日志 ==\n'
sudo -n journalctl -u x-ui --no-pager -n 120 2>&1 || true

printf '\n== 完成 ==\n'

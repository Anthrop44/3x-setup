#!/bin/bash

# 为{directDomain}申请TLS证书并自动续签

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/direct-tls-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"

rm -f "$LOG_PATH"
exec >"$LOG_PATH" 2>&1

DIRECT_DOMAIN="$(jq -r '.directDomain' "$CONFIG_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort' "$CONSTANTS_PATH")"

direct_domain_has_public_tls() {
	# 判断 directDomain 是否已经不是Cloudflare源站证书
	local cert_info_path

	cert_info_path="$(mktemp)"
	if ! openssl s_client -connect "127.0.0.1:$REALITY_TARGET_PORT" -servername "$DIRECT_DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates >"$cert_info_path" 2>/dev/null; then
		rm -f "$cert_info_path"
		return 1
	fi
	if grep -qi 'CloudFlare Origin' "$cert_info_path"; then
		cat "$cert_info_path"
		rm -f "$cert_info_path"
		return 1
	fi
	cat "$cert_info_path"
	rm -f "$cert_info_path"
	return 0
}

wait_direct_domain_tls() {
	# 等待Caddy为 directDomain 完成公信TLS握手
	local index

	for index in $(seq 1 60); do
		if curl -k -fsS --max-time 20 --resolve "$DIRECT_DOMAIN:$REALITY_TARGET_PORT:127.0.0.1" "https://$DIRECT_DOMAIN:$REALITY_TARGET_PORT/" >/dev/null && direct_domain_has_public_tls; then
			return 0
		fi
		sleep 5
	done

	printf '等待%s:%s TLS可用超时\n' "$DIRECT_DOMAIN" "$REALITY_TARGET_PORT" >&2
	exit 1
}

printf '== 基本信息 ==\n'
date -Is
printf 'directDomain: %s\n' "$DIRECT_DOMAIN"
printf 'Reality目标端口: %s\n' "$REALITY_TARGET_PORT"

printf '\n== 重载Caddy ==\n'
sudo -n caddy validate --config /etc/caddy/Caddyfile
sudo -n systemctl reload caddy || sudo -n systemctl restart caddy

printf '\n== 触发 directDomain 证书 ==\n'
wait_direct_domain_tls

printf '\n== 完成 ==\n'

# 执行 direct-tls-check.sh
chmod +x "$SCRIPT_DIR/direct-tls-check.sh"
exec bash "$SCRIPT_DIR/direct-tls-check.sh"

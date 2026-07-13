#!/bin/bash

# 为directDomain切换公信TLS证书

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/direct-tls-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"
DIRECT_CERT_FILE="/etc/caddy/3x-direct-cert.pem"
DIRECT_KEY_FILE="/etc/caddy/3x-direct-key.pem"
NO_TLS=0
DIRECT_DOMAIN_TLS_CONFIG_PATH="$(mktemp)"
trap 'rm -f "$DIRECT_DOMAIN_TLS_CONFIG_PATH"' EXIT

rm -f "$LOG_PATH"
exec >"$LOG_PATH" 2>&1

parse_args() {
	# 解析传入参数
	local arg

	for arg in "$@"; do
		case "$arg" in
		--noTLS)
			NO_TLS=1
			;;
		*)
			printf '未知参数: %s\n' "$arg" >&2
			exit 1
			;;
		esac
	done
}

write_file_tls_config() {
	# 写入Caddy文件证书TLS配置
	local output_path="$1"

	printf 'tls %s %s\n' "$DIRECT_CERT_FILE" "$DIRECT_KEY_FILE" >"$output_path"
}

write_acme_tls_config() {
	# 写入Caddy ACME证书TLS配置
	local output_path="$1"

	cat >"$output_path" <<'EOF'
tls {
	issuer acme {
		disable_tlsalpn_challenge
	}
}
EOF
}

render_caddyfile() {
	# 渲染Caddyfile模板
	sed \
		-e "s|{{AUTO_HTTPS_CONFIG}}|$AUTO_HTTPS_CONFIG|g" \
		-e "s|{{DIRECT_DOMAIN}}|$DIRECT_DOMAIN|g" \
		-e "s|{{CDN_DOMAIN}}|$CDN_DOMAIN|g" \
		-e "s|{{CDN_PORT}}|$CDN_PORT|g" \
		-e "s|{{SUBSCRIPTION_URI_PATH}}|$SUBSCRIPTION_URI_PATH|g" \
		-e "s|{{CLASH_SUBSCRIPTION_URI_PATH}}|$CLASH_SUBSCRIPTION_URI_PATH|g" \
		-e "s|{{SUBSCRIPTION_PORT}}|$SUBSCRIPTION_PORT|g" \
		-e "s|{{XHTTP_PATH}}|$XHTTP_PATH|g" \
		-e "s|{{XHTTP_PORT}}|$XHTTP_PORT|g" \
		-e "s|{{FAKE_SITE_PORT}}|$FAKE_SITE_PORT|g" \
		-e "s|{{REALITY_TARGET_PORT}}|$REALITY_TARGET_PORT|g" \
		"$SCRIPT_DIR/Caddyfile.template" | awk \
		-v direct_tls_path="$DIRECT_DOMAIN_TLS_CONFIG_PATH" '
			function print_file(path, indent, line) {
				while ((getline line < path) > 0) {
					print indent line
				}
				close(path)
			}
			{
				if (index($0, "{{DIRECT_DOMAIN_TLS_CONFIG}}") > 0) {
					indent = $0
					sub(/\{\{DIRECT_DOMAIN_TLS_CONFIG\}\}.*/, "", indent)
					print_file(direct_tls_path, indent)
				} else {
					print
				}
			}'
}

direct_domain_has_public_tls() {
	# 判断directDomain是否使用公信TLS证书
	local cert_info_path
	local subject
	local issuer

	cert_info_path="$(mktemp)"
	if ! openssl s_client -connect "127.0.0.1:$REALITY_TARGET_PORT" -servername "$DIRECT_DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates -ext subjectAltName >"$cert_info_path" 2>/dev/null; then
		rm -f "$cert_info_path"
		return 1
	fi
	cat "$cert_info_path"
	subject="$(sed -n 's/^subject=//p' "$cert_info_path" | head -n 1)"
	issuer="$(sed -n 's/^issuer=//p' "$cert_info_path" | head -n 1)"
	if [ "$subject" = "$issuer" ] || grep -Eqi 'CloudFlare Origin|STAGING|Fake LE' "$cert_info_path"; then
		rm -f "$cert_info_path"
		return 1
	fi
	rm -f "$cert_info_path"
	return 0
}

wait_direct_domain_tls() {
	# 等待Caddy为directDomain完成公信TLS握手
	local index

	for index in $(seq 1 60); do
		if curl -k -fsS --max-time 20 --resolve "$DIRECT_DOMAIN:$REALITY_TARGET_PORT:127.0.0.1" "https://$DIRECT_DOMAIN:$REALITY_TARGET_PORT/" >/dev/null && direct_domain_has_public_tls; then
			return 0
		fi
		sleep 5
	done

	printf '等待%s:%s公信TLS可用超时\n' "$DIRECT_DOMAIN" "$REALITY_TARGET_PORT" >&2
	exit 1
}

install_public_direct_cert() {
	# 将Caddy公信证书复制到稳定路径
	local public_cert_file="$PUBLIC_DIRECT_CERT_DIR/$DIRECT_DOMAIN.crt"
	local public_key_file="$PUBLIC_DIRECT_CERT_DIR/$DIRECT_DOMAIN.key"

	sudo -n test -s "$public_cert_file"
	sudo -n test -s "$public_key_file"
	sudo install -m 644 -o caddy -g caddy "$public_cert_file" "$DIRECT_CERT_FILE"
	sudo install -m 640 -o caddy -g caddy "$public_key_file" "$DIRECT_KEY_FILE"
	sudo -n openssl x509 -in "$DIRECT_CERT_FILE" -noout -subject -issuer -dates -ext subjectAltName
}

parse_args "$@"

DIRECT_DOMAIN="$(jq -r '.directDomain' "$CONFIG_PATH")"
AUTO_HTTPS_CONFIG="auto_https disable_redirects ignore_loaded_certs"
CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort' "$CONFIG_PATH")"
FAKE_SITE_PORT="$(jq -r '.fakeSitePort' "$CONSTANTS_PATH")"
XHTTP_PORT="$(jq -r '.xhttpPort' "$CONSTANTS_PATH")"
SUBSCRIPTION_PORT="$(jq -r '.subscriptionPort' "$CONSTANTS_PATH")"
CLASH_SUBSCRIPTION_PATH_SUFFIX="$(jq -r '.clashSubscriptionPathSuffix' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort' "$CONSTANTS_PATH")"
SUBSCRIPTION_URI_PATH="$(jq -r '.subscriptionPath' "$CONFIG_PATH")"
CLASH_SUBSCRIPTION_URI_PATH="${SUBSCRIPTION_URI_PATH}${CLASH_SUBSCRIPTION_PATH_SUFFIX}"
XHTTP_PATH="$(jq -r '.xhttpPath' "$PATHS_PATH")"
PUBLIC_DIRECT_CERT_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DIRECT_DOMAIN"

printf '== 基本信息 ==\n'
date -Is
printf 'directDomain: %s\n' "$DIRECT_DOMAIN"
printf 'Reality目标端口: %s\n' "$REALITY_TARGET_PORT"
printf '跳过公信TLS: %s\n' "$NO_TLS"

if [ "$NO_TLS" = "1" ]; then
	printf '\n== 跳过directDomain公信TLS初始化 ==\n'
	printf '收到--noTLS，不渲染ACME配置，不触发CA签发\n'
else
	printf '\n== 渲染ACME Caddyfile ==\n'
	write_acme_tls_config "$DIRECT_DOMAIN_TLS_CONFIG_PATH"
	render_caddyfile | sed '1s/.*/# Caddyfile正则替换成功产物/' | sudo tee /etc/caddy/Caddyfile >/dev/null
	sudo caddy fmt --overwrite /etc/caddy/Caddyfile
	sudo caddy validate --config /etc/caddy/Caddyfile

	printf '\n== 重载Caddy并触发directDomain公信证书 ==\n'
	sudo -n systemctl reload caddy || sudo -n systemctl restart caddy
	wait_direct_domain_tls

	printf '\n== 安装公信证书到稳定路径 ==\n'
	install_public_direct_cert
	sudo -n systemctl reload caddy || sudo -n systemctl restart caddy

	printf '\n== 重启x-ui加载新证书 ==\n'
	sudo -n systemctl restart x-ui
fi

printf '\n== 完成 ==\n'

# 执行 direct-tls-check.sh
chmod +x "$SCRIPT_DIR/direct-tls-check.sh"
exec bash "$SCRIPT_DIR/direct-tls-check.sh" "$@"

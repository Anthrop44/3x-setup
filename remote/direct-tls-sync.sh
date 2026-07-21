#!/bin/bash

# 同步Caddy续期后的directDomain证书

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="/etc/3x-setup/direct-tls-sync.conf"
TARGET_CERT_FILE="/etc/caddy/3x-direct-cert.pem"
TARGET_KEY_FILE="/etc/caddy/3x-direct-key.pem"
LOCK_PATH="/run/lock/3x-direct-tls-sync.lock"
MODE="sync"
source "$SCRIPT_DIR/script-timing.sh"

parse_args() {
	# 解析传入参数
	local arg

	for arg in "$@"; do
		case "$arg" in
		--check)
			MODE="check"
			;;
		--sync)
			MODE="sync"
			;;
		*)
			printf 'Unknown argument: %s\n' "$arg" >&2
			exit 1
			;;
		esac
	done
}

load_config() {
	# 读取受root保护的同步配置
	if [ ! -r "$CONFIG_PATH" ]; then
		printf 'Missing sync config: %s\n' "$CONFIG_PATH" >&2
		exit 1
	fi

	DIRECT_DOMAIN="$(sed -n 's/^DIRECT_DOMAIN=//p' "$CONFIG_PATH")"
	if [ -z "$DIRECT_DOMAIN" ] || [ "${#DIRECT_DOMAIN}" -gt 253 ] || [ "$(printf '%s\n' "$DIRECT_DOMAIN" | wc -l)" -ne 1 ] || ! printf '%s\n' "$DIRECT_DOMAIN" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'; then
		printf 'Invalid direct domain in sync config\n' >&2
		exit 1
	fi

	SOURCE_CERT_FILE="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DIRECT_DOMAIN/$DIRECT_DOMAIN.crt"
	SOURCE_KEY_FILE="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DIRECT_DOMAIN/$DIRECT_DOMAIN.key"
}

certificate_key_matches() {
	# 判断指定证书和私钥是否匹配
	local cert_file="$1"
	local key_file="$2"

	[ "$(openssl x509 -in "$cert_file" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)" = "$(openssl pkey -in "$key_file" -pubout -outform DER | sha256sum)" ]
}

require_public_certificate() {
	# 要求源文件是匹配directDomain的有效公信证书
	local cert_info_path
	local subject
	local issuer

	if [ ! -s "$SOURCE_CERT_FILE" ] || [ ! -s "$SOURCE_KEY_FILE" ]; then
		printf 'Missing Caddy managed certificate or key\n' >&2
		exit 1
	fi
	if ! openssl x509 -in "$SOURCE_CERT_FILE" -noout -checkend 0 >/dev/null; then
		printf 'Caddy managed certificate is expired or invalid\n' >&2
		exit 1
	fi
	if ! openssl x509 -in "$SOURCE_CERT_FILE" -noout -ext subjectAltName | grep -Eqi "DNS:$DIRECT_DOMAIN([,[:space:]]|$)"; then
		printf 'Caddy managed certificate does not cover direct domain\n' >&2
		exit 1
	fi

	cert_info_path="$(mktemp)"
	openssl x509 -in "$SOURCE_CERT_FILE" -noout -issuer -subject >"$cert_info_path"
	subject="$(sed -n 's/^subject=//p' "$cert_info_path" | head -n 1)"
	issuer="$(sed -n 's/^issuer=//p' "$cert_info_path" | head -n 1)"
	rm -f "$cert_info_path"
	if [ -z "$subject" ] || [ -z "$issuer" ] || [ "$subject" = "$issuer" ] || openssl x509 -in "$SOURCE_CERT_FILE" -noout -issuer | grep -Eqi 'CloudFlare Origin|STAGING|Fake LE'; then
		printf 'Caddy managed certificate is not public\n' >&2
		exit 1
	fi
	if ! certificate_key_matches "$SOURCE_CERT_FILE" "$SOURCE_KEY_FILE"; then
		printf 'Caddy managed certificate and key do not match\n' >&2
		exit 1
	fi
}

require_target_certificate() {
	# 要求目标文件与源文件完全一致
	if ! cmp -s "$SOURCE_CERT_FILE" "$TARGET_CERT_FILE" || ! cmp -s "$SOURCE_KEY_FILE" "$TARGET_KEY_FILE"; then
		printf 'Xray certificate is not synchronized\n' >&2
		exit 1
	fi
}

sync_certificate() {
	# 原子替换目标证书并重启x-ui
	local cert_temp_path
	local key_temp_path

	if cmp -s "$SOURCE_CERT_FILE" "$TARGET_CERT_FILE" && cmp -s "$SOURCE_KEY_FILE" "$TARGET_KEY_FILE"; then
		printf 'Xray certificate is already synchronized\n'
		return 0
	fi

	cert_temp_path="$(mktemp /etc/caddy/.3x-direct-cert.XXXXXX)"
	key_temp_path="$(mktemp /etc/caddy/.3x-direct-key.XXXXXX)"
	trap 'rm -f "$cert_temp_path" "$key_temp_path"' RETURN
	install -m 644 -o caddy -g caddy "$SOURCE_CERT_FILE" "$cert_temp_path"
	install -m 640 -o caddy -g caddy "$SOURCE_KEY_FILE" "$key_temp_path"
	if ! certificate_key_matches "$cert_temp_path" "$key_temp_path"; then
		printf 'Copied certificate and key do not match\n' >&2
		return 1
	fi
	mv -f "$cert_temp_path" "$TARGET_CERT_FILE"
	mv -f "$key_temp_path" "$TARGET_KEY_FILE"
	trap - RETURN

	systemctl restart x-ui
	systemctl is-active --quiet x-ui
	printf 'Xray certificate synchronized and x-ui restarted\n'
}

parse_args "$@"
load_config
require_public_certificate

if [ "$MODE" = "check" ]; then
	require_target_certificate
	printf 'Xray certificate synchronization check passed\n'
	exit 0
fi

install -d -m 755 /run/lock
exec 9>"$LOCK_PATH"
if ! flock -n 9; then
	printf 'Another certificate synchronization is running\n'
	exit 0
fi
sync_certificate

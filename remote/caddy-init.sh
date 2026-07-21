#!/bin/bash

# 安装并配置Caddy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/caddy-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"
DIRECT_CERT_FILE="/etc/caddy/3x-direct-cert.pem"
DIRECT_KEY_FILE="/etc/caddy/3x-direct-key.pem"
NO_TLS=0
DIRECT_DOMAIN_TLS_CONFIG_PATH="$(mktemp)"
trap 'rm -f "$DIRECT_DOMAIN_TLS_CONFIG_PATH"' EXIT

exec >>"$LOG_PATH" 2>&1

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
source "$SCRIPT_DIR/caddyfile-common.sh"

install_self_signed_direct_cert() {
	# 安装directDomain测试自签证书
	local cert_path
	local key_path

	cert_path="$(mktemp)"
	key_path="$(mktemp)"
	openssl req \
		-x509 \
		-nodes \
		-newkey rsa:2048 \
		-days 30 \
		-keyout "$key_path" \
		-out "$cert_path" \
		-subj "/CN=$DIRECT_DOMAIN" \
		-addext "subjectAltName=DNS:$DIRECT_DOMAIN"
	sudo install -m 644 -o caddy -g caddy "$cert_path" "$DIRECT_CERT_FILE"
	sudo install -m 640 -o caddy -g caddy "$key_path" "$DIRECT_KEY_FILE"
	rm -f "$cert_path" "$key_path"
}

parse_args "$@"

# 读取 config.json 和 constants.json
DIRECT_DOMAIN="$(jq -r '.directDomain' "$CONFIG_PATH")"
AUTO_HTTPS_CONFIG="auto_https disable_redirects"
CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort' "$CONFIG_PATH")"
FAKE_SITE_PORT="$(jq -r '.fakeSitePort' "$CONSTANTS_PATH")"
XHTTP_PORT="$(jq -r '.xhttpPort' "$CONSTANTS_PATH")"
SUBSCRIPTION_PORT="$(jq -r '.subscriptionPort' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort' "$CONSTANTS_PATH")"
SUBSCRIPTION_URI_PATH="$(jq -r '.subscriptionPath' "$CONFIG_PATH")"

printf '跳过公信TLS: %s\n' "$NO_TLS"

# 随机生成XHTTP路径（20位）
XHTTP_PATH="$(openssl rand -hex 10)"

# 将生成结果写入 paths.json
jq -n \
	--arg xhttpPath "$XHTTP_PATH" \
	'{
		xhttpPath: $xhttpPath
	}' >"$PATHS_PATH"

# 安装Caddy
export DEBIAN_FRONTEND=noninteractive
sudo apt-get -o DPkg::Lock::Timeout=600 update
sudo apt-get \
	-o DPkg::Lock::Timeout=600 \
	-o Dpkg::Options::=--force-confdef \
	-o Dpkg::Options::=--force-confold \
	install -y debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --batch --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
sudo chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
sudo chmod o+r /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get -o DPkg::Lock::Timeout=600 update
sudo apt-get \
	-o DPkg::Lock::Timeout=600 \
	-o Dpkg::Options::=--force-confdef \
	-o Dpkg::Options::=--force-confold \
	install -y caddy

# 安装伪装站
sudo install -d -m 755 -o caddy -g caddy /var/www/3x-fake-site
sudo cp -a "$SCRIPT_DIR/fake-site"/. /var/www/3x-fake-site/
sudo chown -R caddy:caddy /var/www/3x-fake-site

# 安装Cloudflare源站证书
sudo install -m 644 -o caddy -g caddy "$SCRIPT_DIR/cert.pem" /etc/caddy/3x-origin-cert.pem
sudo install -m 640 -o caddy -g caddy "$SCRIPT_DIR/key.pem" /etc/caddy/3x-origin-key.pem

# 安装directDomain测试自签证书
install_self_signed_direct_cert
write_file_tls_config "$DIRECT_DOMAIN_TLS_CONFIG_PATH"

# 渲染并安装Caddyfile
render_caddyfile | sed '1s/.*/# Caddyfile正则替换成功产物/' | sudo tee /etc/caddy/Caddyfile >/dev/null
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl enable caddy
sudo systemctl reload caddy || sudo systemctl restart caddy

# 执行 caddy-check.sh
chmod +x "$SCRIPT_DIR/caddy-check.sh"
exec bash "$SCRIPT_DIR/caddy-check.sh" "$@"

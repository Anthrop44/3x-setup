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

exec >>"$LOG_PATH" 2>&1

# 读取 config.json 和 constants.json
DIRECT_DOMAIN="$(jq -r '.directDomain' "$CONFIG_PATH")"
CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort' "$CONFIG_PATH")"
FAKE_SITE_PORT="$(jq -r '.fakeSitePort' "$CONSTANTS_PATH")"
XHTTP_PORT="$(jq -r '.xhttpPort' "$CONSTANTS_PATH")"
SUBSCRIPTION_PORT="$(jq -r '.subscriptionPort' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort' "$CONSTANTS_PATH")"
CONFIG_SUBSCRIPTION_PATH="$(jq -r '.subscriptionPath // ""' "$CONFIG_PATH")"
CONFIG_INITIAL_CLIENT_SUB_ID="$(jq -r '.initialClientSubId // ""' "$CONFIG_PATH")"

# 选择订阅路径、初始客户端订阅ID并随机生成XHTTP路径
if [ -n "$CONFIG_SUBSCRIPTION_PATH" ]; then
	SUBSCRIPTION_URI_PATH="$CONFIG_SUBSCRIPTION_PATH"
else
	SUBSCRIPTION_URI_PATH="$(openssl rand -hex 16)"
fi
if [ -n "$CONFIG_INITIAL_CLIENT_SUB_ID" ]; then
	INITIAL_CLIENT_SUB_ID="$CONFIG_INITIAL_CLIENT_SUB_ID"
else
	INITIAL_CLIENT_SUB_ID="$(openssl rand -hex 16)"
fi
XHTTP_PATH="$(openssl rand -hex 16)"
REVERSE_PROXY_URI="https://$CDN_DOMAIN/$SUBSCRIPTION_URI_PATH/"

# 将生成结果写入 paths.json
jq -n \
	--arg subscriptionUriPath "$SUBSCRIPTION_URI_PATH" \
	--arg initialClientSubId "$INITIAL_CLIENT_SUB_ID" \
	--arg reverseProxyUri "$REVERSE_PROXY_URI" \
	--arg xhttpPath "$XHTTP_PATH" \
	'{
		subscriptionUriPath: $subscriptionUriPath,
		initialClientSubId: $initialClientSubId,
		reverseProxyUri: $reverseProxyUri,
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

# 渲染并安装Caddyfile
sed \
	-e "s|{{DIRECT_DOMAIN}}|$DIRECT_DOMAIN|g" \
	-e "s|{{CDN_DOMAIN}}|$CDN_DOMAIN|g" \
	-e "s|{{CDN_PORT}}|$CDN_PORT|g" \
	-e "s|{{SUBSCRIPTION_URI_PATH}}|$SUBSCRIPTION_URI_PATH|g" \
	-e "s|{{SUBSCRIPTION_PORT}}|$SUBSCRIPTION_PORT|g" \
	-e "s|{{XHTTP_PATH}}|$XHTTP_PATH|g" \
	-e "s|{{XHTTP_PORT}}|$XHTTP_PORT|g" \
	-e "s|{{FAKE_SITE_PORT}}|$FAKE_SITE_PORT|g" \
	-e "s|{{REALITY_TARGET_PORT}}|$REALITY_TARGET_PORT|g" \
	"$SCRIPT_DIR/Caddyfile.template" | sed '1s/.*/# Caddyfile正则替换成功产物/' | sudo tee /etc/caddy/Caddyfile >/dev/null
sudo caddy fmt --overwrite /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl enable caddy
sudo systemctl reload caddy || sudo systemctl restart caddy

# 执行 caddy-check.sh
chmod +x "$SCRIPT_DIR/caddy-check.sh"
exec bash "$SCRIPT_DIR/caddy-check.sh"

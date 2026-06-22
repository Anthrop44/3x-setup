#!/bin/bash

# 检查Caddy服务状态

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
OUTPUT_FILE="$LOG_DIR/caddy-check.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PATHS_PATH="$SCRIPT_DIR/paths.json"

rm -f "$OUTPUT_FILE"
exec >"$OUTPUT_FILE" 2>&1

DIRECT_DOMAIN="$(jq -r '.directDomain // empty' "$CONFIG_PATH")"
CDN_DOMAIN="$(jq -r '.cdnDomain // empty' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort // empty' "$CONFIG_PATH")"
FAKE_SITE_PORT="$(jq -r '.fakeSitePort // empty' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort // empty' "$CONSTANTS_PATH")"
SUBSCRIPTION_URI_PATH="$(jq -r '.subscriptionUriPath // empty' "$PATHS_PATH")"
XHTTP_PATH="$(jq -r '.xhttpPath // empty' "$PATHS_PATH")"

printf '== 基本信息 ==\n'
date -Is
printf '工作目录: %s\n' "$SCRIPT_DIR"
printf 'CDN域名: %s\n' "$CDN_DOMAIN"
printf 'CDN端口: %s\n' "$CDN_PORT"
printf '订阅路径: %s\n' "$SUBSCRIPTION_URI_PATH"
printf 'XHTTP路径: %s\n' "$XHTTP_PATH"

printf '\n== Caddy服务状态 ==\n'
sudo -n systemctl --no-pager --full status caddy 2>&1
sudo -n systemctl is-active --quiet caddy

printf '\n== Caddyfile ==\n'
sudo -n sed -n '1,220p' /etc/caddy/Caddyfile 2>&1

printf '\n== Caddy校验 ==\n'
sudo -n caddy validate --config /etc/caddy/Caddyfile 2>&1

printf '\n== Cloudflare源站证书 ==\n'
sudo -n ls -l /etc/caddy/3x-origin-cert.pem /etc/caddy/3x-origin-key.pem 2>&1
sudo -n openssl x509 -in /etc/caddy/3x-origin-cert.pem -noout -subject -issuer -dates -ext subjectAltName 2>&1

printf '\n== directDomain证书 ==\n'
sudo -n find /var/lib/caddy/.local/share/caddy/certificates -type f -path "*$DIRECT_DOMAIN*" -printf '%p %s bytes\n' 2>&1 | sort || true
sudo -n find /var/lib/caddy/.local/share/caddy/certificates -type f -name "$DIRECT_DOMAIN.crt" -exec openssl x509 -in '{}' -noout -subject -issuer -dates -ext subjectAltName ';' 2>&1 || true

printf '\n== 伪装站文件 ==\n'
sudo -n find /var/www/3x-fake-site -maxdepth 2 -type f -printf '%p %s bytes\n' 2>&1 | sort

printf '\n== 本机HTTP探测 ==\n'
curl -fsS -I --max-time 10 "http://127.0.0.1:$FAKE_SITE_PORT/" 2>&1

printf '\n== directDomain证书入口探测 ==\n'
curl -k -sS -I --max-time 10 --resolve "$DIRECT_DOMAIN:$REALITY_TARGET_PORT:127.0.0.1" "https://$DIRECT_DOMAIN:$REALITY_TARGET_PORT/" 2>&1 || true

printf '\n== Caddy日志 ==\n'
sudo -n journalctl -u caddy --no-pager -n 120 2>&1 || true

printf '\n== 失败单元 ==\n'
sudo -n systemctl --failed --no-pager 2>&1 || true

printf '\n== 完成 ==\n'

# 执行 3x-panel-init.sh
chmod +x "$SCRIPT_DIR/3x-panel-init.sh"
exec bash "$SCRIPT_DIR/3x-panel-init.sh"

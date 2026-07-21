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

rm -f "$LOG_PATH"
exec >"$LOG_PATH" 2>&1
source "$SCRIPT_DIR/script-timing.sh"
trap 'exit_code=$?; rm -f "$DIRECT_DOMAIN_TLS_CONFIG_PATH"; script_timer_finish "$exit_code"' EXIT

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
source "$SCRIPT_DIR/caddyfile-common.sh"

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

install_direct_tls_sync_task() {
	# 安装Caddy续期证书同步任务
	local sync_config_path="/etc/3x-setup/direct-tls-sync.conf"
	local sync_config_temp_path

	sync_config_temp_path="$(mktemp)"
	trap 'rm -f "$sync_config_temp_path"' RETURN
	printf 'DIRECT_DOMAIN=%s\n' "$DIRECT_DOMAIN" >"$sync_config_temp_path"
	sudo -n install -d -m 755 -o root -g root /etc/3x-setup
	sudo -n install -m 644 -o root -g root "$sync_config_temp_path" "$sync_config_path"
	sudo -n install -m 755 -o root -g root "$SCRIPT_DIR/direct-tls-sync.sh" /usr/local/sbin/3x-sync-direct-tls
	sudo -n install -m 644 -o root -g root "$SCRIPT_DIR/script-timing.sh" /usr/local/sbin/script-timing.sh
	trap - RETURN
	rm -f "$sync_config_temp_path"

	sudo tee /etc/systemd/system/3x-direct-tls-sync.service >/dev/null <<'EOF'
[Unit]
Description=Synchronize Caddy managed certificate to 3x-ui Xray
Wants=network-online.target
After=network-online.target caddy.service x-ui.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/3x-sync-direct-tls --sync
EOF

	sed "s|{{DAILY_TASK_TIME}}|$DAILY_TASK_TIME|g" <<'EOF' | sudo tee /etc/systemd/system/3x-direct-tls-sync.timer >/dev/null
[Unit]
Description=Synchronize Caddy managed certificate to 3x-ui Xray daily

[Timer]
OnCalendar=*-*-* {{DAILY_TASK_TIME}}
RandomizedDelaySec=1h
Persistent=true
Unit=3x-direct-tls-sync.service

[Install]
WantedBy=timers.target
EOF

	sudo -n systemctl daemon-reload
	sudo -n systemctl enable --now 3x-direct-tls-sync.timer
	sudo -n systemctl start 3x-direct-tls-sync.service
}

parse_args "$@"

DIRECT_DOMAIN="$(jq -r '.directDomain' "$CONFIG_PATH")"
AUTO_HTTPS_CONFIG="auto_https disable_redirects ignore_loaded_certs"
CDN_DOMAIN="$(jq -r '.cdnDomain' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort' "$CONFIG_PATH")"
FAKE_SITE_PORT="$(jq -r '.fakeSitePort' "$CONSTANTS_PATH")"
XHTTP_PORT="$(jq -r '.xhttpPort' "$CONSTANTS_PATH")"
SUBSCRIPTION_PORT="$(jq -r '.subscriptionPort' "$CONSTANTS_PATH")"
REALITY_TARGET_PORT="$(jq -r '.realityTargetPort' "$CONSTANTS_PATH")"
DAILY_TASK_HOUR="$(jq -r '.dailyTaskHour' "$CONSTANTS_PATH")"
DAILY_TASK_TIME="$(printf '%02d:00:00' "$DAILY_TASK_HOUR")"
SUBSCRIPTION_URI_PATH="$(jq -r '.subscriptionPath' "$CONFIG_PATH")"
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

	printf '\n== 安装证书同步任务 ==\n'
	install_direct_tls_sync_task
fi

printf '\n== 完成 ==\n'

# 执行 direct-tls-check.sh
chmod +x "$SCRIPT_DIR/direct-tls-check.sh"
script_timer_finish 0
exec bash "$SCRIPT_DIR/direct-tls-check.sh" "$@"

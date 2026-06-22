#!/bin/bash

# 以sudo用户身份执行初始化

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/user-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"

exec >>"$LOG_PATH" 2>&1

# 读取 config.json 和 constants.json
SSH_PORT="$(jq -r '.sshPort' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort' "$CONFIG_PATH")"

# 配置SSH高位端口、禁止SSH密码登录、禁止SSH直接使用root登录
sudo install -d /etc/ssh/sshd_config.d
printf 'Port %s\nPubkeyAuthentication yes\nPasswordAuthentication no\nPermitRootLogin no\n' "$SSH_PORT" | sudo tee /etc/ssh/sshd_config.d/99-3x-setup.conf >/dev/null
if ! sudo grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
	printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' | sudo tee -a /etc/ssh/sshd_config >/dev/null
fi

# 重启SSH服务
sudo sshd -t
sudo systemctl restart ssh || sudo systemctl restart sshd

# 收紧防火墙，只开放80、443、{sshPort}
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow "${SSH_PORT}/tcp"

# {cdnPort}只允许CloudflareIP段访问，并通过systemdtimer定时刷新
sed "s|{{CDN_PORT}}|$CDN_PORT|g" <<'EOF' | sudo tee /usr/local/sbin/3x-update-cloudflare-ufw.sh >/dev/null
#!/bin/bash

set -euo pipefail

CDN_PORT="{{CDN_PORT}}"
RULE_COMMENT="3x-cloudflare-cdn"
LOCK_PATH="/run/3x-update-cloudflare-ufw.lock"
CLOUDFLARE_IPS_FILE="$(mktemp)"
CLOUDFLARE_IPS_CLEAN_FILE="$(mktemp)"

trap 'rm -f "$CLOUDFLARE_IPS_FILE" "$CLOUDFLARE_IPS_CLEAN_FILE"' EXIT

exec 9>"$LOCK_PATH"
if ! flock -n 9; then
	printf 'CloudflareIP段更新已在执行\n' >&2
	exit 0
fi

curl -fsSL --retry 3 --connect-timeout 10 https://www.cloudflare.com/ips-v4 >"$CLOUDFLARE_IPS_FILE"
printf '\n' >>"$CLOUDFLARE_IPS_FILE"
curl -fsSL --retry 3 --connect-timeout 10 https://www.cloudflare.com/ips-v6 >>"$CLOUDFLARE_IPS_FILE"
sed '/^[[:space:]]*$/d' "$CLOUDFLARE_IPS_FILE" | sort -u >"$CLOUDFLARE_IPS_CLEAN_FILE"

if [ ! -s "$CLOUDFLARE_IPS_CLEAN_FILE" ]; then
	printf 'CloudflareIP段为空，保留现有UFW规则\n' >&2
	exit 1
fi

if grep -Evq '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9A-Fa-f:]+/[0-9]{1,3}$' "$CLOUDFLARE_IPS_CLEAN_FILE"; then
	printf 'CloudflareIP段格式异常，保留现有UFW规则\n' >&2
	exit 1
fi

CDN_UFW_RULES="$(sudo ufw status numbered | sed -n "/${RULE_COMMENT}/ s/^\[[[:space:]]*\([0-9][0-9]*\)\].*${CDN_PORT}\/tcp.*/\1/p" | sort -rn)"
if [ -n "$CDN_UFW_RULES" ]; then
	printf '%s\n' "$CDN_UFW_RULES" | while IFS= read -r CDN_UFW_RULE; do
		sudo ufw --force delete "$CDN_UFW_RULE" >/dev/null
	done
fi

while IFS= read -r CLOUDFLARE_IP; do
	sudo ufw allow proto tcp from "$CLOUDFLARE_IP" to any port "$CDN_PORT" comment "$RULE_COMMENT" >/dev/null
done <"$CLOUDFLARE_IPS_CLEAN_FILE"

sudo ufw --force enable
EOF
sudo chmod 755 /usr/local/sbin/3x-update-cloudflare-ufw.sh

sudo tee /etc/systemd/system/3x-cloudflare-ufw.service >/dev/null <<'EOF'
[Unit]
Description=Update Cloudflare UFW rules for 3x CDN port
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/3x-update-cloudflare-ufw.sh
EOF

sudo tee /etc/systemd/system/3x-cloudflare-ufw.timer >/dev/null <<'EOF'
[Unit]
Description=Update Cloudflare UFW rules for 3x CDN port daily

[Timer]
OnBootSec=5min
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
Unit=3x-cloudflare-ufw.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl start 3x-cloudflare-ufw.service
sudo systemctl enable --now 3x-cloudflare-ufw.timer

# 开启BBR拥塞控制
sudo modprobe tcp_bbr 2>/dev/null || true
if ! sysctl net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
	printf '当前内核不支持BBR\n' >&2
	exit 1
fi
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' | sudo tee /etc/sysctl.d/99-3x-bbr.conf >/dev/null
sudo sysctl -w net.core.default_qdisc=fq >/dev/null
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

# 执行 service-check.sh
chmod +x "$SCRIPT_DIR/service-check.sh"
exec bash "$SCRIPT_DIR/service-check.sh"

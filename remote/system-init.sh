#!/bin/bash

# 以root身份执行系统初始化

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
	printf 'This script must be run as root\n' >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/system-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"

exec >>"$LOG_PATH" 2>&1
source "$SCRIPT_DIR/script-timing.sh"

# 读取 config.json 和 constants.json
SSH_PORT="$(jq -r '.sshPort' "$CONFIG_PATH")"
CDN_PORT="$(jq -r '.cdnPort' "$CONFIG_PATH")"
DAILY_TASK_HOUR="$(jq -r '.dailyTaskHour' "$CONSTANTS_PATH")"
printf -v DAILY_TASK_TIME '%02d:00:00' "$DAILY_TASK_HOUR"

# 确认root公钥已就位，再禁用密码认证
test -s /root/.ssh/authorized_keys
ssh-keygen -l -f /root/.ssh/authorized_keys >/dev/null

# 优先加载部署配置，避免云镜像的密码认证配置抢先生效
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-3x-setup.conf <<EOF
Port $SSH_PORT
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
AuthorizedKeysFile .ssh/authorized_keys
EOF
chmod 644 /etc/ssh/sshd_config.d/00-3x-setup.conf
sed -i '\|^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config.d/00-3x-setup.conf[[:space:]]*$|d' /etc/ssh/sshd_config
sed -i '1i Include /etc/ssh/sshd_config.d/00-3x-setup.conf' /etc/ssh/sshd_config

source "$SCRIPT_DIR/check-common.sh"
sshd -t
assert_root_ssh_publickey_only
if [ -n "${SSH_CONNECTION:-}" ]; then
	read -r CLIENT_ADDR _ SERVER_ADDR _ <<<"$SSH_CONNECTION"
	assert_root_ssh_publickey_only /etc/ssh/sshd_config "user=root,host=$CLIENT_ADDR,addr=$CLIENT_ADDR,laddr=$SERVER_ADDR,lport=$SSH_PORT"
fi

# 重启SSH服务
systemctl restart ssh || systemctl restart sshd

# 收紧防火墙，只开放80、443/tcp、443/udp、{sshPort}
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow "${SSH_PORT}/tcp"

# {cdnPort}只允许CloudflareIP段访问，并通过systemdtimer定时刷新
sed "s|{{CDN_PORT}}|$CDN_PORT|g" <<'EOF' | tee /usr/local/sbin/3x-update-cloudflare-ufw.sh >/dev/null
#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CDN_PORT="{{CDN_PORT}}"
RULE_COMMENT="3x-cloudflare-cdn"
LOCK_PATH="/run/3x-update-cloudflare-ufw.lock"
CLOUDFLARE_IPS_FILE="$(mktemp)"
CLOUDFLARE_IPS_CLEAN_FILE="$(mktemp)"
source "$SCRIPT_DIR/script-timing.sh"

trap 'exit_code=$?; rm -f "$CLOUDFLARE_IPS_FILE" "$CLOUDFLARE_IPS_CLEAN_FILE"; script_timer_finish "$exit_code"' EXIT

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

CDN_UFW_RULES="$(ufw status numbered | sed -n "/${RULE_COMMENT}/ s/^\[[[:space:]]*\([0-9][0-9]*\)\].*${CDN_PORT}\/tcp.*/\1/p" | sort -rn)"
if [ -n "$CDN_UFW_RULES" ]; then
	printf '%s\n' "$CDN_UFW_RULES" | while IFS= read -r CDN_UFW_RULE; do
		ufw --force delete "$CDN_UFW_RULE" >/dev/null
	done
fi

while IFS= read -r CLOUDFLARE_IP; do
	ufw allow proto tcp from "$CLOUDFLARE_IP" to any port "$CDN_PORT" comment "$RULE_COMMENT" >/dev/null
done <"$CLOUDFLARE_IPS_CLEAN_FILE"

ufw --force enable
EOF

chmod 755 /usr/local/sbin/3x-update-cloudflare-ufw.sh
install -m 644 -o root -g root "$SCRIPT_DIR/script-timing.sh" /usr/local/sbin/script-timing.sh

tee /etc/systemd/system/3x-cloudflare-ufw.service >/dev/null <<'EOF'
[Unit]
Description=Update Cloudflare UFW rules for 3x CDN port
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/3x-update-cloudflare-ufw.sh
EOF

sed "s|{{DAILY_TASK_TIME}}|$DAILY_TASK_TIME|g" <<'EOF' | tee /etc/systemd/system/3x-cloudflare-ufw.timer >/dev/null
[Unit]
Description=Update Cloudflare UFW rules for 3x CDN port daily

[Timer]
OnCalendar=*-*-* {{DAILY_TASK_TIME}}
RandomizedDelaySec=1h
Persistent=true
Unit=3x-cloudflare-ufw.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl start 3x-cloudflare-ufw.service
systemctl enable --now 3x-cloudflare-ufw.timer

# 开启BBR拥塞控制
modprobe tcp_bbr 2>/dev/null || true
if ! sysctl net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
	printf '当前内核不支持BBR\n' >&2
	exit 1
fi
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' | tee /etc/sysctl.d/99-3x-bbr.conf >/dev/null
sysctl -w net.core.default_qdisc=fq >/dev/null
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null

# 执行 service-check.sh
chmod +x "$SCRIPT_DIR/service-check.sh"
script_timer_finish 0
exec bash "$SCRIPT_DIR/service-check.sh" "$@"

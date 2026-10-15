#!/bin/bash

# 以root身份执行初始化

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
	printf 'This script must be run as root\n' >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/root-init.log"
PUBLIC_KEY_PATH="$SCRIPT_DIR/id_ed25519.pub"
exec >>"$LOG_PATH" 2>&1
source "$SCRIPT_DIR/script-timing.sh"

normalize_workdir_permissions() {
	# 归一化工作目录权限，避免归档目录只读导致后续脚本无法写入
	local workdir="$1"

	find "$workdir" -type d -exec chmod 755 {} +
	find "$workdir" -type f -exec chmod 644 {} +
	find "$workdir" -maxdepth 1 -type f -name "*.sh" -exec chmod 755 {} +
	chmod 600 "$workdir/key.pem"
	chmod 644 "$workdir/cert.pem" "$workdir/id_ed25519.pub"
}

# 安装依赖
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get dist-upgrade -y
apt-get install -y jq openssl openssh-server curl ca-certificates ufw procps sqlite3

# 直接使用上传到/root/3x-setup的工作目录
chown -R root:root "$SCRIPT_DIR"
normalize_workdir_permissions "$SCRIPT_DIR"

# 在关闭密码认证前，校验并安装root的部署公钥
ssh-keygen -l -f "$PUBLIC_KEY_PATH" >/dev/null
install -d -m 700 -o root -g root /root/.ssh
install -m 600 -o root -g root "$PUBLIC_KEY_PATH" /root/.ssh/authorized_keys

# 以root继续系统初始化
cd "$SCRIPT_DIR"
script_timer_finish 0
exec bash "$SCRIPT_DIR/system-init.sh" "$@"

#!/bin/bash

# 以root身份执行初始化

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/log"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/root-init.log"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
PUBLIC_KEY_PATH="$SCRIPT_DIR/id_ed25519.pub"
exec >>"$LOG_PATH" 2>&1

normalize_workdir_permissions() {
	# 归一化工作目录权限，避免Windows归档目录只读导致用户脚本无法写入
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
apt-get upgrade -y
apt-get install -y jq openssl openssh-server sudo curl ca-certificates ufw procps sqlite3

# 读取 config.json 和 constants.json
USERNAME="$(jq -r '.username' "$CONSTANTS_PATH")"
PASSWORD="$(jq -r '.password' "$CONSTANTS_PATH")"
USER_HOME="/home/$USERNAME"
USER_WORKDIR="$USER_HOME/3x-setup"

# 创建sudo用户
if ! id "$USERNAME" >/dev/null 2>&1; then
	useradd -m -s /bin/bash "$USERNAME"
fi
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
usermod -aG sudo "$USERNAME"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USERNAME" >"/etc/sudoers.d/$USERNAME"
chmod 440 "/etc/sudoers.d/$USERNAME"

# 为sudo用户创建用户目录下的工作目录
install -d -o "$USERNAME" -g "$USERNAME" "$USER_WORKDIR"

# 将当前上传目录复制到用户目录下的工作目录
cp -a "$SCRIPT_DIR"/. "$USER_WORKDIR"/

# 将用户目录下工作目录的所有权交给sudo用户
chown -R "$USERNAME:$USERNAME" "$USER_WORKDIR"
normalize_workdir_permissions "$USER_WORKDIR"

# 为sudo用户写入SSH公钥
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$USER_HOME/.ssh"
install -m 600 -o "$USERNAME" -g "$USERNAME" "$PUBLIC_KEY_PATH" "$USER_HOME/.ssh/authorized_keys"

# 验证sudo用户可以免交互使用sudo
sudo -n -u "$USERNAME" sudo -n true

# 切换到sudo用户身份并进入用户目录下的工作目录
mkdir -p "$USER_WORKDIR/log"
cp "$LOG_PATH" "$USER_WORKDIR/log/root-init.log"
chown "$USERNAME:$USERNAME" "$USER_WORKDIR/log/root-init.log"

# 执行 user-init.sh
exec sudo -Hu "$USERNAME" bash -c 'cd "$1" && bash ./user-init.sh' bash "$USER_WORKDIR"

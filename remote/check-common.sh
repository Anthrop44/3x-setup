#!/bin/bash

# 检查阶段公共函数

ensure_no_failed_units() {
	# 确认systemd没有失败单元
	local failed_units

	failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null || true)"
	if [ -n "$failed_units" ]; then
		printf '%s\n' "$failed_units" >&2
		exit 1
	fi
}

assert_root_ssh_publickey_only() {
	# 检查root连接实际生效的认证策略，失败时不重启SSH
	local config_path="${1:-/etc/ssh/sshd_config}"
	local connection="${2:-user=root,host=localhost,addr=127.0.0.1}"
	local ssh_config
	local expected
	local root_login

	ssh_config="$(sshd -T -f "$config_path" -C "$connection")" || return 1
	for expected in "port $SSH_PORT" 'pubkeyauthentication yes' 'authenticationmethods publickey' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitemptypasswords no' 'authorizedkeysfile .ssh/authorized_keys'; do
		if ! grep -Fqx "$expected" <<<"$ssh_config"; then
			printf 'Unexpected effective root SSH configuration: expected %s\n' "$expected" >&2
			return 1
		fi
	done
	root_login="$(sed -n 's/^permitrootlogin //p' <<<"$ssh_config")"
	if [ "$root_login" != prohibit-password ] && [ "$root_login" != without-password ]; then
		printf 'Unexpected effective root SSH configuration: permitrootlogin %s\n' "$root_login" >&2
		return 1
	fi
}

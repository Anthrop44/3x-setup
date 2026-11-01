#!/usr/bin/env nu
const FILE = path self
use ../lib/core.nu [root-required ensure]
use ../features/apps.nu

# 校验更新或重置模式，在文件锁保护下执行代理客户端任务
def main [--update, --reset: string, --locked] {
	root-required
	let config_path = ($env.FETCH_APPS_CONFIG_PATH? | default '/etc/3x-fetch-apps.json')
	let state_dir = ($env.FETCH_APPS_STATE_DIR? | default '/var/lib/3x-fetch-apps')
	let lock_path = ($env.FETCH_APPS_LOCK_PATH? | default '/run/3x-fetch-apps.lock')
	ensure ($update or $reset != null) 'Use --update or --reset RESOURCE_ID'
	ensure (not ($update and $reset != null)) 'Choose either --update or --reset'
	if not $locked {
		let options = (if $reset != null { [--reset $reset] } else { [--update] })
		let lock_options = (if $reset != null { [] } else { [--nonblock --conflict-exit-code 75] })
		let result = (^flock ...$lock_options $lock_path nu --no-config-file $FILE --locked ...$options | complete)
		if $result.exit_code == 75 { return }
		print $result.stdout
		ensure ($result.exit_code == 0) $result.stderr
		return
	}
	apps execute $config_path $state_dir $reset
}

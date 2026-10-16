use ../remote/lib/core.nu [ensure checked]

# 将字符串转义为远端Shell可安全解析的单引号参数
export def shell-quote [value: string] {
	"'" + ($value | str replace --all "'" "'\"'\"'") + "'"
}

# 构造不加载用户配置且正确引用代码的远端Nu命令
export def remote-nu [code: string] {
	$"nu --no-config-file -c (shell-quote $code)"
}

# 使用直连域名构造root的SSH目标地址
export def ssh-target [config: record] {
	$"root@($config.directDomain)"
}

# 使用直连域名构造root的SCP目标路径
export def scp-target [config: record, path: string] { $"root@($config.directDomain):($path)" }

# 返回部署私钥和配置端口对应的SSH参数
export def ssh-options [project: string, config: record] {
	[-i ($project | path join id_ed25519) -p ($config.sshPort | into string)]
}

# 每次入口执行最多尝试恢复一次未知主机连接，绝不接受已知主机的密钥变更
export def --env ssh-run [project: string, config: record, command: string] {
	mut result = (^ssh ...(ssh-options $project $config) (ssh-target $config) $command | complete)
	if $result.exit_code == 255 and not ($env.THREEX_HOST_RECOVERY? | default false) {
		$env.THREEX_HOST_RECOVERY = true
		print 'SSH failed; fetching logs once before retrying'
		let recovery = (^nu --no-config-file ($project | path join get-log.nu) | complete)
		if $recovery.exit_code == 0 {
			$result = (^ssh ...(ssh-options $project $config) (ssh-target $config) $command | complete)
		} else { print --stderr $recovery.stderr }
	}
	print $result.stdout
	if ($result.stderr | is-not-empty) { print --stderr $result.stderr }
	ensure ($result.exit_code == 0) $"SSH failed with exit code ($result.exit_code)"
}

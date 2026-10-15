use ../remote/common.nu [ensure checked]

export def shell-quote [value: string] {
	"'" + ($value | str replace --all "'" "'\"'\"'") + "'"
}

export def remote-nu [code: string] {
	$"nu --no-config-file -c (shell-quote $code)"
}

export def ssh-target [config: record] {
	$"root@($config.ip | str trim --char '[' | str trim --char ']')"
}

export def scp-target [config: record, path: string] { $"root@($config.ip):($path)" }

export def ssh-options [project: string, config: record] {
	[-i ($project | path join id_ed25519) -p ($config.sshPort | into string)]
}

# Recover an unknown host once per entrypoint, never accept a changed known key
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

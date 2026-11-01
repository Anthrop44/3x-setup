#!/usr/bin/env nu
const FILE = path self
use ../lib/core.nu [root-required ensure]
use ../lib/config.nu project-paths
use ../features/system.nu refresh-firewall

# 以root权限和文件锁刷新Cloudflare回源防火墙规则
def main [--locked] {
	root-required
	if not $locked {
		let result = (^flock --nonblock --conflict-exit-code 75 /run/3x-cloudflare-ufw.lock nu --no-config-file $FILE --locked | complete)
		if $result.exit_code == 75 { return }
		print $result.stdout
		ensure ($result.exit_code == 0) $result.stderr
		return
	}
	let paths = (project-paths ($FILE | path dirname | path dirname))
	refresh-firewall (open $paths.config)
}

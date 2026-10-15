#!/usr/bin/env nu
const FILE = path self
use modules/ssh.nu [remote-nu ssh-run]

def main [] {
	let project = ($FILE | path dirname)
	let config = (open ($project | path join remote config.json))
	ssh-run $project $config (remote-nu '^nu --no-config-file /root/3x-setup/update-all.nu; exit $env.LAST_EXIT_CODE')
}

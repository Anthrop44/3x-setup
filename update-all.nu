#!/usr/bin/env nu
const FILE = path self
use modules/ssh.nu [remote-nu ssh-run]

# 通过SSH更新远端系统、3X-UI和已安装的代理客户端
def main [] {
	let project = ($FILE | path dirname)
	let config = (open ($project | path join remote config.json))
	ssh-run $project $config (remote-nu '^nu --no-config-file /root/3x-setup/main.nu update; exit $env.LAST_EXIT_CODE')
}

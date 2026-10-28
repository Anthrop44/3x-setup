#!/usr/bin/env nu
const FILE = path self
use remote/lib/core.nu [checked ensure]
use modules/ssh.nu [remote-nu ssh-options ssh-target scp-target]

# 依次探测配置端口与初始端口，返回第一个能建立公钥连接的端口
# 部署在system-init之前失败时sshd仍在初始端口，必须回退才能取到日志
def reachable-port [project: string, config: record, initial: int] {
	let ports = ([$config.sshPort $initial] | uniq)
	let reachable = ($ports | where {|port|
		(^ssh ...(ssh-options $project $config $port) -o BatchMode=yes -o StrictHostKeyChecking=accept-new (ssh-target $config) 'true' | complete).exit_code == 0
	})
	ensure ($reachable | is-not-empty) $"Cannot reach ($config.directDomain) on SSH port ($ports | each { into string } | str join ' or ')"
	$reachable.0
}

# 下载远端阶段日志，并轮转本地已有的非空日志目录
def main [] {
	let project = ($FILE | path dirname)
	let config = (open ($project | path join remote config.json))
	let constants = (open ($project | path join remote constants.json))
	let key = ($project | path join id_ed25519)
	let port = (reachable-port $project $config $constants.initialSshPort)
	let name = $"3x-setup-log-(random uuid).tar"
	let remote_archive = $"/tmp/($name)"
	let local_archive = ($project | path join $name)
	let log = ($project | path join log)
	try {
		let code = $"^tar -C /root/3x-setup/log -cf ($remote_archive) .; exit $env.LAST_EXIT_CODE"
		checked -- ssh ...(ssh-options $project $config $port) -o StrictHostKeyChecking=accept-new (ssh-target $config) (remote-nu $code)
		checked -- scp -i $key -o StrictHostKeyChecking=accept-new -P $port (scp-target $config $remote_archive) $local_archive
		checked -- ssh ...(ssh-options $project $config $port) -o StrictHostKeyChecking=accept-new (ssh-target $config) (remote-nu $"rm --force ($remote_archive)")
		if ($log | path exists) and (ls --all $log | is-not-empty) {
			mut index = 0
			while ($project | path join $"log($index)" | path exists) { $index += 1 }
			mv $log ($project | path join $"log($index)")
		}
		mkdir $log
		checked -- tar -xf $local_archive -C $log
		rm --force $local_archive
		print $"Downloaded logs to ($log)"
	} catch {|err|
		rm --force $local_archive
		error make {msg: $err.msg}
	}
}

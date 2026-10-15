#!/usr/bin/env nu
const FILE = path self
use remote/common.nu [checked ensure]
use modules/ssh.nu [remote-nu ssh-options ssh-target scp-target]

def main [] {
	let project = ($FILE | path dirname)
	let config = (open ($project | path join remote config.json))
	let name = $"3x-setup-log-(random uuid).tar"
	let remote_archive = $"/tmp/($name)"
	let local_archive = ($project | path join $name)
	let log = ($project | path join log)
	try {
		let code = $"^tar -C /root/3x-setup/log -cf ($remote_archive) .; exit $env.LAST_EXIT_CODE"
		checked -- ssh ...(ssh-options $project $config) -o StrictHostKeyChecking=accept-new (ssh-target $config) (remote-nu $code)
		checked -- scp -i ($project | path join id_ed25519) -o StrictHostKeyChecking=accept-new -P $config.sshPort (scp-target $config $remote_archive) $local_archive
		checked -- ssh ...(ssh-options $project $config) -o StrictHostKeyChecking=accept-new (ssh-target $config) (remote-nu $"rm --force ($remote_archive)")
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

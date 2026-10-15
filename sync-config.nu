#!/usr/bin/env nu
const FILE = path self
use remote/common.nu [checked ensure]
use modules/setup-config.nu prepare-config
use modules/client-files.nu export-client-files
use modules/ssh.nu [remote-nu ssh-run scp-target]

def main [] {
	let project = ($FILE | path dirname)
	let setup = (prepare-config $project)
	let config = $setup.config
	export-client-files $project $config $setup.constants
	let upload = ($project | path join $"sync-(random uuid).tar")
	let staging = $"/root/3x-sync-(random uuid)"
	try {
		checked -- tar -cf $upload -C ($project | path join remote) config.json $"fake-site/($config.distributionPath)"
		ssh-run $project $config (remote-nu $"mkdir ($staging)")
		checked -- scp -i ($project | path join id_ed25519) -P $config.sshPort $upload (scp-target $config $"($staging)/upload.tar")
		ssh-run $project $config (remote-nu $"^systemd-run --quiet --wait --collect --unit=3x-sync-(random uuid) /usr/bin/nu --no-config-file /root/3x-setup/sync-config.nu ($staging); exit $env.LAST_EXIT_CODE")
		rm --force $upload
	} catch {|err|
		rm --force $upload
		error make {msg: $err.msg}
	}
	checked -- nu --no-config-file ($project | path join get-log.nu)
}

#!/usr/bin/env nu
const FILE = path self
use remote/lib/core.nu [ensure checked]
use modules/setup-config.nu prepare-config
use modules/generate-ssh-key.nu initialize-key
use modules/client-files.nu export-client-files
use modules/ssh.nu [shell-quote ssh-target scp-target]

# 部署到刚重建的Debian/Ubuntu服务器
def main [--noTLS, --noAPP, --accept-new-host, --prepare-only] {
	let project = ($FILE | path dirname)
	let remote = ($project | path join remote)
	let config_path = ($remote | path join config.json)
	if not ($config_path | path exists) {
		'{"$schema":"config.schema.json"}' | save $config_path
		print 'Created remote/config.json; fill it in and run nu init.nu again'
		return
	}
	for command in [ssh scp ssh-keygen tar openssl] { ensure (which $command | is-not-empty) $"Missing required command: ($command)" }
	initialize-key $project
	for file in [
		{name: cert.pem, prefix: '-----BEGIN CERTIFICATE-----', suffix: '-----END CERTIFICATE-----'}
		{name: key.pem, prefix: '-----BEGIN PRIVATE KEY-----', suffix: '-----END PRIVATE KEY-----'}
		{name: fake-site/index.html, prefix: '<!doctype html>', suffix: ''}
	] {
		let content = (open --raw ($remote | path join $file.name))
		ensure ($content starts-with $file.prefix) $"Invalid prefix: ($file.name)"
		ensure (($content | str trim) ends-with $file.suffix) $"Invalid suffix: ($file.name)"
	}
	let setup = (prepare-config $project --initial)
	let config = $setup.config
	export-client-files $project $config $setup.constants
	for file in (glob ($remote | path join '**/*') | where {|p| ($p | path type) == file and ($p | path parse | get extension) in [nu sh html css json pem pub template txt] }) {
		open --raw $file | str replace --all "\r\n" "\n" | str replace --all "\r" "\n" | save --force $file
	}
	if $prepare_only { print 'Local preparation complete'; return }
	let tar_path = ($project | path join 3x-setup.tar)
	let key = ($project | path join id_ed25519)
	let initial_port = $setup.constants.initialSshPort
	let options = (if $accept_new_host { [-o StrictHostKeyChecking=accept-new] } else { [] })
	let known_hosts = ($nu.home-dir | path join .ssh known_hosts)
	if ($known_hosts | path exists) {
		let host = ($config.ip | str trim --char '[' | str trim --char ']')
		for port in ([$initial_port $config.sshPort] | uniq) {
			let entry = (if $port == 22 { $host } else { $"[($host)]:($port)" })
			checked -- ssh-keygen -R $entry -f $known_hosts
		}
	}
	let flags = ([ (if $noTLS { '--noTLS' } else { '' }) (if $noAPP { '--noAPP' } else { '' }) ] | where {|s| $s != '' } | str join ' ')
	try {
		checked -- tar -cf $tar_path -C $remote .
		checked -- scp -i $key ...$options -P $initial_port $tar_path (scp-target $config /root/3x-setup.tar)
		let started = (date now)
		let command = $"mkdir -p /root/3x-setup && tar -xf /root/3x-setup.tar -C /root/3x-setup && setsid --wait bash /root/3x-setup/bootstrap.sh ($flags) </dev/null >/dev/null 2>&1"
		checked -- ssh -i $key ...$options -p $initial_port (ssh-target $config) $command
		print $"Remote initialization completed in ((date now) - $started)"
		rm --force $tar_path
	} catch {|err|
		rm --force $tar_path
		try { checked -- nu --no-config-file ($project | path join get-log.nu) } catch { print --stderr 'Log download failed; check bootstrap.log over the initial SSH port' }
		error make {msg: $err.msg}
	}
	checked -- nu --no-config-file ($project | path join get-log.nu)
}

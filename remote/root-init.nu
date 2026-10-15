#!/usr/bin/env nu
const FILE = path self
use common.nu *
use schema.nu validate-config
use system-init.nu
use service-check.nu
use caddy-init.nu
use caddy-check.nu
use 3x-panel-init.nu
use 3x-panel-check.nu
use 3x-inbound-init.nu
use 3x-inbound-check.nu
use cf-host-init.nu
use cf-host-check.nu
use 3x-client-init.nu
use 3x-client-check.nu
use fetch-apps-init.nu
use fetch-apps-check.nu
use direct-tls-init.nu
use direct-tls-check.nu

export def deployment-stages [--noAPP] {
	[root-init system-init service-check caddy-init caddy-check 3x-panel-init 3x-panel-check 3x-inbound-init 3x-inbound-check cf-host-init cf-host-check 3x-client-init 3x-client-check fetch-apps-init fetch-apps-check direct-tls-init direct-tls-check] | where {|s| not $noAPP or ($s not-in [fetch-apps-init fetch-apps-check]) }
}

def install-command [name: string, script: string] {
	$'#!/usr/bin/nu --no-config-file
def --wrapped main [...args: string] {
	exec /usr/bin/nu --no-config-file /root/3x-setup/($script) ...$args
}
' | save --force $"/usr/local/sbin/($name)"
	checked -- chmod 755 $"/usr/local/sbin/($name)"
}

def initialize [ctx: record] {
	checked -- apt-get update
	checked -- apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y
	checked -- apt-get install -y openssl openssh-server curl ca-certificates ufw procps sqlite3 iproute2 util-linux
	checked -- chown -R root:root $ctx.dir
	checked -- chmod 700 $ctx.dir
	for file in (glob ($ctx.dir | path join '*') | where {|p| ($p | path type) == file }) { checked -- chmod 600 $file }
	checked -- ssh-keygen -l -f ($ctx.dir | path join id_ed25519.pub)
	checked -- install -d -m 700 -o root -g root /root/.ssh
	checked -- install -m 600 -o root -g root ($ctx.dir | path join id_ed25519.pub) /root/.ssh/authorized_keys
	install-command 3x-fetch-apps fetch-apps.nu
	install-command 3x-sync-direct-tls direct-tls-sync.nu
}

def execute-stage [stage: string, ctx: record] {
	match $stage {
		root-init => { initialize $ctx }
		system-init => { system-init apply $ctx }
		service-check => { service-check verify $ctx }
		caddy-init => { caddy-init apply $ctx }
		caddy-check => { caddy-check verify $ctx }
		3x-panel-init => { 3x-panel-init apply $ctx }
		3x-panel-check => { 3x-panel-check verify $ctx }
		3x-inbound-init => { 3x-inbound-init apply $ctx }
		3x-inbound-check => { 3x-inbound-check verify $ctx }
		cf-host-init => { cf-host-init apply $ctx }
		cf-host-check => { cf-host-check verify $ctx }
		3x-client-init => { 3x-client-init apply $ctx }
		3x-client-check => { 3x-client-check verify $ctx }
		fetch-apps-init => { fetch-apps-init apply $ctx }
		fetch-apps-check => { fetch-apps-check verify $ctx }
		direct-tls-init => { direct-tls-init apply $ctx }
		direct-tls-check => { direct-tls-check verify $ctx }
		_ => { error make {msg: $"Unknown stage: ($stage)"} }
	}
}

def main [--noTLS, --noAPP, --from: string = root-init, --stage: string] {
	root-required
	$env.DEBIAN_FRONTEND = 'noninteractive'
	# systemd/sshd may supply a PATH without sbin
	$env.PATH = ($env.PATH | prepend [/usr/local/sbin /usr/sbin /sbin])
	let directory = ($FILE | path dirname)
	let ctx = (context $directory $noTLS $noAPP)
	validate-config $ctx.config $ctx.constants --complete
	let stages = (deployment-stages --noAPP=$noAPP)
	if $stage != null {
		let started = (date now)
		print $"Starting ($stage) at ($started)"
		try {
			execute-stage $stage $ctx
			print $"Completed ($stage); execution time: ((date now) - $started)"
		} catch {|err|
			print --stderr $"FAILED ($stage); execution time: ((date now) - $started)"
			error make {msg: $err.msg}
		}
		return
	}
	ensure ($from in $stages) $"Invalid starting stage: ($from)"
	mkdir ($directory | path join log)
	let flags = ([ (if $noTLS { '--noTLS' } else { '' }) (if $noAPP { '--noAPP' } else { '' }) ] | where {|s| $s != '' })
	let selected = ($stages | skip until {|s| $s == $from })
	for item in $selected {
		let log = ($directory | path join log $"($item).log")
		try {
			^nu --no-config-file $FILE --stage $item ...$flags out+err> $log
		} catch { error make {msg: $"Stage ($item) failed; see ($log)"} }
	}
}

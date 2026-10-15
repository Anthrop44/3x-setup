#!/usr/bin/env nu
const FILE = path self
use common.nu *
use schema.nu validate-config

def main [staging: string] {
	root-required
	ensure ($staging =~ '^/root/3x-sync-[a-f0-9-]+$') 'Invalid staging directory'
	let directory = ($FILE | path dirname)
	checked -- tar -xf ($staging | path join upload.tar) -C $staging
	let config = (open ($staging | path join config.json))
	let constants = (open ($directory | path join constants.json))
	validate-config $config $constants --complete
	let current = (open ($directory | path join config.json))
	ensure (($current | reject --optional clients cdnOptDomains) == ($config | reject --optional clients cdnOptDomains)) 'Only clients and cdnOptDomains may be changed on an existing deployment'
	let source_dir = ($staging | path join fake-site $config.distributionPath)
	ensure ($source_dir | path join template.css | path exists) 'Distribution stylesheet missing'
	cp --force ($staging | path join config.json) ($directory | path join config.json)
	# The systemd transient service survives an SSH disconnect
	checked -- nu --no-config-file ($directory | path join root-init.nu) --from cf-host-init --noTLS --noAPP
	let target = $"/var/www/3x-fake-site/($config.distributionPath)"
	let temporary = $"($target).new-(random uuid)"
	let backup = $"($target).old-(random uuid)"
	try {
		checked -- cp -a $source_dir $temporary
		checked -- find $temporary -type d -exec chmod 755 '{}' '+'
		checked -- find $temporary -type f -exec chmod 644 '{}' '+'
		checked -- chown -R caddy:caddy $temporary
		if ($target | path exists) { mv $target $backup }
		try { mv $temporary $target } catch {|err|
			if ($backup | path exists) { mv $backup $target }
			error make {msg: $err.msg}
		}
		rm --recursive --force $backup $staging
	} catch {|err|
		rm --recursive --force $temporary
		error make {msg: $err.msg}
	}
}

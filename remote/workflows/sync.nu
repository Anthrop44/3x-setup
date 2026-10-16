use ../lib/core.nu [ensure checked]
use ../lib/config.nu [project-paths context validate-config]
use ../lib/runner.nu run-workflow
use stages.nu plan

# This allowlist deliberately does not depend on the tail of the deployment plan.
export def steps [] {
	plan [cf-host-init cf-host-check 3x-client-init 3x-client-check connectivity-check direct-tls-check]
}

export def validate-changes [current: record, proposed: record] {
	ensure (($current | reject --optional clients cdnOptDomains) == ($proposed | reject --optional clients cdnOptDomains)) 'Only clients and cdnOptDomains may be changed on an existing deployment'
}

export def execute [directory: string, staging: string] {
	ensure ($staging =~ '^/root/3x-sync-[a-f0-9-]+$') 'Invalid staging directory'
	let paths = (project-paths $directory)
	checked -- tar -xf ($staging | path join upload.tar) -C $staging
	let config = (open ($staging | path join config.json))
	let constants = (open $paths.constants)
	validate-config $config $constants --complete
	validate-changes (open $paths.config) $config
	let source_dir = ($staging | path join fake-site $config.distributionPath)
	ensure ($source_dir | path join template.css | path exists) 'Distribution stylesheet missing'
	cp --force ($staging | path join config.json) $paths.config
	# The local entry point starts this workflow in a transient systemd service.
	run-workflow (context $directory true true) (steps)
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

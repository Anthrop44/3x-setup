use ../lib/core.nu [ensure checked]
use ../lib/config.nu [project-paths context validate-config]
use ../lib/runner.nu run-workflow
use stages.nu plan

# 返回配置同步所需的Host、客户、连通性和TLS阶段
# 此阶段白名单独立维护，不依赖部署计划的末尾阶段
export def steps [] {
	plan [cf-host-init cf-host-check 3x-client-init 3x-client-check connectivity-check direct-tls-check]
}

# 确保已有部署仅修改客户、CDN优选域名和ECH订阅设置
export def validate-changes [current: record, proposed: record, current_constants: record, proposed_constants: record] {
	ensure (($current | reject --optional clients) == ($proposed | reject --optional clients)) 'Only clients may be changed in config.json on an existing deployment'
	ensure (($current_constants | reject --optional cdnOptDomains cdnEchConfigList) == ($proposed_constants | reject --optional cdnOptDomains cdnEchConfigList)) 'Only cdnOptDomains and cdnEchConfigList may be changed in constants.json on an existing deployment'
}

# 校验上传配置并执行同步检查，成功后替换线上分发目录
export def execute [directory: string, staging: string] {
	ensure ($staging =~ '^/root/3x-sync-[a-f0-9-]+$') 'Invalid staging directory'
	let paths = (project-paths $directory)
	checked -- tar -xf ($staging | path join upload.tar) -C $staging
	let config = (open ($staging | path join config.json))
	let constants = (open ($staging | path join constants.json))
	validate-config $config $constants --complete
	validate-changes (open $paths.config) $config (open $paths.constants) $constants
	let source_dir = ($staging | path join fake-site $config.distributionPath)
	ensure ($source_dir | path join template.css | path exists) 'Distribution stylesheet missing'
	cp --force ($staging | path join config.json) $paths.config
	cp --force ($staging | path join constants.json) $paths.constants
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

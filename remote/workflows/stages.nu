use ../lib/core.nu ensure
use ../features/system.nu
use ../features/caddy
use ../features/caddy/tls.nu
use ../features/panel
use ../features/panel/inbounds.nu
use ../features/panel/hosts.nu
use ../features/panel/clients.nu
use ../features/apps.nu
use ../checks/connectivity.nu

# 集中定义每个阶段，供工作流计划和诊断命令共用
# 阶段名用于标识日志和显式诊断命令
export def catalog [] {
	[
		{name: root-init, source: features/system.nu, description: 'Install dependencies and root SSH key', run: {|ctx| system provision $ctx }}
		{name: system-init, source: features/system.nu, description: 'Configure SSH, firewall and BBR', run: {|ctx| system apply $ctx }}
		{name: service-check, source: features/system.nu, description: 'Verify system hardening and services', run: {|ctx| system verify $ctx }}
		{name: caddy-init, source: features/caddy/setup.nu, description: 'Install Caddy, site and initial certificates', run: {|ctx| caddy apply $ctx }}
		{name: caddy-check, source: features/caddy/setup.nu, description: 'Verify Caddy listeners and initial site', run: {|ctx| caddy verify $ctx }}
		{name: 3x-panel-init, source: features/panel/setup.nu, description: 'Install and configure 3X-UI', run: {|ctx| panel apply $ctx }}
		{name: 3x-panel-check, source: features/panel/setup.nu, description: 'Verify panel and subscription settings', run: {|ctx| panel verify $ctx }}
		{name: 3x-inbound-init, source: features/panel/inbounds.nu, description: 'Create Direct and Cloudflare inbounds', run: {|ctx| inbounds apply $ctx }}
		{name: 3x-inbound-check, source: features/panel/inbounds.nu, description: 'Verify inbound transport and encryption', run: {|ctx| inbounds verify $ctx }}
		{name: cf-host-init, source: features/panel/hosts.nu, description: 'Synchronize Direct and CDN Host groups', run: {|ctx| hosts apply $ctx }}
		{name: cf-host-check, source: features/panel/hosts.nu, description: 'Verify Direct and CDN Host groups', run: {|ctx| hosts verify $ctx }}
		{name: 3x-client-init, source: features/panel/clients.nu, description: 'Synchronize clients and restart Xray', run: {|ctx| clients apply $ctx }}
		{name: 3x-client-check, source: features/panel/clients.nu, description: 'Verify client policies and subscription links', run: {|ctx| clients verify $ctx | ignore }}
		{name: connectivity-check, source: checks/connectivity.nu, description: 'Test loopback and public XHTTP H2/H3 paths', run: {|ctx| connectivity verify $ctx }}
		{name: fetch-apps-init, source: features/apps.nu, description: 'Install and start proxy application updater', run: {|ctx| apps apply $ctx }}
		{name: fetch-apps-check, source: features/apps.nu, description: 'Verify application downloads and updater state', run: {|ctx| apps verify $ctx }}
		{name: direct-tls-init, source: features/caddy/tls.nu, description: 'Enable public TLS unless --noTLS is set', run: {|ctx| tls apply $ctx }}
		{name: direct-tls-check, source: features/caddy/tls.nu, description: 'Verify active certificates and fallback pages', run: {|ctx| tls verify $ctx }}
	]
}

# 按名称返回唯一的阶段定义，名称不存在时报错
export def find-stage [name: string] {
	let matches = (catalog | where name == $name)
	ensure (($matches | length) == 1) $"Unknown stage: ($name)"
	$matches.0
}

# 按输入顺序将阶段名列表解析为阶段定义列表
export def plan [names: list] {
	$names | each {|name| find-stage $name }
}

# 将诊断目标映射到对应的检查阶段，拒绝未知目标
export def check-stage [target: string] {
	let checks = {
		system: service-check, caddy: caddy-check, panel: 3x-panel-check
		inbounds: 3x-inbound-check, hosts: cf-host-check, clients: 3x-client-check
		connectivity: connectivity-check, apps: fetch-apps-check, tls: direct-tls-check
	}
	ensure ($target in $checks) $"Unknown check: ($target); choose one of: ($checks | columns | str join ', ')"
	find-stage ($checks | get $target)
}

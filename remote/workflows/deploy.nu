use ../lib/runner.nu run-workflow
use stages.nu plan

export def deployment-stages [--noAPP] {
	[
		root-init system-init service-check
		caddy-init caddy-check
		3x-panel-init 3x-panel-check
		3x-inbound-init 3x-inbound-check
		cf-host-init cf-host-check
		3x-client-init 3x-client-check connectivity-check
		fetch-apps-init fetch-apps-check
		direct-tls-init direct-tls-check
	] | where {|name| not $noAPP or ($name not-in [fetch-apps-init fetch-apps-check]) }
}

export def steps [--noAPP] {
	plan (deployment-stages --noAPP=$noAPP)
}

export def execute [ctx: record, --from: string = root-init] {
	run-workflow $ctx (steps --noAPP=$ctx.noAPP) --from $from
}

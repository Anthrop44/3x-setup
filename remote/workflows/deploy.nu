use ../lib/runner.nu run-workflow
use stages.nu plan

# 按执行顺序返回部署阶段名，支持跳过代理客户端分发
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

# 将选定的部署阶段名解析为包含实现函数的执行计划
export def steps [--noAPP] {
	plan (deployment-stages --noAPP=$noAPP)
}

# 从指定阶段开始执行部署工作流，任一阶段失败即停止
export def execute [ctx: record, --from: string = root-init] {
	run-workflow $ctx (steps --noAPP=$ctx.noAPP) --from $from
}

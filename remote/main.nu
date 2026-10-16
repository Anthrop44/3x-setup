#!/usr/bin/env nu
const ROOT = path self | path dirname
use lib/core.nu [root-required ensure]
use lib/config.nu [context validate-config]
use lib/runner.nu execute-stage
use workflows/stages.nu [find-stage check-stage]
use workflows/deploy.nu
use workflows/sync.nu
use workflows/update.nu

# 检查root权限，并设置无人值守APT环境和系统命令搜索路径
def --env prepare [] {
	root-required
	$env.DEBIAN_FRONTEND = 'noninteractive'
	# systemd/sshd may supply a PATH without sbin.
	$env.PATH = ($env.PATH | prepend [/usr/local/sbin /usr/sbin /sbin])
}

# 读取远端执行上下文，并校验部署配置完整性
def load-context [no_tls: bool, no_app: bool] {
	let ctx = (context $ROOT $no_tls $no_app)
	validate-config $ctx.config $ctx.constants --complete
	$ctx
}

# 仅部署到刚重建的服务器；--from和--stage用于诊断
def 'main deploy' [--noTLS, --noAPP, --from: string = root-init, --stage: string] {
	# Resolve names before loading configuration or performing privileged operations.
	if $stage != null {
		find-stage $stage | ignore
	} else {
		ensure ($from in (deploy deployment-stages --noAPP=$noAPP)) $"Invalid starting stage: ($from)"
	}
	prepare
	let ctx = (load-context $noTLS $noAPP)
	if $stage != null { execute-stage (find-stage $stage) $ctx } else { deploy execute $ctx --from $from }
}

# 从经过校验的上传目录同步客户和CDN的Host组
def 'main sync' [staging: string] {
	prepare
	sync execute $ROOT $staging
}

# 更新系统软件包、3X-UI和已安装的代理客户端
def 'main update' [] {
	prepare
	update execute
}

# 对system、caddy、panel、inbounds、hosts、clients、connectivity、apps或tls执行只读检查
def 'main check' [target: string] {
	let stage = (check-stage $target)
	prepare
	execute-stage $stage (load-context true true)
}

# 查看按执行顺序排列的阶段及其实现路径，无需root权限或部署配置
def 'main list-stages' [--workflow: string = deploy, --noAPP, --json] {
	let stages = (match $workflow {
		deploy => { deploy steps --noAPP=$noAPP }
		sync => { sync steps }
		_ => { error make {msg: 'Choose --workflow deploy or --workflow sync'} }
	})
	let rows = ($stages | select name source description)
	if $json { $rows | to json } else { $rows }
}

# 显示远端部署、同步、更新和诊断命令的帮助
def main [] {
	help main
}

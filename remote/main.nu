#!/usr/bin/env nu
const ROOT = path self | path dirname
use lib/core.nu [root-required ensure]
use lib/config.nu [context validate-config]
use lib/runner.nu execute-stage
use workflows/stages.nu [find-stage check-stage]
use workflows/deploy.nu
use workflows/sync.nu
use workflows/update.nu

def --env prepare [] {
	root-required
	$env.DEBIAN_FRONTEND = 'noninteractive'
	# systemd/sshd may supply a PATH without sbin.
	$env.PATH = ($env.PATH | prepend [/usr/local/sbin /usr/sbin /sbin])
}

def load-context [no_tls: bool, no_app: bool] {
	let ctx = (context $ROOT $no_tls $no_app)
	validate-config $ctx.config $ctx.constants --complete
	$ctx
}

# Deploy only to a freshly rebuilt server; --from and --stage are diagnostic tools.
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

# Synchronize clients and CDN Host groups from a validated upload directory.
def 'main sync' [staging: string] {
	prepare
	sync execute $ROOT $staging
}

# Update system packages, 3X-UI and installed proxy applications.
def 'main update' [] {
	prepare
	update execute
}

# Run a read-only system, caddy, panel, inbounds, hosts, clients, connectivity, apps or tls check.
def 'main check' [target: string] {
	let stage = (check-stage $target)
	prepare
	execute-stage $stage (load-context true true)
}

# Inspect ordered stages and implementation paths without root or deployment configuration.
def 'main list-stages' [--workflow: string = deploy, --noAPP, --json] {
	let stages = (match $workflow {
		deploy => { deploy steps --noAPP=$noAPP }
		sync => { sync steps }
		_ => { error make {msg: 'Choose --workflow deploy or --workflow sync'} }
	})
	let rows = ($stages | select name source description)
	if $json { $rows | to json } else { $rows }
}

def main [] {
	help main
}

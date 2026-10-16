#!/usr/bin/env nu
const ROOT = path self | path dirname | path dirname
use ../remote/lib/core.nu *
use ../remote/lib/config.nu [context validate-config]
use ../remote/lib/runner.nu run-workflow
use ../remote/workflows/deploy.nu
use ../remote/workflows/sync.nu
use ../remote/workflows/stages.nu [catalog find-stage check-stage]
use ../remote/features/caddy/config.nu render-caddyfile
use ../remote/features/panel/inbounds.nu inbound-payloads
use ../remote/features/panel/hosts.nu host-payloads
use ../remote/features/panel/clients.nu [client-policy stale-clients validate-links]
use ../remote/features/panel/encryption.nu select-vless-encryption
use ../remote/checks/connectivity.nu proxy-config
use ../remote/features/apps.nu
use ../modules/setup-config.nu prepare-config
use ../modules/ssh.nu [ssh-target scp-target]

# 断言实际值与预期值相等，否则显示差异并抛错
def equal [actual: any, expected: any] {
	ensure ($actual == $expected) $"Expected ($expected | to nuon), got ($actual | to nuon)"
}

# 断言闭包执行失败且错误信息包含指定文本
def rejects [body: closure, message: string] {
	let result = (try { do $body; {failed: false, message: ''} } catch {|err| {failed: true, message: $err.msg} })
	ensure ($result.failed and ($result.message | str contains $message)) $"Expected failure containing '($message)', got ($result | to nuon)"
}

# 运行一组测试，并在成功后打印测试名称
def test [name: string, body: closure] {
	do $body
	print $"PASS ($name)"
}

# 在临时目录生成有效部署配置、常量和模板，返回测试上下文
def fixture [directory: string] {
	let remote = ($directory | path join remote)
	mkdir $remote ($remote | path join templates)
	cp ($ROOT | path join remote constants.json) $remote
	cp ($ROOT | path join remote templates Caddyfile.template) ($remote | path join templates)
	write-json ($remote | path join config.json) {
		directDomain: direct.example.com, cdnDomain: cdn.example.com
		cdnPort: 15443, cdnOptDomains: [opt.example.com], clients: [{client: alice, traffic: 10}]
	}
	prepare-config $directory --initial | ignore
	write-json ($remote | path join paths.json) {xhttpPath: test-xhttp-path}
	context $remote false false
}

# 生成满足格式与长度校验的VLESS加密测试数据
def encryption [] {
	{decryption: $"mlkem768x25519plus.xorpub.600s.(1..86 | each { 'A' } | str join)", encryption: $"mlkem768x25519plus.xorpub.1rtt.(1..1579 | each { 'A' } | str join)"}
}

# 运行本地语法、配置、工作流和业务逻辑测试
def main [] {
	test 'all Nu modules and entry points parse' {
		for file in (glob ($ROOT | path join '**/*.nu')) { ensure (nu-check --debug $file) $"Cannot parse ($file)" }
		checked -- bash -n ($ROOT | path join remote bootstrap.sh)
	}

	test 'workflow selection and diagnostic routing' {
		let all = (catalog)
		equal ($all.name | uniq | length) ($all | length)
		for stage in $all {
			ensure ($ROOT | path join remote $stage.source | path exists) $"Missing implementation: ($stage.name)"
		}
		let full = (deploy steps)
		equal $full.0.name root-init
		equal ($full | last | get name) direct-tls-check
		let reduced = (deploy steps --noAPP)
		equal ($full | length) (($reduced | length) + 2)
		ensure ('fetch-apps-init' not-in $reduced.name and 'connectivity-check' in $reduced.name) 'Wrong --noAPP plan'
		equal (sync steps | get name) [cf-host-init cf-host-check 3x-client-init 3x-client-check connectivity-check direct-tls-check]
		equal (check-stage clients | get source) features/panel/clients.nu
		equal (check-stage connectivity | get source) checks/connectivity.nu
		rejects { find-stage unknown } 'Unknown stage'
		rejects { check-stage unknown } 'Unknown check'
	}

	test 'configuration survives preparation and rejects invalid changes' {
		with-temp {|temp|
			let ctx = (fixture $temp)
			validate-config $ctx.config $ctx.constants --complete
			equal (ssh-target $ctx.config) root@direct.example.com
			equal (scp-target $ctx.config /root/3x-setup.tar) 'root@direct.example.com:/root/3x-setup.tar'
			equal (prepare-config $temp | get config) $ctx.config
			sync validate-changes $ctx.config ($ctx.config | upsert cdnOptDomains [] | upsert clients [{client: bob}])
			rejects { sync validate-changes $ctx.config ($ctx.config | update cdnPort 16443) } 'Only clients and cdnOptDomains'
			rejects { validate-config ($ctx.config | update directDomain invalid) $ctx.constants } 'invalid format'
			rejects { validate-config ($ctx.config | upsert ip '203.0.113.10') $ctx.constants } 'unknown property'
			rejects { validate-config ($ctx.config | upsert unexpected true) $ctx.constants } 'unknown property'
			rejects { validate-config ($ctx.config | update cdnPort 443) $ctx.constants } 'below minimum'
			rejects { validate-config ($ctx.config | update clients [$ctx.config.clients.0 $ctx.config.clients.0]) $ctx.constants } 'duplicate items'
			equal $ctx.paths.state ($ctx.dir | path join paths.json)
		}
	}

	test 'Caddy rendering resolves the relocated template and persisted paths' {
		with-temp {|temp|
			let ctx = (fixture $temp)
			let initial = (render-caddyfile $ctx)
			let acme = (render-caddyfile $ctx --acme)
			ensure ($initial | str contains 'test-xhttp-path') 'Missing XHTTP path'
			ensure ($initial | str contains 'tls /etc/caddy/3x-direct-cert.pem /etc/caddy/3x-direct-key.pem') 'Missing initial TLS files'
			ensure ($acme | str contains 'issuer acme') 'Missing ACME issuer'
			ensure ($acme | str contains 'auto_https disable_redirects ignore_loaded_certs') 'Missing ACME configuration'
			ensure (not ($acme | str contains '{{')) 'Unresolved template placeholder'
		}
	}

	test 'panel payloads, policies and proxy probes retain protocol settings' {
		with-temp {|temp|
			let ctx = (fixture $temp)
			let keys = (encryption)
			equal (select-vless-encryption {auths: [($keys | insert id mlkem768_xorpub)]}) $keys
			let payloads = (inbound-payloads $ctx (open $ctx.paths.state) $keys)
			equal $payloads.0.settings.encryption none
			equal $payloads.0.disableFlow true
			equal $payloads.1.settings.encryption $keys.encryption
			equal $payloads.1.disableFlow false
			equal $payloads.1.streamSettings.xhttpSettings.path /test-xhttp-path
			equal (host-payloads $ctx 1 --direct | length) 2
			equal (host-payloads $ctx 2 | length) 4
			let policy = (client-policy $ctx.config.clients.0)
			equal $policy.totalGB 10737418240
			equal (stale-clients $ctx.config.clients [$policy]) []
			equal (stale-clients $ctx.config.clients [($policy | update totalGB 0)]) [alice]
			for direct in [true false] {
				for alpn in ['' h2 h3] {
					let probe = (proxy-config $ctx test-uuid $keys 12345 --direct=$direct --alpn=$alpn)
					let target = $probe.outbounds.0.settings.vnext.0
					equal $target.users.0.flow (if $direct { '' } else { 'xtls-rprx-vision' })
					equal $target.users.0.encryption (if $direct { 'none' } else { $keys.encryption })
					if $alpn != '' { equal $target.port 443; equal $probe.outbounds.0.streamSettings.tlsSettings.alpn [$alpn] }
				}
			}
			let links = ([{domain: $ctx.config.directDomain, sni: $ctx.config.directDomain, encryption: none, flow: ''}] | append ([$ctx.config.cdnDomain] | append $ctx.config.cdnOptDomains | each {|domain| {domain: $domain, sni: $ctx.config.cdnDomain, encryption: $keys.encryption, flow: xtls-rprx-vision} }) | each {|target|
				[h2 h3] | each {|alpn|
					let query = ({type: xhttp, security: tls, sni: $target.sni, encryption: $target.encryption, flow: $target.flow, alpn: $alpn} | url build-query)
					$"vless://test-uuid@($target.domain):443?($query)"
				}
			} | flatten)
			validate-links $ctx $links {Direct: none, Cloudflare: $keys.encryption}
			rejects { validate-links $ctx ($links | each { str replace ':443?' ':8443?' }) {Direct: none, Cloudflare: $keys.encryption} } 'Missing or duplicate'
		}
	}

	test 'application asset selection, integrity and failure state' {
		with-temp {|temp|
			let asset = {id: 1, name: app.zip, size: 3, browser_download_url: 'https://example.com/app.zip'}
			let release = {id: 1, tag_name: v1, draft: false, prerelease: false, assets: [$asset]}
			equal (apps select-asset $release '^app[.]zip$') $asset
			rejects { apps select-asset ($release | update assets [$asset $asset]) '^app[.]zip$' } 'Expected one release asset'
			let file = ($temp | path join app.zip)
			'abc' | save $file
			ensure (apps validate-download $file 3 $"sha256:('abc' | hash sha256)") 'Valid download rejected'
			ensure (not (apps validate-download $file 4 '')) 'Bad size accepted'
			ensure (not (apps validate-download $file 3 'sha256:bad')) 'Bad hash accepted'
			let failed = (apps failure-state (apps failure-state (apps failure-state {tag: v1} one) two) three)
			equal $failed.failureCount 3
			equal $failed.disabled true
			equal (apps reset-state $failed) {tag: v1, failureCount: 0, disabled: false}
		}
	}

	test 'stage workers forward flags, capture both streams and stop on failure' {
		with-temp {|temp|
			let ctx = {paths: {main: ($ROOT | path join tests fixtures stage-worker.nu), log: ($temp | path join log)}, noTLS: true, noAPP: false}
			rejects { run-workflow $ctx [{name: success} {name: failure} {name: never}] } 'Stage failure failed; see'
			let success = (open --raw ($ctx.paths.log | path join success.log))
			let flags = ($success | lines | where { str starts-with '{' } | first | from json)
			equal $flags {stage: success, noTLS: true, noAPP: false}
			ensure ($success | str contains 'stderr from success') 'stderr was not captured'
			ensure ($success | str contains 'Completed success; execution time:') 'Completion metadata missing'
			let failure = (open --raw ($ctx.paths.log | path join failure.log))
			ensure ($failure | str contains 'stderr from failure') 'Failure log missing'
			ensure ($failure | str contains 'FAILED failure; execution time:') 'Failure metadata missing'
			ensure (not ($ctx.paths.log | path join never.log | path exists)) 'Workflow continued after failure'
			let resumed = ($ctx | update paths.log ($temp | path join resumed) | update noAPP true)
			run-workflow $resumed [{name: skipped} {name: success}] --from success
			ensure (not ($resumed.paths.log | path join skipped.log | path exists)) 'Wrong --from selection'
			let flags = (open --raw ($resumed.paths.log | path join success.log) | lines | where { str starts-with '{' } | first | from json)
			equal $flags.noAPP true
			rejects { run-workflow $ctx [{name: success}] --from missing } 'Invalid starting stage'
		}
	}

	test 'application job reset and real flock conflict stay inside the sandbox' {
		with-temp {|temp|
			let bin = ($temp | path join bin)
			mkdir $bin
			for item in [{source: root-id.nu, name: id} {source: install-directory.nu, name: install}] {
				let target = ($bin | path join $item.name)
				$"#!($nu.current-exe) --no-config-file\n(open --raw ($ROOT | path join tests fixtures $item.source))" | save $target
				checked -- chmod 755 $target
			}
			let runtime = {targetDir: ($temp | path join downloads), logPath: ($temp | path join events.log), resources: [{id: app}]}
			let state_dir = ($temp | path join state)
			let config_path = ($temp | path join runtime.json)
			let lock_path = ($temp | path join updater.lock)
			mkdir $state_dir
			write-json $config_path $runtime
			write-json ($state_dir | path join state.json) {resources: {app: {tag: v1, failureCount: 3, disabled: true}}}
			let job = ($ROOT | path join remote jobs fetch-apps.nu)
			with-env {PATH: ($env.PATH | prepend $bin), TEST_SANDBOX: $temp, FETCH_APPS_CONFIG_PATH: $config_path, FETCH_APPS_STATE_DIR: $state_dir, FETCH_APPS_LOCK_PATH: $lock_path} {
				checked -- nu --no-config-file $job --reset app
				let state = (open ($state_dir | path join state.json))
				equal $state.resources.app {tag: v1, failureCount: 0, disabled: false}
				ensure (open --raw $runtime.logPath | str contains 'event=resource_reset') 'Missing reset event'
				# The outer flock holds the exact lock the updater will try to acquire.
				checked -- flock $lock_path nu --no-config-file $job --update
				equal (open ($state_dir | path join state.json)) $state
				let invalid = (^nu --no-config-file $job --update --reset app | complete)
				ensure ($invalid.exit_code != 0 and ($invalid.stderr | str contains 'Choose either')) 'Invalid updater mode accepted'
			}
		}
	}

	test 'remote archive runs without local modules, configuration or current-directory assumptions' {
		with-temp {|temp|
			let package = ($temp | path join package)
			let unpacked = ($temp | path join unpacked)
			mkdir $package $unpacked
			for entry in [main.nu bootstrap.sh lib workflows features checks jobs templates constants.json constants.schema.json config.schema.json] {
				cp --recursive ($ROOT | path join remote $entry) $package
			}
			let archive = ($temp | path join remote.tar)
			checked -- tar -cf $archive -C $package .
			checked -- tar -xf $archive -C $unpacked
			cd $temp
			let entry = ($unpacked | path join main.nu)
			let rows = (capture -- nu --no-config-file $entry list-stages --json | from json)
			equal ($rows | length) (deploy steps | length)
			for row in $rows { ensure ($unpacked | path join $row.source | path exists) 'Packaged stage implementation missing' }
			equal (capture -- nu --no-config-file $entry list-stages --workflow sync --json | from json | get name) (sync steps | get name)
			let invalid = (^nu --no-config-file $entry deploy --stage unknown | complete)
			ensure ($invalid.exit_code != 0 and ($invalid.stderr | str contains 'Unknown stage')) 'Unknown stage was not rejected before configuration access'
			let invalid_from = (^nu --no-config-file $entry deploy --from unknown | complete)
			ensure ($invalid_from.exit_code != 0 and ($invalid_from.stderr | str contains 'Invalid starting stage')) 'Unknown --from accepted'
			# Exercise a real catalog dispatch with a safe no-op stage and temporary config.
			let ctx = (fixture ($temp | path join prepared))
			cp $ctx.paths.config $unpacked
			let bin = ($temp | path join bin)
			mkdir $bin
			let id = ($bin | path join id)
			$"#!($nu.current-exe) --no-config-file\n(open --raw ($ROOT | path join tests fixtures root-id.nu))" | save $id
			checked -- chmod 755 $id
			with-env {PATH: ($env.PATH | prepend $bin)} {
				let output = (capture -- nu --no-config-file $entry deploy --stage direct-tls-init --noTLS)
				ensure ($output | str contains 'Skipping ACME (--noTLS)') 'Stage options did not reach the feature'
				ensure ($output | str contains 'Completed direct-tls-init; execution time:') 'Catalog dispatch failed'
			}
		}
	}
	print 'All 9 test groups passed'
}

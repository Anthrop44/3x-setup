use ../../lib/core.nu [ensure decode-json]
use api.nu [with-panel request]

const LEGACY_OUTBOUND = '3x-setup-ban-outbound'
const MANAGED_RULES = {domain: '3x-setup-ban-domain', ip: '3x-setup-ban-ip'}

# URL解析器校验IPv6，IPv4要求完整的点分十进制表示
def valid-ip [entry: string] {
	let parts = ($entry | split row '/')
	let addr = $parts.0
	let ipv6 = ($addr | str contains ':')
	let limit = (if $ipv6 { 128 } else { 32 })
	if ($parts | length) > 2 { return false }
	if ($parts | length) == 2 and ($parts.1 !~ '^(0|[1-9][0-9]{0,2})$' or ($parts.1 | into int) > $limit) { return false }
	if $ipv6 {
		($addr =~ '^[a-f0-9:.]+$') and (try { $"http://[($addr)]" | url parse | ignore; true } catch { false })
	} else {
		($addr =~ '^((0|[1-9][0-9]{0,2})\.){3}(0|[1-9][0-9]{0,2})$') and ($addr | split row '.' | all {|n| ($n | into int) < 256 })
	}
}

export def read-blocklist [file: path] {
	let entries = (open --raw $file | lines | str trim | where {|entry| $entry != '' and not ($entry starts-with '#') } | str lowercase | uniq)
	let groups = ($entries | group-by {|entry| if $entry starts-with 'domain:' or $entry starts-with 'geosite:' { 'domain' } else { 'ip' } })
	let domains = ($groups.domain? | default [])
	let ips = ($groups.ip? | default [])
	for entry in $domains {
		ensure ($entry =~ '^domain:([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$' or $entry =~ '^geosite:[a-z0-9_-]+(@[a-z0-9_-]+)?$') $"Invalid domain entry: ($entry)"
	}
	for entry in $ips {
		ensure ($entry =~ '^geoip:[a-z0-9_-]+$' or (valid-ip $entry)) $"Invalid IP entry: ($entry)"
	}
	{domain: $domains, ip: $ips}
}

export def configure [template: record, blocklist: record] {
	let routing = ($template.routing? | default {})
	let rules = ($routing.rules? | default [] | where {|r| $r.outboundTag? != $LEGACY_OUTBOUND and $r.ruleTag? not-in ($MANAGED_RULES | values) })
	let outbounds = ($template.outbounds | where {|o| $o.tag? != $LEGACY_OUTBOUND })
	let managed = ($MANAGED_RULES | transpose field tag | each {|r|
		let entries = ($blocklist | get $r.field)
		if ($entries | is-not-empty) {
			{type: field, outboundTag: blocked, ruleTag: $r.tag} | insert $r.field $entries
		}
	})
	if ($managed | is-not-empty) {
		ensure ($outbounds | any {|o| $o.tag? == blocked and $o.protocol == blackhole }) 'Expected the built-in blocked blackhole outbound'
	}
	# API入站必须优先于可能匹配回环地址的IP规则
	let api = ($rules | take while {|r| $r.outboundTag? == api })
	$template | update outbounds $outbounds | upsert routing ($routing | upsert rules ($api | append $managed | append ($rules | skip ($api | length))))
}

export def apply [ctx: record] {
	let blocklist = (read-blocklist ($ctx.dir | path join ban-outbound.txt))
	with-panel $ctx {|session|
		let xray = (decode-json (request $session /panel/api/xray/ --post))
		let template = (decode-json $xray.xraySetting)
		let updated = (configure $template $blocklist)
		if $updated != $template {
			request $session /panel/api/xray/update --xray-template $updated --test-url ($xray.outboundTestUrl? | default '') | ignore
		}
	}
}

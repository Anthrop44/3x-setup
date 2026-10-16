use ../../lib/core.nu *
use api.nu *

export def client-policy [client: record] {
	let traffic = ($client.traffic? | default 0)
	{email: $client.client, subId: $client.path, totalGB: ($traffic * 1073741824), reset: (if $traffic > 0 { 30 } else { 0 })}
}

export def stale-clients [configured: list, current: list] {
	let expected = ($configured | each { client-policy $in })
	$current | where {|client|
		let matches = ($expected | where email == $client.email)
		($matches | is-empty) or (($client | select email subId totalGB reset) != $matches.0)
	} | get email | uniq
}

export def apply [ctx: record] {
	with-panel $ctx {|session|
		let inbounds = (request $session /panel/api/inbounds/list)
		let ids = ([Direct Cloudflare] | each {|remark| inbound $inbounds $remark | get id })
		mut current = (request $session /panel/api/clients/list | default [])
		let stale = (stale-clients $ctx.config.clients $current)
		if ($stale | is-not-empty) {
			request $session /panel/api/clients/bulkDel --data {emails: $stale, keepTraffic: false} | ignore
			$current = (request $session /panel/api/clients/list | default [])
		}
		for client in $ctx.config.clients {
			if ($current | any {|c| $c.email == $client.client and $c.subId == $client.path }) { continue }
			# The panel suppresses this flow on Direct (disableFlow), while Cloudflare retains Vision
			let policy = (client-policy $client | merge {auth: (token 24), flow: xtls-rprx-vision, security: auto, expiryTime: 0, limitIp: 0, enable: true, tgId: 0, comment: ''})
			request $session /panel/api/clients/add --data {client: $policy, inboundIds: $ids} | ignore
		}
		request $session /panel/api/server/restartXrayService --post | ignore
		retry 30 1sec {
			let status = (request $session /panel/api/server/status)
			ensure (($status.xray?.state? | default $status.state?) == running) 'Xray is not running'
		}
	}
}

export def subscription-links [value: any] {
	let kind = ($value | describe)
	if $kind == string { $value | lines | where {|s| $s != '' } } else if $kind starts-with record { $value.externalLinks? | default [] } else { $value }
}

export def validate-links [ctx: record, value: any, encryption: record] {
	let links = (subscription-links $value)
	let domains = ([$ctx.config.cdnDomain] | append ($ctx.config.cdnOptDomains? | default []))
	ensure (($links | length) == (2 + 2 * ($domains | length))) 'Wrong subscription link count'
	ensure ($encryption.Direct == none) 'Direct XHTTP must not use VLESS Encryption'
	let targets = ([{domain: $ctx.config.directDomain, sni: $ctx.config.directDomain, encryption: none, flow: ''}] | append ($domains | each {|domain| {domain: $domain, sni: $ctx.config.cdnDomain, encryption: $encryption.Cloudflare, flow: xtls-rprx-vision} }))
	for target in $targets {
		for alpn in [h2 h3] {
			let matching = ($links | where {|link|
				let url = ($link | url parse)
				$url.scheme == vless and $url.host == $target.domain and $url.port == '443' and (($url.params | where key == alpn | get value) == [$alpn])
			})
			ensure (($matching | length) == 1) $"Missing or duplicate XHTTP subscription: ($target.domain)/($alpn)"
			let params = ($matching.0 | url parse | get params)
			ensure (($params | where key == type | get value) == [xhttp] and ($params | where key == security | get value) == [tls] and ($params | where key == sni | get value) == [$target.sni]) 'Wrong XHTTP subscription transport or TLS settings'
			ensure (($params | where key == encryption | get value) == [$target.encryption]) 'XHTTP subscription encryption does not match the inbound'
			let flows = ($params | where key == flow | get value)
			if $target.flow == '' {
				ensure ($flows in [[] ['']]) 'Direct XHTTP subscription must not use Vision flow'
			} else {
				ensure ($flows == [$target.flow]) 'CDN XHTTP subscription is missing Vision flow'
			}
		}
	}
	ensure ($links | all {|link| $link =~ '^vless://[^@]+@[^:/?#]+:443([/?#]|$)' }) 'A subscription has an obsolete protocol or exposes an internal port'
}

export def verify [ctx: record] {
	with-panel $ctx {|session|
		let inbounds = (request $session /panel/api/inbounds/list)
		let direct = (inbound $inbounds Direct | get settings)
		let cf = (inbound $inbounds Cloudflare | get settings)
		let ids = ([Direct Cloudflare] | each {|remark| inbound $inbounds $remark | get id })
		for client in $ctx.config.clients {
			let actual = (request $session $"/panel/api/clients/get/($client.client)")
			let expected = (client-policy $client)
			ensure (($actual.client | select email subId totalGB reset) == $expected) $"Wrong client policy: ($client.client)"
			ensure ($actual.client.enable and ($actual.client.comment? | default '') == '' and ($actual.client.auth | str length) >= 16) 'Invalid client authentication or state'
			ensure ($ids | all {|id| $id in $actual.inboundIds }) 'Client is missing an inbound'
			let uuid = ($actual.client.uuid? | default $actual.client.id?)
			ensure ($uuid | is-not-empty) 'Client UUID missing'
			request $session $"/panel/api/clients/links/($client.client)" | ignore
			validate-links $ctx (request $session $"/panel/api/clients/subLinks/($client.path)") {Direct: $direct.encryption, Cloudflare: $cf.encryption}
		}
	}
}

use common.nu *
use 3x-ui-api.nu *

export def host-payloads [ctx: record, inbound_id: int] {
	let domains = ([$ctx.config.cdnDomain] | append ($ctx.config.cdnOptDomains? | default []))
	$domains | enumerate | each {|item|
		[h2 h3] | enumerate | each {|protocol|
			let prefix = (if $item.index == 0 { '3xsetupxhttpcdn1' } else { $"3xsetupxhttpopt($item.index)" })
			let remark = (if $item.index == 0 { 'Cloudflare Vanilla' } else { $"Cloudflare OPT ($item.index)" })
			{groupId: $"($prefix)($protocol.item)", inboundIds: [$inbound_id], hosts: [$item.item], sortOrder: ($item.index * 2 + $protocol.index), remark: $"($remark) ($protocol.item)", isDisabled: false, isHidden: false, port: 443, security: tls, sni: $ctx.config.cdnDomain, alpn: [$protocol.item], fingerprint: $ctx.constants.fingerprint}
		}
	} | flatten
}

export def apply [ctx: record] {
	with-panel $ctx {|session|
		let id = (inbound (api $session /panel/api/inbounds/list) Cloudflare | get id)
		let current = (api $session $"/panel/api/hosts/byInbound/($id)" | default [])
		let expected = (host-payloads $ctx $id)
		for payload in $expected {
			let endpoint = (if ($current | any {|g| $g.groupId == $payload.groupId }) { $"/panel/api/hosts/update/($payload.groupId)" } else { '/panel/api/hosts/bulk/add' })
			api $session $endpoint --data $payload | ignore
		}
		let extra = ($current | where {|g| $g.groupId not-in $expected.groupId } | get groupId)
		if ($extra | is-not-empty) { api $session /panel/api/hosts/bulk/del --data {ids: $extra} | ignore }
	}
}

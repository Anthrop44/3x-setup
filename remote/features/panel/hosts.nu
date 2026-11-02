use ../../lib/core.nu ensure
use ../../lib/config.nu cdn-addresses
use api.nu *

# 直连使用普通TLS，CDN生成ECH H2/H3 Host组
export def host-payloads [ctx: record, inbound_id: int, --direct] {
	let domains = (if $direct { [$ctx.config.directDomain] } else { cdn-addresses $ctx.constants })
	let ech = (if $direct { '' } else { $ctx.constants.cdnEchConfigList })
	ensure ($direct or ($ech | is-not-empty)) 'CDN requires cdnEchConfigList'
	$domains | enumerate | each {|item|
		[h2 h3] | enumerate | each {|protocol|
			let prefix = (if $direct { '3xsetupxhttpdirect' } else if $item.index == 0 { '3xsetupxhttpcdn1' } else { $"3xsetupxhttpopt($item.index)" })
			let remark = (if $direct { 'Direct' } else { 'Cloudflare ECH' })
			let suffix = (if $direct { '' } else { 'ech' })
			{groupId: $"($prefix)($protocol.item)($suffix)", inboundIds: [$inbound_id], hosts: [$item.item], sortOrder: ($item.index * 2 + $protocol.index), remark: $"($remark) ($protocol.item)", isDisabled: false, isHidden: false, port: 443, security: tls, sni: (if $direct { $ctx.config.directDomain } else { $ctx.config.cdnDomain }), alpn: [$protocol.item], fingerprint: $ctx.constants.fingerprint, echConfigList: $ech}
		}
	} | flatten
}

# 创建或更新直连与CDN的Host组，并删除多余组
export def apply [ctx: record] {
	with-panel $ctx {|session|
		let inbounds = (request $session /panel/api/inbounds/list)
		for remark in [Direct Cloudflare] {
			let id = (inbound $inbounds $remark | get id)
			let current = (request $session $"/panel/api/hosts/byInbound/($id)" | default [])
			let expected = (host-payloads $ctx $id --direct=($remark == Direct))
			for payload in $expected {
				let endpoint = (if ($current | any {|g| $g.groupId == $payload.groupId }) { $"/panel/api/hosts/update/($payload.groupId)" } else { '/panel/api/hosts/bulk/add' })
				request $session $endpoint --data $payload | ignore
			}
			let extra = ($current | where {|g| $g.groupId not-in $expected.groupId } | get groupId)
			if ($extra | is-not-empty) { request $session /panel/api/hosts/bulk/del --data {ids: $extra} | ignore }
		}
	}
}

# 检查直连与CDN的Host组数量及各项配置
export def verify [ctx: record] {
	with-panel $ctx {|session|
		let inbounds = (request $session /panel/api/inbounds/list)
		for remark in [Direct Cloudflare] {
			let id = (inbound $inbounds $remark | get id)
			let groups = (request $session $"/panel/api/hosts/byInbound/($id)" | default [])
			let expected = (host-payloads $ctx $id --direct=($remark == Direct))
			ensure (($groups | length) == ($expected | length)) $"Wrong number of XHTTP Host groups: ($remark)"
			for item in $expected {
				let matches = ($groups | where groupId == $item.groupId)
				ensure (($matches | length) == 1) $"Missing or duplicate Host: ($item.groupId)"
				let wanted = ($item | reject inboundIds | update hosts {|g| $g.hosts | each {|host| $"($host):443" } })
				ensure (($matches.0 | select ...($wanted | columns)) == $wanted) $"Wrong XHTTP Host: ($item.groupId)"
			}
		}
	}
}

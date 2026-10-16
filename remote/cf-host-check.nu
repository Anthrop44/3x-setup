use common.nu *
use 3x-ui-api.nu *
use cf-host-init.nu host-payloads

export def verify [ctx: record] {
	with-panel $ctx {|session|
		let inbounds = (api $session /panel/api/inbounds/list)
		for remark in [Direct Cloudflare] {
			let id = (inbound $inbounds $remark | get id)
			let groups = (api $session $"/panel/api/hosts/byInbound/($id)" | default [])
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

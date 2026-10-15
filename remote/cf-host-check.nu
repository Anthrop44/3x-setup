use common.nu *
use 3x-ui-api.nu *
use cf-host-init.nu host-payloads

export def verify [ctx: record] {
	with-panel $ctx {|session|
		let id = (inbound (api $session /panel/api/inbounds/list) Cloudflare | get id)
		let groups = (api $session $"/panel/api/hosts/byInbound/($id)" | default [])
		let expected = (host-payloads $ctx $id)
		ensure (($groups | length) == ($expected | length)) 'Wrong number of XHTTP Host groups'
		for item in $expected {
			let matches = ($groups | where groupId == $item.groupId)
			ensure (($matches | length) == 1) $"Missing or duplicate Host: ($item.groupId)"
			let wanted = ($item | reject inboundIds | update hosts {|g| $g.hosts | each {|host| $"($host):443" } })
			ensure (($matches.0 | select ...($wanted | columns)) == $wanted) $"Wrong XHTTP Host: ($item.groupId)"
		}
	}
}

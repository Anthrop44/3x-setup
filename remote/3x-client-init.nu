use common.nu *
use 3x-ui-api.nu *

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
		let inbounds = (api $session /panel/api/inbounds/list)
		let ids = ([QUIC TCP Cloudflare] | each {|remark| inbound $inbounds $remark | get id })
		mut current = (api $session /panel/api/clients/list | default [])
		let stale = (stale-clients $ctx.config.clients $current)
		if ($stale | is-not-empty) {
			api $session /panel/api/clients/bulkDel --data {emails: $stale, keepTraffic: false} | ignore
			$current = (api $session /panel/api/clients/list | default [])
		}
		for client in $ctx.config.clients {
			if ($current | any {|c| $c.email == $client.client and $c.subId == $client.path }) { continue }
			let policy = (client-policy $client | merge {auth: (token 24), flow: xtls-rprx-vision, security: auto, expiryTime: 0, limitIp: 0, enable: true, tgId: 0, comment: ''})
			api $session /panel/api/clients/add --data {client: $policy, inboundIds: $ids} | ignore
		}
		api $session /panel/api/server/restartXrayService --post | ignore
		retry 30 1sec {
			let status = (api $session /panel/api/server/status)
			ensure (($status.xray?.state? | default $status.state?) == running) 'Xray is not running'
		}
	}
}

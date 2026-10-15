use common.nu *
use 3x-ui-api.nu *
use 3x-client-init.nu client-policy

export def subscription-links [value: any] {
	let kind = ($value | describe)
	if $kind == string { $value | lines | where {|s| $s != '' } } else if $kind starts-with record { $value.externalLinks? | default [] } else { $value }
}

export def validate-links [ctx: record, value: any, encryption: string] {
	let links = (subscription-links $value)
	let domains = ([$ctx.config.cdnDomain] | append ($ctx.config.cdnOptDomains? | default []))
	ensure (($links | length) == (2 + 2 * ($domains | length))) 'Wrong subscription link count'
	ensure ($links | any {|link| ($link starts-with 'hysteria2://') and ($link | str contains $"@($ctx.config.directDomain):443") and ($link | str contains QUIC) }) 'Missing Hysteria2 subscription link'
	ensure ($links | any {|link| ($link starts-with 'vless://') and ($link | str contains $"@($ctx.config.directDomain):443") and ($link | str contains 'flow=xtls-rprx-vision') and ($link | str contains TCP) }) 'Missing Reality subscription link'
	for domain in $domains {
		for alpn in [h2 h3] {
			let matching = ($links | where {|link| ($link starts-with 'vless://') and ($link | str contains $"@($domain):443") and ($link | str contains 'type=xhttp') and ($link | str contains $"alpn=($alpn)") })
			ensure (($matching | length) == 1) $"Missing or duplicate XHTTP subscription: ($domain)/($alpn)"
			let params = ($matching.0 | url parse | get params)
			ensure (($params | where key == encryption | get value) == [$encryption]) 'XHTTP subscription encryption does not match the inbound'
			ensure (($params | where key == flow | get value) == [xtls-rprx-vision]) 'XHTTP subscription is missing Vision flow'
		}
	}
	ensure ($links | all {|link| $link =~ '^(vless|hysteria2)://[^@]+@[^:/?#]+:443([/?#]|$)' }) 'A subscription exposes an internal port'
}

export def proxy-config [ctx: record, uuid: string, reality: record, socks_port: int, --xhttp: record = {}, --cdn-alpn: string = ''] {
	let is_xhttp = ($xhttp | is-not-empty)
	let cdn = ($cdn_alpn != '')
	ensure (not $cdn or ($is_xhttp and $cdn_alpn in [h2 h3])) 'CDN testing requires XHTTP with h2 or h3'
	let paths = (open ($ctx.dir | path join paths.json))
	let stream = (if $is_xhttp {
		{network: xhttp, security: (if $cdn { 'tls' } else { 'none' }), xhttpSettings: {path: $"/($paths.xhttpPath)", host: (if $cdn { $ctx.config.cdnDomain } else { '' }), mode: auto}} | merge (if $cdn {
			{tlsSettings: {serverName: $ctx.config.cdnDomain, fingerprint: $ctx.constants.fingerprint, alpn: [$cdn_alpn]}}
		} else { {} })
	} else {
		{network: tcp, security: reality, realitySettings: {serverName: $ctx.config.directDomain, fingerprint: $ctx.constants.fingerprint, publicKey: $reality.settings.publicKey, shortId: $reality.shortIds.0, spiderX: '/'}}
	})
	let user = {id: $uuid, encryption: (if $is_xhttp { $xhttp.encryption } else { 'none' }), flow: xtls-rprx-vision}
	{log: {loglevel: warning}, inbounds: [{tag: socks, listen: '127.0.0.1', port: $socks_port, protocol: socks, settings: {auth: noauth, udp: false}}], outbounds: [{tag: proxy, protocol: vless, settings: {vnext: [{address: (if $cdn { $ctx.config.cdnDomain } else { '127.0.0.1' }), port: (if $is_xhttp and not $cdn { $ctx.constants.xhttpPort } else { 443 }), users: [$user]}]}, streamSettings: $stream}]}
}

def proxy-test [ctx: record, uuid: string, reality: record, --xhttp: record = {}, --cdn-alpn: string = ''] {
	let candidates = (glob /usr/local/x-ui/bin/xray* | where {|p| ($p | path type) == file })
	ensure ($candidates | is-not-empty) 'Xray binary not found'
	let binary = $candidates.0
	with-temp {|temp|
		let socks_port = (port)
		let config = ($temp | path join test.json)
		let log = ($temp | path join xray.log)
		write-json $config (proxy-config $ctx $uuid $reality $socks_port --xhttp=$xhttp --cdn-alpn=$cdn_alpn)
		let id = (job spawn { ^$binary run -config $config out+err> $log })
		try {
			retry 20 1sec { ensure (listening $socks_port --local) 'Waiting for test SOCKS port' }
			curl-text -- --max-time 20 --socks5-hostname $"127.0.0.1:($socks_port)" https://www.cloudflare.com/cdn-cgi/trace | ignore
			try { job kill $id } catch { }
		} catch {|err|
			try { job kill $id } catch { }
			let detail = (if ($log | path exists) { open --raw $log } else { '' })
			error make {msg: $"($err.msg)\n($detail)"}
		}
	}
}

export def verify [ctx: record] {
	with-panel $ctx {|session|
		let inbounds = (api $session /panel/api/inbounds/list)
		let xhttp = (inbound $inbounds Cloudflare | get settings)
		let ids = ([QUIC TCP Cloudflare] | each {|remark| inbound $inbounds $remark | get id })
		mut test_uuid = ''
		for client in $ctx.config.clients {
			let actual = (api $session $"/panel/api/clients/get/($client.client)")
			let expected = (client-policy $client)
			ensure (($actual.client | select email subId totalGB reset) == $expected) $"Wrong client policy: ($client.client)"
			ensure ($actual.client.enable and ($actual.client.comment? | default '') == '' and ($actual.client.auth | str length) >= 16) 'Invalid client authentication or state'
			ensure ($ids | all {|id| $id in $actual.inboundIds }) 'Client is missing an inbound'
			let uuid = ($actual.client.uuid? | default $actual.client.id?)
			ensure ($uuid | is-not-empty) 'Client UUID missing'
			if $test_uuid == '' { $test_uuid = $uuid }
			api $session $"/panel/api/clients/links/($client.client)" | ignore
			validate-links $ctx (api $session $"/panel/api/clients/subLinks/($client.path)") $xhttp.encryption
		}
		let status = (api $session /panel/api/server/status)
		ensure (($status.xray?.state? | default $status.state?) == running) 'Xray is not running'
		ensure (listening 443 --udp) 'Hysteria2 is not listening'
		ensure (listening 443) 'Reality is not listening'
		only-loopback $ctx.constants.xhttpPort
		let reality = (inbound $inbounds TCP | get streamSettings.realitySettings)
		proxy-test $ctx $test_uuid $reality
		print 'Reality end-to-end proxy test passed'
		proxy-test $ctx $test_uuid $reality --xhttp=$xhttp
		print 'XHTTP ML-KEM-768 (xorpub) + Vision loopback proxy test passed'
		for alpn in [h2 h3] {
			proxy-test $ctx $test_uuid $reality --xhttp=$xhttp --cdn-alpn=$alpn
			print $"XHTTP CDN ($alpn) ML-KEM-768 \(xorpub\) + Vision end-to-end proxy test passed"
		}
	}
	no-failed-units
}

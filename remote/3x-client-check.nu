use common.nu *
use 3x-ui-api.nu *
use 3x-client-init.nu client-policy

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

export def proxy-config [ctx: record, uuid: string, xhttp: record, socks_port: int, --direct, --alpn: string = ''] {
	let tls = ($alpn != '')
	ensure (not $tls or $alpn in [h2 h3]) 'XHTTP testing requires h2 or h3'
	let paths = (open ($ctx.dir | path join paths.json))
	let domain = (if $direct { $ctx.config.directDomain } else { $ctx.config.cdnDomain })
	let stream = ({network: xhttp, security: (if $tls { 'tls' } else { 'none' }), xhttpSettings: {path: $"/($paths.xhttpPath)", host: (if $tls { $domain } else { '' }), mode: auto}} | merge (if $tls {
		# Direct TLS tests also run before ACME, so trust the bootstrap certificate alongside system roots
		{tlsSettings: ({serverName: $domain, fingerprint: $ctx.constants.fingerprint, alpn: [$alpn]} | merge (if $direct {
			{certificates: [{certificateFile: /etc/caddy/3x-direct-cert.pem, usage: verify}]}
		} else { {} }))}
	} else { {} }))
	let user = {id: $uuid, encryption: (if $direct { 'none' } else { $xhttp.encryption }), flow: (if $direct { '' } else { 'xtls-rprx-vision' })}
	let address = (if $tls and not $direct { $domain } else { '127.0.0.1' })
	let port = (if $tls { 443 } else if $direct { $ctx.constants.directXhttpPort } else { $ctx.constants.xhttpPort })
	{log: {loglevel: warning}, inbounds: [{tag: socks, listen: '127.0.0.1', port: $socks_port, protocol: socks, settings: {auth: noauth, udp: false}}], outbounds: [{tag: proxy, protocol: vless, settings: {vnext: [{address: $address, port: $port, users: [$user]}]}, streamSettings: $stream}]}
}

def proxy-test [ctx: record, uuid: string, xhttp: record, --direct, --alpn: string = ''] {
	let candidates = (glob /usr/local/x-ui/bin/xray* | where {|p| ($p | path type) == file })
	ensure ($candidates | is-not-empty) 'Xray binary not found'
	let binary = $candidates.0
	with-temp {|temp|
		let socks_port = (port)
		let config = ($temp | path join test.json)
		let log = ($temp | path join xray.log)
		write-json $config (proxy-config $ctx $uuid $xhttp $socks_port --direct=$direct --alpn=$alpn)
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
		let direct = (inbound $inbounds Direct | get settings)
		let cf = (inbound $inbounds Cloudflare | get settings)
		let ids = ([Direct Cloudflare] | each {|remark| inbound $inbounds $remark | get id })
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
			validate-links $ctx (api $session $"/panel/api/clients/subLinks/($client.path)") {Direct: $direct.encryption, Cloudflare: $cf.encryption}
		}
		let status = (api $session /panel/api/server/status)
		ensure (($status.xray?.state? | default $status.state?) == running) 'Xray is not running'
		ensure (listening 443 --udp) 'Caddy XHTTP H3 is not listening'
		ensure (listening 443) 'Caddy XHTTP H2 is not listening'
		only-loopback $ctx.constants.directXhttpPort
		only-loopback $ctx.constants.xhttpPort
		for target in [{remark: Direct, settings: $direct, direct: true} {remark: Cloudflare, settings: $cf, direct: false}] {
			let protection = (if $target.direct { 'plain VLESS (TLS at Caddy)' } else { 'ML-KEM-768 (xorpub) + Vision' })
			proxy-test $ctx $test_uuid $target.settings --direct=$target.direct
			print $"XHTTP ($target.remark) ($protection) loopback proxy test passed"
			for alpn in [h2 h3] {
				proxy-test $ctx $test_uuid $target.settings --direct=$target.direct --alpn=$alpn
				print $"XHTTP ($target.remark) ($alpn) ($protection) end-to-end proxy test passed"
			}
		}
	}
	no-failed-units
}

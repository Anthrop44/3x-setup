use ../lib/core.nu *
use ../lib/network.nu [curl-text listening only-loopback]
use ../lib/systemd.nu no-failed-units
use ../features/panel/api.nu *

# 生成用于回环或公网H2/H3链路测试的临时Xray代理配置
export def proxy-config [ctx: record, uuid: string, xhttp: record, socks_port: int, --direct, --alpn: string = '', --ech, --address: string = ''] {
	let tls = ($alpn != '')
	ensure (not $tls or $alpn in [h2 h3]) 'XHTTP testing requires h2 or h3'
	ensure (not $ech or ($tls and not $direct and ($ctx.constants.cdnEchConfigList? | default '' | is-not-empty))) 'ECH testing requires CDN TLS and cdnEchConfigList'
	ensure ($address == '' or $tls) 'A public test address requires TLS'
	let paths = (open $ctx.paths.state)
	let domain = (if $direct { $ctx.config.directDomain } else { $ctx.config.cdnDomain })
	let stream = ({network: xhttp, security: (if $tls { 'tls' } else { 'none' }), xhttpSettings: {path: $"/($paths.xhttpPath)", host: (if $tls { $domain } else { '' }), mode: auto}} | merge (if $tls {
		# Direct TLS tests also run before ACME, so trust the bootstrap certificate alongside system roots
		{tlsSettings: ({serverName: $domain, fingerprint: $ctx.constants.fingerprint, alpn: [$alpn]} | merge (if $direct {
			{certificates: [{certificateFile: /etc/caddy/3x-direct-cert.pem, usage: verify}]}
		} else if $ech { {echConfigList: $ctx.constants.cdnEchConfigList} } else { {} }))}
	} else { {} }))
	let user = {id: $uuid, encryption: (if $direct { 'none' } else { $xhttp.encryption }), flow: (if $direct { '' } else { 'xtls-rprx-vision' })}
	let address = (if $address != '' { $address } else if $tls and not $direct { $domain } else { '127.0.0.1' })
	let port = (if $tls { 443 } else if $direct { $ctx.constants.directXhttpPort } else { $ctx.constants.xhttpPort })
	{log: {loglevel: warning}, inbounds: [{tag: socks, listen: '127.0.0.1', port: $socks_port, protocol: socks, settings: {auth: noauth, udp: false}}], outbounds: [{tag: proxy, protocol: vless, settings: {vnext: [{address: $address, port: $port, users: [$user]}]}, streamSettings: $stream}]}
}

# 启动临时Xray并通过SOCKS测试代理链路，结束时清理测试任务
def proxy-test [ctx: record, uuid: string, xhttp: record, --direct, --alpn: string = '', --ech, --address: string = ''] {
	let candidates = (glob /usr/local/x-ui/bin/xray* | where {|p| ($p | path type) == file })
	ensure ($candidates | is-not-empty) 'Xray binary not found'
	let binary = $candidates.0
	with-temp {|temp|
		let socks_port = (port)
		let config = ($temp | path join test.json)
		let log = ($temp | path join xray.log)
		write-json $config (proxy-config $ctx $uuid $xhttp $socks_port --direct=$direct --alpn=$alpn --ech=$ech --address=$address)
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

# 检查Xray和监听地址，并测试直连与CDN的回环及公网H2/H3链路
export def verify [ctx: record] {
	with-panel $ctx {|session|
		let inbounds = (request $session /panel/api/inbounds/list)
		let direct = (inbound $inbounds Direct | get settings)
		let cf = (inbound $inbounds Cloudflare | get settings)
		let client = (request $session $"/panel/api/clients/get/($ctx.config.clients.0.client)" | get client)
		let uuid = ($client.uuid? | default $client.id?)
		ensure ($uuid | is-not-empty) 'Client UUID missing for connectivity test'
		let status = (request $session /panel/api/server/status)
		ensure (($status.xray?.state? | default $status.state?) == running) 'Xray is not running'
		ensure (listening 443 --udp) 'Caddy XHTTP H3 is not listening'
		ensure (listening 443) 'Caddy XHTTP H2 is not listening'
		only-loopback $ctx.constants.directXhttpPort
		only-loopback $ctx.constants.xhttpPort
		for target in [{remark: Direct, settings: $direct, direct: true} {remark: Cloudflare, settings: $cf, direct: false}] {
			let protection = (if $target.direct { 'plain VLESS (TLS at Caddy)' } else { 'ML-KEM-768 (xorpub) + Vision' })
			proxy-test $ctx $uuid $target.settings --direct=$target.direct
			print $"XHTTP ($target.remark) ($protection) loopback proxy test passed"
			let addresses = (if $target.direct { [''] } else { [$ctx.config.cdnDomain] | append ($ctx.constants.cdnOptDomains? | default []) })
			let variants = (if not $target.direct and ($ctx.constants.cdnEchConfigList? | default '' | is-not-empty) { [false true] } else { [false] })
			for address in $addresses {
				for ech in $variants {
					for alpn in [h2 h3] {
						proxy-test $ctx $uuid $target.settings --direct=$target.direct --alpn=$alpn --ech=$ech --address=$address
						print $"XHTTP ($target.remark) ($address) ($alpn) (if $ech { 'ECH' } else { 'TLS' }) ($protection) end-to-end proxy test passed"
					}
				}
			}
		}
	}
	no-failed-units
}

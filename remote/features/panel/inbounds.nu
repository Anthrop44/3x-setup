use ../../lib/core.nu ensure
use ../../lib/systemd.nu no-failed-units
use api.nu *
use encryption.nu *

# 生成直连无VLESS加密和CDN使用ML-KEM-768的XHTTP入站请求数据
export def inbound-payloads [ctx: record, paths: record, encryption: record] {
	validate-vless-encryption $encryption
	let common = {enable: true, listen: '127.0.0.1', expiryTime: 0, total: 0, trafficReset: never, shareAddrStrategy: listen, shareAddr: ''}
	let sniffing = {enabled: true, destOverride: [http tls quic], metadataOnly: false, routeOnly: false, ipsExcluded: [], domainsExcluded: []}
	let vless = {clients: [], decryption: none, encryption: none}
	let stream = {
		network: xhttp, security: none
		xhttpSettings: {
			path: $"/($paths.xhttpPath)", host: '', mode: auto, xPaddingBytes: '100-1000', xPaddingObfsMode: false
			xPaddingKey: '', xPaddingHeader: '', xPaddingPlacement: '', xPaddingMethod: '', sessionPlacement: '', sessionKey: ''
			seqPlacement: '', seqKey: '', uplinkDataPlacement: '', uplinkDataKey: '', scMaxEachPostBytes: '', noSSEHeader: false
			scMaxBufferedPosts: 30, scStreamUpServerSecs: '20-80', serverMaxHeaderBytes: 0, uplinkHTTPMethod: '', headers: {}
			scMinPostsIntervalMs: '', uplinkChunkSize: 0, noGRPCHeader: false
		}
	}
	[
		($common | merge {
			remark: Direct, protocol: vless, subSortIndex: 1, settings: $vless, disableFlow: true, sniffing: $sniffing
			port: $ctx.constants.directXhttpPort, streamSettings: $stream
		})
		($common | merge {
			remark: Cloudflare, protocol: vless, subSortIndex: 2, settings: ($vless | merge $encryption), disableFlow: false, sniffing: $sniffing
			port: $ctx.constants.xhttpPort, streamSettings: $stream
		})
	]
}

# 获取面板生成的加密密钥并创建Direct与Cloudflare入站
export def apply [ctx: record] {
	with-panel $ctx {|session|
		let encryption = (select-vless-encryption (request $session /panel/api/server/getNewVlessEnc))
		let payloads = (inbound-payloads $ctx (open $ctx.paths.state) $encryption)
		for payload in $payloads { request $session /panel/api/inbounds/add --data $payload | ignore }
	}
}

# 检查两个XHTTP入站的监听、路径、加密、流控和回落策略
export def verify [ctx: record] {
	let paths = (open $ctx.paths.state)
	with-panel $ctx {|session|
		let inbounds = (request $session /panel/api/inbounds/list)
		ensure (($inbounds | length) == 2) 'Expected only Direct and Cloudflare XHTTP inbounds'
		for target in [
			{remark: Direct, sort: 1, port: $ctx.constants.directXhttpPort}
			{remark: Cloudflare, sort: 2, port: $ctx.constants.xhttpPort}
		] {
			let item = (inbound $inbounds $target.remark)
			ensure $item.enable $"Disabled inbound: ($item.remark)"
			ensure ($item.protocol == vless and $item.subSortIndex == $target.sort and $item.listen == '127.0.0.1' and $item.port == $target.port and $item.shareAddrStrategy == listen and ($item.shareAddr? | default '') == '') $"Wrong XHTTP inbound: ($item.remark)"
			ensure ($item.streamSettings.network == xhttp and $item.streamSettings.security == none and $item.streamSettings.xhttpSettings.path == $"/($paths.xhttpPath)" and ($item.streamSettings.externalProxy? | default [] | is-empty)) $"Wrong XHTTP transport: ($item.remark)"
			if $target.remark == Direct {
				ensure ($item.settings.decryption == none and $item.settings.encryption == none and $item.disableFlow == true) 'Direct XHTTP must use TLS without VLESS Encryption or Vision'
			} else {
				validate-vless-encryption $item.settings
				ensure ($item.disableFlow == false) 'CDN XHTTP must allow Vision flow'
			}
			ensure ('fallbacks' not-in $item.settings) 'XHTTP must omit protocol fallbacks; Caddy handles the masquerade site'
		}
	}
	no-failed-units
}

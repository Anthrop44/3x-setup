use common.nu *
use 3x-ui-api.nu *
use vless-encryption.nu *

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

export def apply [ctx: record] {
	with-panel $ctx {|session|
		let encryption = (select-vless-encryption (api $session /panel/api/server/getNewVlessEnc))
		let payloads = (inbound-payloads $ctx (open ($ctx.dir | path join paths.json)) $encryption)
		for payload in $payloads { api $session /panel/api/inbounds/add --data $payload | ignore }
	}
}

use common.nu *
use 3x-ui-api.nu *
use vless-encryption.nu *

export def inbound-payloads [ctx: record, paths: record, keys: record, short_id: string, obfs: string, encryption: record] {
	validate-vless-encryption $encryption
	let common = {enable: true, listen: '', port: 443, expiryTime: 0, total: 0, trafficReset: never, shareAddrStrategy: custom, shareAddr: $ctx.config.directDomain}
	let sniffing = {enabled: true, destOverride: [http tls quic], metadataOnly: false, routeOnly: false, ipsExcluded: [], domainsExcluded: []}
	let vless = {clients: [], decryption: none, encryption: none, fallbacks: []}
	[
		($common | merge {
			remark: QUIC, protocol: hysteria, subSortIndex: 1
			settings: {clients: [], address: $ctx.config.directDomain, port: 443, version: 2}
			streamSettings: {
				network: hysteria, security: tls
				hysteriaSettings: {version: 2, auth: '', udpIdleTimeout: 60}
				tlsSettings: {
					serverName: $ctx.config.directDomain, alpn: [h3]
					settings: {fingerprint: '', echConfigList: '', verifyPeerCertByName: '', pinnedPeerCertSha256: []}
					certificates: [{useFile: true, certificateFile: /etc/caddy/3x-direct-cert.pem, keyFile: /etc/caddy/3x-direct-key.pem, certificate: [], key: [], ocspStapling: 0, oneTimeLoading: false, usage: encipherment, buildChain: false}]
				}
				finalmask: {tcp: [], udp: [{type: salamander, settings: {password: $obfs}}]}
			}
			sniffing: ($sniffing | merge {enabled: false, destOverride: []})
		})
		($common | merge {
			remark: TCP, protocol: vless, subSortIndex: 2, settings: $vless, sniffing: $sniffing
			streamSettings: {
				network: tcp, security: reality, tcpSettings: {acceptProxyProtocol: false, header: {type: none}}
				realitySettings: {
					show: false, xver: 0, target: $"127.0.0.1:($ctx.constants.realityTargetPort)", serverNames: [$ctx.config.directDomain]
					privateKey: $keys.privateKey, minClientVer: '', maxClientVer: '', maxTimediff: 0, shortIds: [$short_id], mldsa65Seed: ''
					settings: {publicKey: $keys.publicKey, fingerprint: $ctx.constants.fingerprint, serverName: $ctx.config.directDomain, spiderX: '/', mldsa65Verify: ''}
				}
			}
		})
		($common | merge {
			remark: Cloudflare, protocol: vless, subSortIndex: 3, settings: ($vless | reject fallbacks | merge $encryption), sniffing: $sniffing
			listen: '127.0.0.1', port: $ctx.constants.xhttpPort, shareAddrStrategy: listen, shareAddr: ''
			streamSettings: {
				network: xhttp, security: none
				xhttpSettings: {
					path: $"/($paths.xhttpPath)", host: '', mode: auto, xPaddingBytes: '100-1000', xPaddingObfsMode: false
					xPaddingKey: '', xPaddingHeader: '', xPaddingPlacement: '', xPaddingMethod: '', sessionPlacement: '', sessionKey: ''
					seqPlacement: '', seqKey: '', uplinkDataPlacement: '', uplinkDataKey: '', scMaxEachPostBytes: '', noSSEHeader: false
					scMaxBufferedPosts: 30, scStreamUpServerSecs: '20-80', serverMaxHeaderBytes: 0, uplinkHTTPMethod: '', headers: {}
					scMinPostsIntervalMs: '', uplinkChunkSize: 0, noGRPCHeader: false
				}
			}
		})
	]
}

export def apply [ctx: record] {
	with-panel $ctx {|session|
		let keys = (api $session /panel/api/server/getNewX25519Cert)
		ensure (($keys.privateKey? | default '' | is-not-empty) and ($keys.publicKey? | default '' | is-not-empty)) 'Missing Reality keys'
		let encryption = (select-vless-encryption (api $session /panel/api/server/getNewVlessEnc))
		let payloads = (inbound-payloads $ctx (open ($ctx.dir | path join paths.json)) $keys (token) (token) $encryption)
		for payload in $payloads { api $session /panel/api/inbounds/add --data $payload | ignore }
	}
}

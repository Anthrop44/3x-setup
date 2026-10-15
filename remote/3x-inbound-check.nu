use common.nu *
use 3x-ui-api.nu *

export def verify [ctx: record] {
	let paths = (open ($ctx.dir | path join paths.json))
	with-panel $ctx {|session|
		let inbounds = (api $session /panel/api/inbounds/list)
		let hy = (inbound $inbounds QUIC)
		let tcp = (inbound $inbounds TCP)
		let cf = (inbound $inbounds Cloudflare)
		for item in [$hy $tcp $cf] { ensure $item.enable $"Disabled inbound: ($item.remark)" }
		for item in [$hy $tcp] { ensure ($item.port == 443 and $item.shareAddrStrategy == custom and $item.shareAddr == $ctx.config.directDomain) $"Wrong direct inbound: ($item.remark)" }
		ensure ($hy.protocol == hysteria and $hy.subSortIndex == 1 and $hy.settings.version == 2 and $hy.settings.address == $ctx.config.directDomain and $hy.settings.port == 443) 'Wrong Hysteria2 settings'
		let hs = $hy.streamSettings
		ensure ($hs.network == hysteria and $hs.security == tls and $hs.hysteriaSettings.version == 2 and $hs.hysteriaSettings.udpIdleTimeout == 60 and $hs.tlsSettings.serverName == $ctx.config.directDomain and 'h3' in $hs.tlsSettings.alpn) 'Wrong Hysteria2 transport'
		let cert = $hs.tlsSettings.certificates.0
		ensure ($cert.certificateFile == /etc/caddy/3x-direct-cert.pem and $cert.keyFile == /etc/caddy/3x-direct-key.pem and $cert.usage == encipherment) 'Wrong Hysteria2 certificate'
		ensure ($hs.finalmask.udp.0.type == salamander and ($hs.finalmask.udp.0.settings.password | str length) >= 16 and $hy.sniffing.enabled == false) 'Wrong Hysteria2 obfuscation'
		let rs = $tcp.streamSettings.realitySettings
		ensure ($tcp.protocol == vless and $tcp.subSortIndex == 2 and $tcp.streamSettings.network == tcp and $tcp.streamSettings.security == reality) 'Wrong Reality inbound'
		ensure (($rs.target? | default $rs.dest?) == $"127.0.0.1:($ctx.constants.realityTargetPort)" and $ctx.config.directDomain in $rs.serverNames and $rs.settings.fingerprint == $ctx.constants.fingerprint and ($rs.shortIds | is-not-empty) and ($rs.privateKey | is-not-empty) and ($rs.settings.publicKey | is-not-empty)) 'Wrong Reality settings'
		ensure ($cf.protocol == vless and $cf.subSortIndex == 3 and $cf.listen == '127.0.0.1' and $cf.port == $ctx.constants.xhttpPort and $cf.shareAddrStrategy == listen and ($cf.shareAddr? | default '') == '') 'Wrong XHTTP inbound'
		ensure ($cf.streamSettings.network == xhttp and $cf.streamSettings.security == none and $cf.streamSettings.xhttpSettings.path == $"/($paths.xhttpPath)" and ($cf.streamSettings.externalProxy? | default [] | is-empty)) 'Wrong XHTTP transport'
	}
	no-failed-units
}

use common.nu *
use 3x-ui-api.nu *
use vless-encryption.nu validate-vless-encryption

export def verify [ctx: record] {
	let paths = (open ($ctx.dir | path join paths.json))
	with-panel $ctx {|session|
		let inbounds = (api $session /panel/api/inbounds/list)
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

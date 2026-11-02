use ../modules/ech-preflight.nu [ech-query validate-response check-ech]
use ../remote/lib/core.nu [ensure with-temp write-json]

def word [n: int] { $n | into binary --endian big | bytes at 6..7 }

def answer [--flags: int = 33152, --owner: binary = 0x[c00c], --ech: binary] {
	let content = ([0x[00 0020 0020] (0..31 | each { 0x[00] } | bytes collect) 0x[0004 0001 0001 00 12] ('cloudflare-ech.com' | into binary) 0x[0000]] | bytes collect)
	let config = ([0x[fe0d] (word ($content | bytes length)) $content] | bytes collect)
	let ech = (if $ech == null { [(word ($config | bytes length)) $config] | bytes collect } else { $ech })
	let rdata = ([0x[0001 00 0005] (word ($ech | bytes length)) $ech] | bytes collect)
	[0x[0000] (word $flags) 0x[0001 0001 0000 0000] (ech-query cloudflare-ech.com | bytes at 12..) $owner 0x[0041 0001 0000012c] (word ($rdata | bytes length)) $rdata] | bytes collect
}

def rejected [body: closure] {
	ensure (try { do $body | ignore; false } catch { true }) 'Invalid DNS/ECH response was accepted'
}

export def test-ech-preflight [] {
	ensure ((validate-response (answer) cloudflare-ech.com) == 300) 'Compressed HTTPS response failed'
	let valid = (answer)
	for flags in [33155 33664] { rejected { validate-response (answer --flags $flags) cloudflare-ech.com } }
	for data in [0x[] ('<html>' | into binary) ($valid | bytes at ..<(($valid | bytes length) - 1))] { rejected { validate-response $data cloudflare-ech.com } }
	for value in [0x[] 0x[0005 0000 0001 00] 0x[0005 fe0d 0001 00] 0x[0006 fe0d 0001 00]] {
		rejected { validate-response (answer --ech $value) cloudflare-ech.com }
	}
	for owner in [0x[c024] 0x[03 626164 03 636f6d 00]] { rejected { validate-response (answer --owner $owner) cloudflare-ech.com } }
	rejected { validate-response (answer) wrong.example.com }
	# 连接本机关闭端口，验证真实预检失败路径，无需外部DNS或网络
	with-temp {|temp|
		mkdir ($temp | path join remote)
		let endpoint = $"https://127.0.0.1:(port)/dns-query"
		write-json ($temp | path join remote constants.json) {cdnEchConfigList: $"cloudflare-ech.com+($endpoint)"}
		let message = (try { check-ech $temp; '' } catch {|err| $err.msg })
		for detail in ['Local ECH preflight failed after 3 attempts' 'cloudflare-ech.com' $endpoint 'No files were uploaded and no remote commands were run' 'remote/constants.json' 'Cause:'] {
			ensure ($message | str contains $detail) $"Missing ECH failure context: ($detail)"
		}
	}
}

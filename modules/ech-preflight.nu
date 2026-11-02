use ../remote/lib/core.nu [ensure retry]

# 二进制读取均先检查边界，避免截断响应被当成零值
export def dns-bytes [data: binary, offset: int, count: int] {
	ensure ($offset >= 0 and $count >= 0 and $offset + $count <= ($data | bytes length)) 'Truncated DNS/ECH data'
	if $count == 0 { return 0x[] }
	$data | bytes at $offset..<($offset + $count)
}

def uint [data: binary, offset: int, count: int = 2] {
	dns-bytes $data $offset $count | into int --endian big
}

# DNS名称可含压缩指针，限制跳转次数并拒绝循环
export def dns-name [data: binary, start: int] {
	mut pos = $start
	mut end = -1
	mut seen = []
	mut labels = []
	loop {
		ensure ($pos not-in $seen and ($seen | length) < 128) 'Invalid DNS name pointer'
		$seen = ($seen | append $pos)
		let size = (uint $data $pos 1)
		$pos += 1
		if $size == 0 { return {name: ($labels | str join '.' | str lowercase), next: (if $end < 0 { $pos } else { $end })} }
		if ($size | bits and 192) == 192 {
			let low = (uint $data $pos 1)
			if $end < 0 { $end = $pos + 1 }
			$pos = ($size mod 64) * 256 + $low
		} else {
			ensure ($size <= 63) 'Invalid DNS label'
			$labels = ($labels | append (dns-bytes $data $pos $size | decode utf-8))
			$pos += $size
		}
	}
}

export def validate-ech [value: binary] {
	let total = ($value | bytes length)
	ensure ($total >= 6 and (uint $value 0) == $total - 2) 'Invalid ECHConfigList length'
	mut pos = 2
	mut supported = false
	while $pos < $total {
		let version = (uint $value $pos)
		let size = (uint $value ($pos + 2))
		$pos += 4
		let content = (dns-bytes $value $pos $size)
		ensure ($size > 0) 'Empty ECHConfig'
		if $version == 65037 {
			mut cursor = 3
			for field in ['public key' 'cipher suites'] {
				let length = (uint $content $cursor)
				$cursor += 2
				ensure ($length > 0) $"Invalid ECH ($field)"
				dns-bytes $content $cursor $length | ignore
				if $field == 'cipher suites' { ensure ($length mod 4 == 0) 'Invalid ECH cipher suites' }
				$cursor += $length
			}
			$cursor += 1
			let length = (uint $content $cursor 1)
			$cursor += 1
			ensure ($length > 0) 'Missing ECH public name'
			dns-bytes $content $cursor $length | decode utf-8 | ignore
			$cursor += $length
			let extensions = (uint $content $cursor)
			ensure ($cursor + 2 + $extensions == $size) 'Invalid ECH extensions length'
			$supported = true
		}
		$pos += $size
	}
	ensure $supported 'No supported ECHConfig version'
}

export def ech-query [domain: string] {
	let labels = ($domain | split row '.' | each {|label|
		let data = ($label | into binary)
		let size = ($data | bytes length)
		ensure ($size > 0 and $size <= 63) 'Invalid DNS label'
		[($size | into binary --endian little | bytes at 0..0) $data] | bytes collect
	} | bytes collect)
	[0x[0000 0100 0001 0000 0000 0000] $labels 0x[00 0041 0001]] | bytes collect
}

export def validate-response [data: binary, domain: string] {
	let flags = (uint $data 2)
	ensure ((uint $data 0) == 0 and ($flags | bits and 32768) != 0 and ($flags | bits and 527) == 0 and (uint $data 4) == 1) 'Invalid or unsuccessful DNS response'
	let question = (dns-name $data 12)
	ensure ($question.name == ($domain | str lowercase) and (uint $data $question.next) == 65 and (uint $data ($question.next + 2)) == 1) 'DNS question mismatch'
	mut pos = $question.next + 4
	let answers = (uint $data 6)
	for _ in (0..<$answers) {
		let owner = (dns-name $data $pos)
		$pos = $owner.next
		let kind = (uint $data $pos)
		let class = (uint $data ($pos + 2))
		let ttl = (uint $data ($pos + 4) 4)
		let size = (uint $data ($pos + 8))
		$pos += 10
		dns-bytes $data $pos $size | ignore
		let end = $pos + $size
		if $kind == 65 and $class == 1 and $owner.name == ($domain | str lowercase) {
			ensure ($size >= 3) 'Truncated HTTPS record'
			let priority = (uint $data $pos)
			let target = (dns-name $data ($pos + 2))
			mut cursor = $target.next
			ensure ($cursor <= $end) 'Truncated HTTPS target'
			while $cursor < $end and $priority != 0 {
				ensure ($cursor + 4 <= $end) 'Truncated HTTPS parameter'
				let key = (uint $data $cursor)
				let length = (uint $data ($cursor + 2))
				$cursor += 4
				ensure ($cursor + $length <= $end) 'Truncated HTTPS parameter'
				if $key == 5 { validate-ech (dns-bytes $data $cursor $length); return $ttl }
				$cursor += $length
			}
		}
		$pos = $end
	}
	error make {msg: 'No ECHConfigList in HTTPS answers'}
}

# 仅本地直连配置中的DoH，在任何上传和远端操作前校验ECH记录
export def check-ech [project: string] {
	let parts = (open ($project | path join remote constants.json) | get cdnEchConfigList | split row '+' --number 2)
	let query = (ech-query $parts.0)
	let ttl = (try { with-env {http_proxy: '', https_proxy: '', all_proxy: '', HTTP_PROXY: '', HTTPS_PROXY: '', ALL_PROXY: '', no_proxy: '*', NO_PROXY: '*'} {
		retry 3 2sec {
			let response = (http post --raw --full --redirect-mode error --max-time 15sec --content-type application/dns-message --headers {Accept: application/dns-message} $parts.1 $query)
			ensure ($response.status == 200) 'DoH expected HTTP 200'
			let types = ($response.headers.response | where {|header| ($header.name | str lowercase) == 'content-type' } | get value)
			ensure ($types | any {|value| ($value | str lowercase | split row ';' | first | str trim) == 'application/dns-message' }) 'DoH expected application/dns-message'
			validate-response ($response.body | into binary) $parts.0
		}
	} } catch {|err|
		error make {msg: $"Local ECH preflight failed after 3 attempts.\nQuery: ($parts.0) HTTPS record\nDoH endpoint: ($parts.1)\nNo files were uploaded and no remote commands were run.\nCheck direct access to this DoH endpoint from your local network and the cdnEchConfigList setting in remote/constants.json. Environment proxy settings are ignored for this check.\nCause: ($err.msg)"}
	})
	print $"Local ECH preflight passed: ($parts.0), TTL=($ttl)s \(environment proxies disabled\)"
}

use core.nu [capture ensure]

# 使用带超时、重定向和HTTP错误检查的curl获取文本
export def curl-text [...args: any] {
	capture -- curl --fail --silent --show-error --location --connect-timeout 20 --max-time 120 ...$args
}

# 判断指定TCP或UDP端口是否监听，可限定为回环地址
export def listening [port: int, --udp, --local] {
	let rows = (capture -- ss -H (if $udp { '-lnu' } else { '-lnt' }) | lines | each { split row --regex '\s+' })
	$rows | any {|row|
		let addr = ($row | get 3)
		($addr ends-with $":($port)") and (not $local or $addr in [$"127.0.0.1:($port)" $"[::1]:($port)"])
	}
}

# 确保指定TCP端口已监听且所有监听地址均为回环地址
export def only-loopback [port: int] {
	let addresses = (capture -- ss -H -lnt | lines | each { split row --regex '\s+' | get 3 } | where {|addr| $addr ends-with $":($port)" })
	ensure (($addresses | is-not-empty) and ($addresses | all {|addr| $addr in [$"127.0.0.1:($port)" $"[::1]:($port)"] })) $"Port ($port) must listen only on loopback"
}

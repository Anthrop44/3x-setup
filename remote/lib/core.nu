# Shared commands have no side effects when imported

# 条件不成立时抛出指定错误
export def ensure [condition: bool, message: string] {
	if not $condition { error make {msg: $message} }
}

# 执行外部命令，保留输出并在退出码非零时抛错
# 不依赖LAST_EXIT_CODE从闭包或模块中传出
export def checked [command: string, ...args: any] {
	^$command ...$args
	let code = $env.LAST_EXIT_CODE
	ensure ($code == 0) $"($command) failed with exit code ($code)"
}

# 执行外部命令并返回标准输出，失败时附带标准错误抛错
export def capture [command: string, ...args: any] {
	let result = (^$command ...$args | complete)
	ensure ($result.exit_code == 0) $"($command) failed with exit code ($result.exit_code): ($result.stderr)"
	$result.stdout
}

# 检查当前用户是否为root，否则抛错
export def root-required [] {
	ensure ((capture -- id -u | str trim) == '0') 'This command must run as root'
}

# 将JSON字符串解析为Nu值，已解析的值原样返回
export def decode-json [value: any] {
	if ($value | describe) == string { $value | from json } else { $value }
}

# 将值序列化为缩进JSON并覆盖写入文件
export def write-json [path: string, value: any] {
	$value | to json --indent 2 | save --force $path
}

# 通过同目录临时文件原子替换JSON文件，并设置权限为600
export def atomic-json [path: string, value: any] {
	let temp = $"($path).(random uuid).tmp"
	try {
		write-json $temp $value
		checked -- chmod 600 $temp
		mv --force $temp $path
	} catch {|err|
		rm --force $temp
		error make {msg: $err.msg}
	}
}

# 创建临时目录供闭包使用，无论成功或失败都清理目录
export def with-temp [body: closure] {
	let temp = (mktemp --directory)
	try {
		let result = (do $body $temp)
		rm --recursive --force $temp
		$result
	} catch {|err|
		rm --recursive --force $temp
		error make {msg: $err.msg}
	}
}

# 使用OpenSSL生成指定字节数的随机十六进制字符串
export def token [bytes: int = 8] {
	capture -- openssl rand -hex $bytes | str trim
}

# 按指定间隔重试闭包并返回成功结果，耗尽次数后抛错
export def retry [attempts: int, delay: duration, body: closure] {
	mut last = ''
	for index in 1..$attempts {
		let result = (try { {ok: true, value: (do $body)} } catch {|err| {ok: false, message: $err.msg} })
		if $result.ok { return $result.value }
		$last = $result.message
		if $index < $attempts { sleep $delay }
	}
	error make {msg: $"Retry limit reached: ($last)"}
}

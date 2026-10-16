# Shared commands have no side effects when imported
export def ensure [condition: bool, message: string] {
	if not $condition { error make {msg: $message} }
}

# Never rely on LAST_EXIT_CODE leaking out of a closure/module
export def checked [command: string, ...args: any] {
	^$command ...$args
	let code = $env.LAST_EXIT_CODE
	ensure ($code == 0) $"($command) failed with exit code ($code)"
}

export def capture [command: string, ...args: any] {
	let result = (^$command ...$args | complete)
	ensure ($result.exit_code == 0) $"($command) failed with exit code ($result.exit_code): ($result.stderr)"
	$result.stdout
}

export def root-required [] {
	ensure ((capture -- id -u | str trim) == '0') 'This command must run as root'
}

export def decode-json [value: any] {
	if ($value | describe) == string { $value | from json } else { $value }
}

export def write-json [path: string, value: any] {
	$value | to json --indent 2 | save --force $path
}

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

export def token [bytes: int = 8] {
	capture -- openssl rand -hex $bytes | str trim
}

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

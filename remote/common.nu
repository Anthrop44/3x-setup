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

export def curl-text [...args: any] {
	capture -- curl --fail --silent --show-error --location --connect-timeout 20 --max-time 120 ...$args
}

export def no-failed-units [] {
	let failed = (capture -- systemctl --failed --no-legend --plain | str trim)
	ensure ($failed | is-empty) $"Failed systemd units: ($failed)"
}

export def daily-time [hour: int] {
	$"($hour | fill --alignment right --character '0' --width 2):00:00"
}

export def install-timer [name: string, command: string, hour: int] {
	$'[Unit]
Description=3x-setup ($name)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=($command)
' | save --force $"/etc/systemd/system/($name).service"
	$'[Unit]
Description=3x-setup ($name) daily

[Timer]
OnCalendar=*-*-* (daily-time $hour)
RandomizedDelaySec=1h
Persistent=true
Unit=($name).service

[Install]
WantedBy=timers.target
' | save --force $"/etc/systemd/system/($name).timer"
	checked -- systemctl daemon-reload
	checked -- systemctl enable --now $"($name).timer"
}

export def check-timer [name: string, hour: int] {
	checked -- systemctl is-enabled --quiet $"($name).timer"
	checked -- systemctl is-active --quiet $"($name).timer"
	let unit = (capture -- systemctl cat $"($name).timer" | lines)
	ensure ($"OnCalendar=*-*-* (daily-time $hour)" in $unit) $"Wrong timer schedule: ($name)"
	ensure ('RandomizedDelaySec=1h' in $unit) $"Wrong timer delay: ($name)"
}

export def listening [port: int, --udp, --local] {
	let rows = (capture -- ss -H (if $udp { '-lnu' } else { '-lnt' }) | lines | each { split row --regex '\s+' })
	$rows | any {|row|
		let addr = ($row | get 3)
		($addr ends-with $":($port)") and (not $local or $addr in [$"127.0.0.1:($port)" $"[::1]:($port)"])
	}
}

export def only-loopback [port: int] {
	let addresses = (capture -- ss -H -lnt | lines | each { split row --regex '\s+' | get 3 } | where {|addr| $addr ends-with $":($port)" })
	ensure (($addresses | is-not-empty) and ($addresses | all {|addr| $addr in [$"127.0.0.1:($port)" $"[::1]:($port)"] })) $"Port ($port) must listen only on loopback"
}

export def context [directory: string, no_tls: bool, no_app: bool] {
	{dir: $directory, config: (open ($directory | path join config.json)), constants: (open ($directory | path join constants.json)), noTLS: $no_tls, noAPP: $no_app}
}

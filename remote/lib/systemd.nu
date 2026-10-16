use core.nu [capture checked ensure]

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

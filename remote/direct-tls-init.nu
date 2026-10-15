use common.nu *
use caddyfile-common.nu install-caddyfile
use direct-tls-sync.nu sync-certificate

export def apply [ctx: record] {
	if $ctx.noTLS { print 'Skipping ACME and certificate sync (--noTLS)'; return }
	install-caddyfile $ctx --acme
	retry 60 5sec {
		curl-text -- --max-time 20 --resolve $"($ctx.config.directDomain):($ctx.constants.realityTargetPort):127.0.0.1" $"https://($ctx.config.directDomain):($ctx.constants.realityTargetPort)/" | ignore
		sync-certificate $ctx.config.directDomain
	}
	install-timer 3x-direct-tls-sync '/usr/local/sbin/3x-sync-direct-tls --sync' $ctx.constants.dailyTaskHour
	checked -- systemctl start 3x-direct-tls-sync.service
}

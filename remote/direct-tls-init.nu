use common.nu *
use caddyfile-common.nu install-caddyfile
use direct-tls-common.nu [certificate-files validate-certificate]

export def apply [ctx: record] {
	if $ctx.noTLS { print 'Skipping ACME (--noTLS)'; return }
	install-caddyfile $ctx --acme
	let files = (certificate-files $ctx.config.directDomain)
	retry 60 5sec {
		curl-text -- --max-time 20 --resolve $"($ctx.config.directDomain):443:127.0.0.1" $"https://($ctx.config.directDomain)/" | ignore
		validate-certificate $files.cert $files.key $ctx.config.directDomain --public
	}
}

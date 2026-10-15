use common.nu *

export def verify [ctx: record] {
	checked -- systemctl is-active --quiet caddy
	checked -- caddy validate --config /etc/caddy/Caddyfile
	for cert in [/etc/caddy/3x-origin-cert.pem /etc/caddy/3x-direct-cert.pem] { checked -- openssl x509 -in $cert -noout -subject -issuer -dates }
	curl-text -- $"http://127.0.0.1:($ctx.constants.fakeSitePort)/" | ignore
	curl-text -- -k --resolve $"($ctx.config.directDomain):($ctx.constants.realityTargetPort):127.0.0.1" $"https://($ctx.config.directDomain):($ctx.constants.realityTargetPort)/" | ignore
}

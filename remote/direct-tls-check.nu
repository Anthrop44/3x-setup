use common.nu *
use direct-tls-sync.nu [validate-certificate sync-certificate]

export def verify [ctx: record] {
	checked -- systemctl is-active --quiet caddy
	checked -- systemctl is-active --quiet x-ui
	checked -- caddy validate --config /etc/caddy/Caddyfile
	validate-certificate /etc/caddy/3x-direct-cert.pem /etc/caddy/3x-direct-key.pem $ctx.config.directDomain --public=(not $ctx.noTLS)
	if not $ctx.noTLS {
		check-timer 3x-direct-tls-sync $ctx.constants.dailyTaskHour
		sync-certificate $ctx.config.directDomain --check
	}
	let index = (open --raw /var/www/3x-fake-site/index.html)
	let direct = $ctx.config.directDomain
	let cdn = $ctx.config.cdnDomain
	let headers = (curl-text -- -I --no-location --resolve $"($direct):80:127.0.0.1" $"http://($direct)/")
	let redirect = ($headers | lines | where {|s| $s =~ '(?i)^location:' } | each {|s| $s | split row ':' --number 2 | last | str trim })
	ensure ($redirect == [$"https://($direct)/"]) 'HTTP redirect does not preserve host'
	let probes = [
		{url: $"http://127.0.0.1:($ctx.constants.fakeSitePort)/", args: []}
		{url: $"https://($direct):($ctx.constants.realityTargetPort)/", args: [--resolve $"($direct):($ctx.constants.realityTargetPort):127.0.0.1"]}
		{url: $"https://($direct)/", args: [--resolve $"($direct):443:127.0.0.1"]}
		{url: $"https://probe.invalid:($ctx.config.cdnPort)/", args: [--resolve $"probe.invalid:($ctx.config.cdnPort):127.0.0.1"]}
		{url: $"https://($cdn):($ctx.config.cdnPort)/", args: [--resolve $"($cdn):($ctx.config.cdnPort):127.0.0.1"]}
	]
	for probe in $probes {
		ensure ((curl-text -- -k ...$probe.args $probe.url) == $index) $"Masquerade site mismatch: ($probe.url)"
		print $"Masquerade site OK: ($probe.url)"
	}
	if not $ctx.noTLS { curl-text -- --resolve $"($direct):($ctx.constants.realityTargetPort):127.0.0.1" $"https://($direct):($ctx.constants.realityTargetPort)/" | ignore }
	no-failed-units
}

use common.nu *
use direct-tls-common.nu [certificate-files validate-certificate]

export def verify [ctx: record] {
	checked -- systemctl is-active --quiet caddy
	checked -- systemctl is-active --quiet x-ui
	checked -- caddy validate --config /etc/caddy/Caddyfile
	# Config synchronization uses --noTLS even after ACME; inspect the active certificate source
	let acme = (open --raw /etc/caddy/Caddyfile | str contains 'issuer acme')
	let files = (if $acme { certificate-files $ctx.config.directDomain } else { {cert: /etc/caddy/3x-direct-cert.pem, key: /etc/caddy/3x-direct-key.pem} })
	validate-certificate $files.cert $files.key $ctx.config.directDomain --public=$acme
	let index = (open --raw /var/www/3x-fake-site/index.html)
	let direct = $ctx.config.directDomain
	let cdn = $ctx.config.cdnDomain
	let headers = (curl-text -- -I --no-location --resolve $"($direct):80:127.0.0.1" $"http://($direct)/")
	let redirect = ($headers | lines | where {|s| $s =~ '(?i)^location:' } | each {|s| $s | split row ':' --number 2 | last | str trim })
	ensure ($redirect == [$"https://($direct)/"]) 'HTTP redirect does not preserve host'
	let probes = [
		{url: $"http://127.0.0.1:($ctx.constants.fakeSitePort)/", args: []}
		{url: $"https://($direct)/", args: [--resolve $"($direct):443:127.0.0.1"]}
		{url: $"https://probe.invalid:($ctx.config.cdnPort)/", args: [--resolve $"probe.invalid:($ctx.config.cdnPort):127.0.0.1"]}
		{url: $"https://($cdn):($ctx.config.cdnPort)/", args: [--resolve $"($cdn):($ctx.config.cdnPort):127.0.0.1"]}
	]
	for probe in $probes {
		ensure ((curl-text -- -k ...$probe.args $probe.url) == $index) $"Masquerade site mismatch: ($probe.url)"
		print $"Masquerade site OK: ($probe.url)"
	}
	if $acme { curl-text -- --resolve $"($direct):443:127.0.0.1" $"https://($direct)/" | ignore }
	no-failed-units
}

use ../../lib/core.nu *
use ../../lib/network.nu curl-text
use ../../lib/systemd.nu no-failed-units
use config.nu install-caddyfile

export def validate-certificate [cert: string, key: string, domain: string, --public] {
	checked -- openssl x509 -in $cert -noout -checkend 0
	ensure ((capture -- openssl x509 -in $cert -noout -checkhost $domain) | str contains ' does match certificate') 'Certificate hostname mismatch'
	let certificate_key = (capture -- openssl x509 -in $cert -pubkey -noout | str trim)
	let private_key = (capture -- openssl pkey -in $key -pubout | str trim)
	ensure ($certificate_key == $private_key) 'Certificate and private key do not match'
	if $public {
		let info = (capture -- openssl x509 -in $cert -noout -subject -issuer)
		let rows = ($info | lines | each {|line| $line | split row '=' --number 2 | last })
		ensure (($rows | length) == 2 and $rows.0 != $rows.1 and $info !~ '(?i)CloudFlare Origin|STAGING|Fake LE') 'Not a production public certificate'
		checked -- openssl verify -purpose sslserver -verify_hostname $domain -untrusted $cert $cert
	}
}

export def certificate-files [domain: string] {
	let base = $"/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/($domain)"
	{cert: $"($base)/($domain).crt", key: $"($base)/($domain).key"}
}

export def apply [ctx: record] {
	if $ctx.noTLS { print 'Skipping ACME (--noTLS)'; return }
	install-caddyfile $ctx --acme
	let files = (certificate-files $ctx.config.directDomain)
	retry 60 5sec {
		curl-text -- --max-time 20 --resolve $"($ctx.config.directDomain):443:127.0.0.1" $"https://($ctx.config.directDomain)/" | ignore
		validate-certificate $files.cert $files.key $ctx.config.directDomain --public
	}
}

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

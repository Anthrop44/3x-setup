use common.nu *

export def render-caddyfile [ctx: record, --acme] {
	let paths = (open ($ctx.dir | path join paths.json))
	let tls = (if $acme { "tls {\n\t\tissuer acme {\n\t\t\tdisable_tlsalpn_challenge\n\t\t}\n\t}" } else { 'tls /etc/caddy/3x-direct-cert.pem /etc/caddy/3x-direct-key.pem' })
	let values = {
		AUTO_HTTPS_CONFIG: (if $acme { 'auto_https disable_redirects ignore_loaded_certs' } else { 'auto_https disable_redirects' })
		DIRECT_DOMAIN: $ctx.config.directDomain
		CDN_DOMAIN: $ctx.config.cdnDomain
		CDN_PORT: $ctx.config.cdnPort
		SUBSCRIPTION_URI_PATH: $ctx.config.subscriptionPath
		SUBSCRIPTION_PORT: $ctx.constants.subscriptionPort
		XHTTP_PATH: $paths.xhttpPath
		XHTTP_PORT: $ctx.constants.xhttpPort
		FAKE_SITE_PORT: $ctx.constants.fakeSitePort
		REALITY_TARGET_PORT: $ctx.constants.realityTargetPort
		DIRECT_DOMAIN_TLS_CONFIG: $tls
	}
	mut content = (open --raw ($ctx.dir | path join Caddyfile.template))
	for entry in ($values | transpose key value) { $content = ($content | str replace --all $"{{($entry.key)}}" ($entry.value | into string)) }
	ensure (not ($content =~ '\{\{[A-Z_]+\}\}')) 'Unresolved Caddyfile placeholder'
	$content
}

export def install-caddyfile [ctx: record, --acme] {
	render-caddyfile $ctx --acme=$acme | save --force /etc/caddy/Caddyfile
	checked -- caddy fmt --overwrite /etc/caddy/Caddyfile
	checked -- caddy validate --config /etc/caddy/Caddyfile
	try { checked -- systemctl reload caddy } catch { checked -- systemctl restart caddy }
}

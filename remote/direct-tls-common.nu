use common.nu *

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

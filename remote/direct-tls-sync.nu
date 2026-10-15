#!/usr/bin/env nu
const FILE = path self
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

export def sync-certificate [domain: string, --check] {
	let base = $"/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/($domain)"
	let cert = $"($base)/($domain).crt"
	let key = $"($base)/($domain).key"
	validate-certificate $cert $key $domain --public
	let target_cert = '/etc/caddy/3x-direct-cert.pem'
	let target_key = '/etc/caddy/3x-direct-key.pem'
	let same = (try { (open --raw $cert) == (open --raw $target_cert) and (open --raw $key) == (open --raw $target_key) } catch { false })
	if $check { ensure $same 'Xray certificate is not synchronized'; return }
	if $same { print 'Xray certificate already synchronized'; return }
	let cert_temp = $"/etc/caddy/.3x-cert-(random uuid)"
	let key_temp = $"/etc/caddy/.3x-key-(random uuid)"
	try {
		checked -- install -m 644 -o caddy -g caddy $cert $cert_temp
		checked -- install -m 640 -o caddy -g caddy $key $key_temp
		validate-certificate $cert_temp $key_temp $domain --public
		mv --force $cert_temp $target_cert
		mv --force $key_temp $target_key
		checked -- systemctl restart x-ui
		checked -- systemctl is-active --quiet x-ui
	} catch {|err|
		rm --force $cert_temp $key_temp
		error make {msg: $err.msg}
	}
}

def main [--check, --sync, --locked] {
	root-required
	if not $locked {
		let mode = (if $check { '--check' } else { '--sync' })
		let result = (^flock --nonblock --conflict-exit-code 75 /run/3x-direct-tls-sync.lock nu --no-config-file $FILE --locked $mode | complete)
		if $result.exit_code == 75 { ensure (not $check) 'Certificate sync is busy'; return }
		print $result.stdout
		ensure ($result.exit_code == 0) $result.stderr
		return
	}
	let cfg = (open ($FILE | path dirname | path join config.json))
	sync-certificate $cfg.directDomain --check=$check
}

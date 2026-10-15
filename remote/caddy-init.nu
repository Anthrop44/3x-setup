use common.nu *
use caddyfile-common.nu install-caddyfile

export def apply [ctx: record] {
	write-json ($ctx.dir | path join paths.json) {xhttpPath: (token 10)}
	checked -- apt-get -o DPkg::Lock::Timeout=600 install -y debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl gnupg
	with-temp {|temp|
		curl-text -- https://dl.cloudsmith.io/public/caddy/stable/gpg.key | save ($temp | path join caddy.key)
		checked -- gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg ($temp | path join caddy.key)
	}
	curl-text -- https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | save --force /etc/apt/sources.list.d/caddy-stable.list
	checked -- chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
	checked -- apt-get -o DPkg::Lock::Timeout=600 update
	checked -- apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y caddy
	checked -- install -d -m 755 -o caddy -g caddy /var/www/3x-fake-site
	checked -- cp -a $"($ctx.dir)/fake-site/." /var/www/3x-fake-site/
	checked -- find /var/www/3x-fake-site -type d -exec chmod 755 '{}' '+'
	checked -- find /var/www/3x-fake-site -type f -exec chmod 644 '{}' '+'
	checked -- chown -R caddy:caddy /var/www/3x-fake-site
	checked -- install -m 644 -o caddy -g caddy ($ctx.dir | path join cert.pem) /etc/caddy/3x-origin-cert.pem
	checked -- install -m 640 -o caddy -g caddy ($ctx.dir | path join key.pem) /etc/caddy/3x-origin-key.pem
	with-temp {|temp|
		let cert = ($temp | path join cert.pem)
		let key = ($temp | path join key.pem)
		checked -- openssl req -x509 -nodes -newkey rsa:2048 -days 30 -keyout $key -out $cert -subj $"/CN=($ctx.config.directDomain)" -addext $"subjectAltName=DNS:($ctx.config.directDomain)"
		checked -- install -m 644 -o caddy -g caddy $cert /etc/caddy/3x-direct-cert.pem
		checked -- install -m 640 -o caddy -g caddy $key /etc/caddy/3x-direct-key.pem
	}
	install-caddyfile $ctx
	checked -- systemctl enable caddy
}

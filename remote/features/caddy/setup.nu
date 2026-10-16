use ../../lib/core.nu *
use ../../lib/network.nu [curl-text listening]
use config.nu install-caddyfile

# 安装Caddy、伪装站和初始证书，生成XHTTP路径并配置服务
export def apply [ctx: record] {
	write-json $ctx.paths.state {xhttpPath: (token 10)}
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

# 检查Caddy服务、配置、初始证书、站点和HTTPS监听
export def verify [ctx: record] {
	checked -- systemctl is-active --quiet caddy
	checked -- caddy validate --config /etc/caddy/Caddyfile
	for cert in [/etc/caddy/3x-origin-cert.pem /etc/caddy/3x-direct-cert.pem] { checked -- openssl x509 -in $cert -noout -subject -issuer -dates }
	curl-text -- $"http://127.0.0.1:($ctx.constants.fakeSitePort)/" | ignore
	ensure (listening 443) 'Caddy HTTPS is not listening on 443/tcp'
	ensure (listening 443 --udp) 'Caddy HTTP/3 is not listening on 443/udp'
	curl-text -- -k --resolve $"($ctx.config.directDomain):443:127.0.0.1" $"https://($ctx.config.directDomain)/" | ignore
}

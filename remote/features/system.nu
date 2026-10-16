use ../lib/core.nu *
use ../lib/network.nu [curl-text listening]
use ../lib/systemd.nu [install-timer check-timer]

def install-command [name: string, script: string] {
	$'#!/usr/bin/nu --no-config-file
def --wrapped main [...args: string] {
	exec /usr/bin/nu --no-config-file ($script | to nuon) ...$args
}
' | save --force $"/usr/local/sbin/($name)"
	checked -- chmod 755 $"/usr/local/sbin/($name)"
}

export def provision [ctx: record] {
	checked -- apt-get update
	checked -- apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y
	checked -- apt-get install -y openssl openssh-server curl ca-certificates ufw procps sqlite3 iproute2 util-linux
	checked -- chown -R root:root $ctx.dir
	checked -- chmod 700 $ctx.dir
	for file in (glob ($ctx.dir | path join '*') | where {|p| ($p | path type) == file }) { checked -- chmod 600 $file }
	checked -- ssh-keygen -l -f ($ctx.dir | path join id_ed25519.pub)
	checked -- install -d -m 700 -o root -g root /root/.ssh
	checked -- install -m 600 -o root -g root ($ctx.dir | path join id_ed25519.pub) /root/.ssh/authorized_keys
	install-command 3x-fetch-apps ($ctx.paths.jobs | path join fetch-apps.nu)
}

export def ssh-policy [port: int, --config: string = '/etc/ssh/sshd_config', --connection: string = 'user=root,host=localhost,addr=127.0.0.1'] {
	let effective = (capture -- sshd -T -f $config -C $connection | lines)
	for expected in [$"port ($port)" 'pubkeyauthentication yes' 'authenticationmethods publickey' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'permitemptypasswords no' 'authorizedkeysfile .ssh/authorized_keys'] {
		ensure ($expected in $effective) $"Unexpected effective SSH policy; expected ($expected)"
	}
	ensure (('permitrootlogin prohibit-password' in $effective) or ('permitrootlogin without-password' in $effective)) 'Unexpected PermitRootLogin policy'
}

export def ssh-config [port: int] {
	$'Port ($port)
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
AuthorizedKeysFile .ssh/authorized_keys
'
}

export def prioritize-ssh-include [content: string, include: string] {
	let retained = ($content | lines | where {|line| ($line | str trim) != $"Include ($include)" } | str join "\n")
	$"Include ($include)\n($retained)\n"
}

export def apply [ctx: record] {
	let cfg = $ctx.config
	checked -- ssh-keygen -l -f /root/.ssh/authorized_keys
	mkdir /etc/ssh/sshd_config.d
	let include = '/etc/ssh/sshd_config.d/00-3x-setup.conf'
	ssh-config $cfg.sshPort | save --force $include
	checked -- chmod 644 $include
	prioritize-ssh-include (open --raw /etc/ssh/sshd_config) $include | save --force /etc/ssh/sshd_config
	checked -- sshd -t
	ssh-policy $cfg.sshPort
	if ($env.SSH_CONNECTION? | default '' | is-not-empty) {
		let parts = ($env.SSH_CONNECTION | split row ' ')
		ssh-policy $cfg.sshPort --connection $"user=root,host=($parts.0),addr=($parts.0),laddr=($parts.2),lport=($cfg.sshPort)"
	}
	try { checked -- systemctl restart ssh } catch { checked -- systemctl restart sshd }
	checked -- ufw default deny incoming
	checked -- ufw default allow outgoing
	for rule in [80/tcp 443/tcp 443/udp $"($cfg.sshPort)/tcp"] { checked -- ufw allow $rule }
	install-timer 3x-cloudflare-ufw $"/usr/bin/nu --no-config-file ($ctx.paths.jobs | path join cloudflare-ufw.nu)" $ctx.constants.dailyTaskHour
	checked -- systemctl start 3x-cloudflare-ufw.service
	try { checked -- modprobe tcp_bbr } catch { }
	ensure ((capture -- sysctl net.ipv4.tcp_available_congestion_control) =~ '\bbbr\b') 'Kernel does not support BBR'
	"net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" | save --force /etc/sysctl.d/99-3x-bbr.conf
	checked -- sysctl -w net.core.default_qdisc=fq
	checked -- sysctl -w net.ipv4.tcp_congestion_control=bbr
}

export def verify [ctx: record] {
	try { checked -- systemctl is-active --quiet ssh } catch { checked -- systemctl is-active --quiet sshd }
	ssh-policy $ctx.config.sshPort
	let firewall = (capture -- ufw status verbose)
	print $firewall
	for pattern in ['(?m)^Status: active' '(?m)^443/tcp\s+ALLOW IN' '(?m)^443/udp\s+ALLOW IN'] { ensure ($firewall =~ $pattern) 'Unexpected UFW policy' }
	ensure ((capture -- ufw status numbered) | str contains $"($ctx.config.cdnPort)/tcp") 'Missing Cloudflare rules'
	check-timer 3x-cloudflare-ufw $ctx.constants.dailyTaskHour
	ensure ((capture -- sysctl -n net.ipv4.tcp_congestion_control | str trim) == bbr) 'BBR is not enabled'
	ensure ((capture -- sysctl -n net.core.default_qdisc | str trim) == fq) 'fq is not enabled'
	ensure (listening $ctx.config.sshPort) 'SSH port is not listening'
}

export def parse-networks [content: string] {
	let networks = ($content | lines | each { str trim } | where {|s| $s != '' } | uniq)
	ensure ($networks | is-not-empty) 'Empty Cloudflare network list; keeping current rules'
	for network in $networks {
		ensure ($network =~ '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9A-Fa-f:]+/[0-9]{1,3}$') 'Invalid Cloudflare network; keeping current rules'
	}
	$networks
}

export def refresh-firewall [cfg: record] {
	let networks = (parse-networks $"(curl-text -- --retry 3 https://www.cloudflare.com/ips-v4)\n(curl-text -- --retry 3 https://www.cloudflare.com/ips-v6)")
	let rules = (capture -- ufw status numbered | lines | where {|s| ($s | str contains '3x-cloudflare-cdn') and ($s | str contains $"($cfg.cdnPort)/tcp") } | parse --regex '^\[\s*(?P<id>\d+)\]' | get id | into int | sort --reverse)
	for id in $rules { checked -- ufw --force delete $id }
	for network in $networks { checked -- ufw allow proto tcp from $network to any port $cfg.cdnPort comment 3x-cloudflare-cdn }
	checked -- ufw --force enable
}

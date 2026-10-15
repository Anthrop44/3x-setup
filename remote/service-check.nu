use common.nu *
use check-common.nu ssh-policy

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

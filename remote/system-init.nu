use common.nu *
use check-common.nu *

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
	install-timer 3x-cloudflare-ufw '/usr/bin/nu --no-config-file /root/3x-setup/cloudflare-ufw.nu' $ctx.constants.dailyTaskHour
	checked -- systemctl start 3x-cloudflare-ufw.service
	try { checked -- modprobe tcp_bbr } catch { }
	ensure ((capture -- sysctl net.ipv4.tcp_available_congestion_control) =~ '\bbbr\b') 'Kernel does not support BBR'
	"net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" | save --force /etc/sysctl.d/99-3x-bbr.conf
	checked -- sysctl -w net.core.default_qdisc=fq
	checked -- sysctl -w net.ipv4.tcp_congestion_control=bbr
}

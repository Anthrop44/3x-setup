#!/usr/bin/env nu
const FILE = path self
use common.nu *

export def parse-networks [content: string] {
	let networks = ($content | lines | each { str trim } | where {|s| $s != '' } | uniq)
	ensure ($networks | is-not-empty) 'Empty Cloudflare network list; keeping current rules'
	for network in $networks {
		ensure ($network =~ '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$|^[0-9A-Fa-f:]+/[0-9]{1,3}$') 'Invalid Cloudflare network; keeping current rules'
	}
	$networks
}

def main [--locked] {
	root-required
	if not $locked {
		let result = (^flock --nonblock --conflict-exit-code 75 /run/3x-cloudflare-ufw.lock nu --no-config-file $FILE --locked | complete)
		if $result.exit_code == 75 { return }
		print $result.stdout
		ensure ($result.exit_code == 0) $result.stderr
		return
	}
	let cfg = (open ($FILE | path dirname | path join config.json))
	let networks = (parse-networks $"(curl-text -- --retry 3 https://www.cloudflare.com/ips-v4)\n(curl-text -- --retry 3 https://www.cloudflare.com/ips-v6)")
	let rules = (capture -- ufw status numbered | lines | where {|s| ($s | str contains '3x-cloudflare-cdn') and ($s | str contains $"($cfg.cdnPort)/tcp") } | parse --regex '^\[\s*(?P<id>\d+)\]' | get id | into int | sort --reverse)
	for id in $rules { checked -- ufw --force delete $id }
	for network in $networks { checked -- ufw allow proto tcp from $network to any port $cfg.cdnPort comment 3x-cloudflare-cdn }
	checked -- ufw --force enable
}

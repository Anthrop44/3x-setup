use common.nu *

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

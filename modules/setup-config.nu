use ../remote/lib/core.nu [ensure token write-json]
use ../remote/lib/config.nu validate-config

# 校验并保存配置，补齐缺失字段；初次部署时生成订阅路径和SSH端口
export def prepare-config [project: string, --initial] {
	let remote = ($project | path join remote)
	mut config = (open ($remote | path join config.json))
	let constants = (open ($remote | path join constants.json))
	validate-config $config $constants
	if $initial and 'subscriptionPath' not-in $config { $config = ($config | insert subscriptionPath (token)) }
	if 'distributionPath' not-in $config { $config = ($config | insert distributionPath (token | str substring 0..<15)) }
	$config = ($config | update clients {|cfg| $cfg.clients | each {|c|
		let client = (if 'path' in $c { $c } else { $c | insert path (token) })
		if 'password' in $client { $client } else { $client | insert password (random int 0..99999999 | into string | fill --alignment right --character '0' --width 8) }
	} })
	if $initial and 'sshPort' not-in $config {
		let ports = [$constants.directXhttpPort $constants.fakeSitePort $constants.xhttpPort $constants.subscriptionPort $constants.'3xpanelPort' $config.cdnPort]
		mut selected = (random int 10001..65535)
		while $selected in $ports { $selected = (random int 10001..65535) }
		$config = ($config | insert sshPort $selected)
	}
	validate-config $config $constants --complete
	write-json ($remote | path join config.json) $config
	{config: $config, constants: $constants}
}

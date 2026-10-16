use ../../lib/core.nu *
use ../../lib/network.nu [curl-text only-loopback]
use api.nu *

# 返回直连出站使用的Happy Eyeballs连接参数
export def happy-eyeballs [] { {tryDelayMs: 0, prioritizeIPv6: false, interleave: 1, maxConcurrentTry: 4} }

# 合并本机订阅服务、公开订阅地址和展示策略到现有面板设置
export def subscription-settings [ctx: record, current: record] {
	$current | merge {
		subEnable: true, subJsonEnable: false, subListen: '127.0.0.1', subPort: $ctx.constants.subscriptionPort
		subPath: $"/($ctx.config.subscriptionPath)/", subDomain: $ctx.config.cdnDomain
		subURI: $"https://($ctx.config.cdnDomain)/($ctx.config.subscriptionPath)/"
		subCertFile: '', subKeyFile: '', subEncrypt: true, subShowInfo: true, subEmailInRemark: true
		remarkTemplate: '{{HOST}}|{{EMAIL}} {{TRAFFIC_USED}}/{{TRAFFIC_LEFT}}'
		subInfoNodeEnable: true, subShowIdentityOnAllLinks: false
		remarkModel: (if ($current.remarkModel? | default '' | is-empty) { '-ieo' } else { $current.remarkModel })
		subUpdates: $ctx.constants.subUpdates, subTitle: '请勿分享！', subSupportUrl: '', subProfileUrl: '', subAnnounce: '请勿分享！', subThemeDir: ''
	}
}

# 确保存在direct的freedom出站，并为其设置Happy Eyeballs
export def configure-outbounds [template: record] {
	mut outbounds = ($template.outbounds? | default [])
	if not ($outbounds | any {|o| $o.protocol == freedom and $o.tag? == direct }) { $outbounds = ($outbounds | append {protocol: freedom, tag: direct, settings: {}}) }
	$template | upsert outbounds ($outbounds | each {|o|
		if $o.protocol == freedom and $o.tag? == direct {
			let stream = ($o.streamSettings? | default {})
			$o | upsert streamSettings ($stream | upsert sockopt (($stream.sockopt? | default {}) | upsert happyEyeballs (happy-eyeballs)))
		} else { $o }
	})
}

# 安装并配置本机3X-UI面板、订阅服务和Xray出站
export def apply [ctx: record] {
	with-temp {|temp|
		let installer = ($temp | path join 3x-ui-install.sh)
		curl-text -- --retry 3 --max-time 900 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh | save $installer
		# Upstream installer is distributed as Bash; it is not repository logic
		with-env {XUI_NONINTERACTIVE: '1', XUI_USERNAME: $ctx.constants.'3xusername', XUI_PASSWORD: $ctx.constants.'3xpassword', XUI_PANEL_PORT: ($ctx.constants.'3xpanelPort' | into string), XUI_WEB_BASE_PATH: $ctx.constants.'3xpanelUriPath', XUI_SSL_MODE: none, XUI_DB_TYPE: sqlite} {
			checked -- bash $installer
		}
	}
	checked -- /usr/local/x-ui/x-ui setting -port $ctx.constants.'3xpanelPort' -username $ctx.constants.'3xusername' -password $ctx.constants.'3xpassword' -webBasePath $ctx.constants.'3xpanelUriPath'
	checked -- /usr/local/x-ui/x-ui setting -listenIP 127.0.0.1
	checked -- systemctl enable --now x-ui
	wait-panel $ctx
	with-panel $ctx {|session|
		let settings = (request $session /panel/api/setting/all --post)
		request $session /panel/api/setting/update --data (subscription-settings $ctx $settings) | ignore
		let xray = (decode-json (request $session /panel/api/xray/ --post))
		let template = (configure-outbounds (decode-json $xray.xraySetting))
		request $session /panel/api/xray/update --form {xraySetting: ($template | to json --raw), outboundTestUrl: ($xray.outboundTestUrl? | default '')} | ignore
		request $session /panel/api/server/restartXrayService --post | ignore
		request $session /panel/api/setting/restartPanel --post | ignore
	}
	sleep 5sec
	wait-panel $ctx
}

# 检查面板服务、回环监听、订阅设置和Happy Eyeballs配置
export def verify [ctx: record] {
	checked -- systemctl is-active --quiet x-ui
	checked -- systemctl is-enabled --quiet x-ui
	only-loopback $ctx.constants.'3xpanelPort'
	only-loopback $ctx.constants.subscriptionPort
	let rows = (retry 5 2sec { capture -- sqlite3 -cmd '.timeout 5000' -json /etc/x-ui/x-ui.db 'select key,value from settings;' | from json })
	for entry in [
		{key: remarkTemplate, expected: '{{HOST}}|{{EMAIL}} {{TRAFFIC_USED}}/{{TRAFFIC_LEFT}}'}
		{key: subInfoNodeEnable, expected: 'true'}
		{key: subShowIdentityOnAllLinks, expected: 'false'}
		{key: subUpdates, expected: ($ctx.constants.subUpdates | into string)}
	] {
		let row = ($rows | where key == $entry.key)
		ensure (($row | length) == 1 and $row.0.value == $entry.expected) $"Unexpected setting: ($entry.key)"
	}
	let template = (open /usr/local/x-ui/bin/config.json)
	ensure ($template.outbounds | any {|o| $o.protocol == freedom and $o.tag? == direct and $o.streamSettings?.sockopt?.happyEyeballs? == (happy-eyeballs) }) 'Missing Happy Eyeballs configuration'
	wait-panel $ctx
}

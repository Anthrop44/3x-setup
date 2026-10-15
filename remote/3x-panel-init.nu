use common.nu *
use 3x-ui-api.nu *

export def happy-eyeballs [] { {tryDelayMs: 0, prioritizeIPv6: false, interleave: 1, maxConcurrentTry: 4} }

export def subscription-settings [ctx: record, current: record] {
	$current | merge {
		subEnable: true, subJsonEnable: false, subListen: '127.0.0.1', subPort: $ctx.constants.subscriptionPort
		subPath: $"/($ctx.config.subscriptionPath)/", subDomain: $ctx.config.cdnDomain
		subURI: $"https://($ctx.config.cdnDomain)/($ctx.config.subscriptionPath)/"
		subCertFile: '', subKeyFile: '', subEncrypt: true, subShowInfo: true, subEmailInRemark: true
		remarkTemplate: '{{INBOUND}} {{EMAIL}} {{TRAFFIC_TOTAL}}'
		remarkModel: (if ($current.remarkModel? | default '' | is-empty) { '-ieo' } else { $current.remarkModel })
		subUpdates: $ctx.constants.subUpdates, subTitle: '请勿分享！', subSupportUrl: '', subProfileUrl: '', subAnnounce: '请勿分享！', subThemeDir: ''
	}
}

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
		let settings = (api $session /panel/api/setting/all --post)
		api $session /panel/api/setting/update --data (subscription-settings $ctx $settings) | ignore
		let xray = (decode-json (api $session /panel/api/xray/ --post))
		let template = (configure-outbounds (decode-json $xray.xraySetting))
		api $session /panel/api/xray/update --form {xraySetting: ($template | to json --raw), outboundTestUrl: ($xray.outboundTestUrl? | default '')} | ignore
		api $session /panel/api/server/restartXrayService --post | ignore
		api $session /panel/api/setting/restartPanel --post | ignore
	}
	sleep 5sec
	wait-panel $ctx
}

use ../../lib/core.nu [ensure with-temp decode-json retry]
use ../../lib/network.nu curl-text

# 携带Cookie和CSRF令牌调用面板API，校验成功状态并返回obj
export def request [session: record, endpoint: string, --post, --data: any, --form: record] {
	mut args = [-b $session.cookie -c $session.cookie -H $"X-CSRF-Token: ($session.csrf)"]
	if $post { $args = ($args | append [-X POST]) }
	if $data != null { $args = ($args | append [-H 'Content-Type: application/json' --data ($data | to json --raw)]) }
	if $form != null { for entry in ($form | transpose key value) { $args = ($args | append [--data-urlencode $"($entry.key)=($entry.value)"]) } }
	let response = (curl-text -- ...$args $"($session.url)($endpoint)" | from json)
	ensure ($response.success? == true) $"3X-UI API failed: ($endpoint): ($response.msg? | default 'invalid response')"
	$response.obj?
}

# 登录面板并将临时会话传给闭包，结束时清理Cookie文件
export def with-panel [ctx: record, body: closure] {
	with-temp {|temp|
		let cookie = ($temp | path join cookies)
		let url = $"http://127.0.0.1:($ctx.constants.'3xpanelPort')/($ctx.constants.'3xpanelUriPath')"
		let page = (curl-text -- -c $cookie $"($url)/")
		let tokens = ($page | parse --regex '<meta name="csrf-token" content="(?P<token>[^"]+)"')
		ensure (($tokens | length) == 1) 'Cannot read 3X-UI CSRF token'
		let session = {cookie: $cookie, url: $url, csrf: $tokens.0.token}
		request $session /login --data {username: $ctx.constants.'3xusername', password: $ctx.constants.'3xpassword', twoFactorCode: ''} | ignore
		do $body $session
	}
}

# 按备注查找唯一入站，并解码其协议、传输和嗅探设置
export def inbound [inbounds: list, remark: string] {
	let items = ($inbounds | where remark == $remark)
	ensure (($items | length) == 1) $"Expected one inbound named ($remark)"
	$items.0 | update settings {|row| decode-json $row.settings } | update streamSettings {|row| decode-json $row.streamSettings } | update sniffing {|row| decode-json $row.sniffing }
}

# 重试访问本机面板，直到就绪或达到重试上限
export def wait-panel [ctx: record] {
	retry 30 2sec { curl-text -- --max-time 5 $"http://127.0.0.1:($ctx.constants.'3xpanelPort')/($ctx.constants.'3xpanelUriPath')/" | ignore }
}

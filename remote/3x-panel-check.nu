use common.nu *
use 3x-panel-init.nu happy-eyeballs
use 3x-ui-api.nu wait-panel

export def verify [ctx: record] {
	checked -- systemctl is-active --quiet x-ui
	checked -- systemctl is-enabled --quiet x-ui
	only-loopback $ctx.constants.'3xpanelPort'
	only-loopback $ctx.constants.subscriptionPort
	let rows = (retry 5 2sec { capture -- sqlite3 -cmd '.timeout 5000' -json /etc/x-ui/x-ui.db 'select key,value from settings;' | from json })
	for entry in [{key: remarkTemplate, expected: '{{INBOUND}} {{EMAIL}} {{TRAFFIC_TOTAL}}'} {key: subUpdates, expected: ($ctx.constants.subUpdates | into string)}] {
		let row = ($rows | where key == $entry.key)
		ensure (($row | length) == 1 and $row.0.value == $entry.expected) $"Unexpected setting: ($entry.key)"
	}
	let template = (open /usr/local/x-ui/bin/config.json)
	ensure ($template.outbounds | any {|o| $o.protocol == freedom and $o.tag? == direct and $o.streamSettings?.sockopt?.happyEyeballs? == (happy-eyeballs) }) 'Missing Happy Eyeballs configuration'
	wait-panel $ctx
}

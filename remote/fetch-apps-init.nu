use common.nu *
use fetch-apps.nu resource-specs

export def apply [ctx: record] {
	let runtime = {
		workDir: $ctx.dir
		targetDir: $"/var/www/3x-fake-site/($ctx.config.subscriptionPath)($ctx.constants.proxyClientsSuffix)"
		logPath: ($ctx.dir | path join log fetch-apps-update.log)
		resources: (resource-specs $ctx.constants.proxyClientsFilenames)
	}
	atomic-json /etc/3x-fetch-apps.json $runtime
	install-timer 3x-fetch-apps '/usr/local/sbin/3x-fetch-apps --update' $ctx.constants.dailyTaskHour
	checked -- systemctl start 3x-fetch-apps.service
}

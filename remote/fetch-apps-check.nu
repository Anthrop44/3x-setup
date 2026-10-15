use common.nu *
use fetch-apps.nu validate-download

export def verify [ctx: record] {
	ensure ((capture -- systemctl show 3x-fetch-apps.service --property=Result --value | str trim) == success) 'Proxy client updater failed'
	for name in [3x-cloudflare-ufw 3x-fetch-apps] { check-timer $name $ctx.constants.dailyTaskHour }
	let state = (open /var/lib/3x-fetch-apps/state.json)
	ensure (($state.resources | columns | length) == ($ctx.constants.proxyClientsFilenames | columns | length)) 'Wrong proxy client resource count'
	let path = $"($ctx.config.subscriptionPath)($ctx.constants.proxyClientsSuffix)"
	for resource in ($ctx.constants.proxyClientsFilenames | transpose id filename) {
		let value = ($state.resources | get $resource.id)
		let file = $"/var/www/3x-fake-site/($path)/($resource.filename)"
		ensure ($value.disabled == false and $value.failureCount == 0 and $value.destinationName == $resource.filename and ($value.assetId | describe) == string and ($value.tag | describe) == string) $"Invalid state: ($resource.id)"
		ensure (validate-download $file $value.size $value.digest) $"Invalid file: ($resource.filename)"
		ensure ((capture -- stat -c '%U:%G:%a' $file | str trim) == 'caddy:caddy:644') 'Invalid proxy file permissions'
		curl-text -- -k -I --resolve $"($ctx.config.cdnDomain):($ctx.config.cdnPort):127.0.0.1" $"https://($ctx.config.cdnDomain):($ctx.config.cdnPort)/($path)/($resource.filename)" | ignore
	}
	no-failed-units
}

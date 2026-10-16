use ../lib/core.nu *
use ../lib/network.nu curl-text
use ../lib/systemd.nu [install-timer check-timer no-failed-units]

# 将固定下载文件名关联到各代理客户端的GitHub仓库和资源匹配规则
export def resource-specs [filenames: record] {
	[
		{id: v2rayNWindowsX64, repo: '2dust/v2rayN', assetPattern: '^v2rayN-windows-64[.]zip$'}
		{id: v2rayNGAndroidArm64, repo: '2dust/v2rayNG', assetPattern: '^v2rayNG_[^/]+-fdroid_arm64-v8a[.]apk$'}
		{id: v2rayNMacOSArm64, repo: '2dust/v2rayN', assetPattern: '^v2rayN-macos-arm64[.]dmg$'}
		{id: v2rayNLinuxX64Deb, repo: '2dust/v2rayN', assetPattern: '^v2rayN-linux-64[.]deb$'}
		{id: v2rayNLinuxX64Rpm, repo: '2dust/v2rayN', assetPattern: '^v2rayN-linux-rhel-64[.]rpm$'}
	] | each {|r| $r | insert filename ($filenames | get $r.id) }
}

# 检查下载文件是否存在、大小正确且匹配可用的SHA-256摘要
export def validate-download [path: string, size: int, digest: string] {
	if not ($path | path exists) { return false }
	if (ls $path | get size.0 | into int) != $size { return false }
	if $digest starts-with 'sha256:' {
		return ((open --raw $path | hash sha256) == ($digest | str substring 7.. | str lowercase))
	}
	$digest == ''
}

# 从稳定release中选出唯一匹配的下载资源，并校验元数据
export def select-asset [release: record, pattern: string] {
	ensure ($release.draft? == false and $release.prerelease? == false and $release.id? != null and ($release.tag_name? | describe) == string) 'Invalid stable release metadata'
	let matches = ($release.assets | where {|asset| $asset.name =~ $pattern })
	ensure (($matches | length) == 1) $"Expected one release asset matching ($pattern)"
	let asset = $matches.0
	ensure ($asset.id? != null and ($asset.size | describe) == int and $asset.size > 0 and ($asset.browser_download_url starts-with 'https://')) 'Invalid release asset metadata'
	$asset
}

# 累计资源失败次数并记录错误，连续失败三次后禁用资源
export def failure-state [previous: record, message: string] {
	let count = (($previous.failureCount? | default 0) + 1)
	$previous | merge {failureCount: $count, disabled: ($count >= 3), lastFailureAt: (date now | format date '%+'), lastError: $message}
}

# 清除资源失败记录和禁用状态，保留已有版本信息
export def reset-state [previous: record] {
	$previous | reject --optional lastFailureAt lastError | merge {failureCount: 0, disabled: false}
}

# 将带时间、级别和资源标识的单行事件追加到更新日志
def event [runtime: record, level: string, name: string, resource: string, message: string] {
	let text = ($message | str replace --all "\n" ' ' | str replace --all "\r" ' ')
	$"(date now | format date '%+') level=($level) event=($name) resource=($resource) message=($text)\n" | save --append $runtime.logPath
}

# 检查并原子更新启用的客户端资源，保存状态并记录更新或失败
export def update-resources [runtime: record, state_path: string] {
	mut state = (if ($state_path | path exists) { open $state_path } else { {resources: {}} })
	mut releases = {}
	mut failed = false
	for resource in $runtime.resources {
		let previous = ($state.resources | get --optional $resource.id | default {})
		if ($previous.disabled? | default false) { continue }
		let repo = $resource.repo
		if $repo not-in $releases {
			let fetched = (try {
				{ok: true, value: (curl-text -- --retry 2 --retry-all-errors -H 'Accept: application/vnd.github+json' -H 'User-Agent: 3x-setup-fetch-apps' $"https://api.github.com/repos/($repo)/releases/latest" | from json)}
			} catch {|err| {ok: false, message: $err.msg} })
			$releases = ($releases | insert $repo $fetched)
		}
		let cached = ($releases | get $repo)
		let result = (try {
			ensure $cached.ok ($cached.message? | default 'Release metadata unavailable')
			let release = $cached.value
			let asset = (select-asset $release $resource.assetPattern)
			let digest = ($asset.digest? | default '')
			let destination = ($runtime.targetDir | path join $resource.filename)
			if (($previous.assetId? | default '' | into string) == ($asset.id | into string)) and (validate-download $destination $asset.size $digest) {
				{ok: true, updated: false, value: (reset-state $previous)}
			} else {
				let temporary = ($runtime.targetDir | path join $".($resource.id)-(random uuid).tmp")
				try {
					checked -- curl --fail --silent --show-error --location --retry 2 --retry-all-errors --connect-timeout 20 --max-time 1800 -H 'Accept: application/octet-stream' -H 'User-Agent: 3x-setup-fetch-apps' $asset.browser_download_url -o $temporary
					ensure (validate-download $temporary $asset.size $digest) 'Downloaded asset failed size/digest validation'
					checked -- chown caddy:caddy $temporary
					checked -- chmod 644 $temporary
					mv --force $temporary $destination
				} catch {|err|
					rm --force $temporary
					error make {msg: $err.msg}
				}
				{ok: true, updated: true, value: {repo: $repo, releaseId: ($release.id | into string), tag: $release.tag_name, assetId: ($asset.id | into string), sourceName: $asset.name, destinationName: $resource.filename, size: $asset.size, digest: $digest, failureCount: 0, disabled: false, updatedAt: (date now | format date '%+')}}
			}
		} catch {|err| {ok: false, message: $err.msg} })
		if $result.ok {
			$state = ($state | upsert resources ($state.resources | upsert $resource.id $result.value))
			if $result.updated { event $runtime INFO resource_updated $resource.id $"tag=($result.value.tag) destination=($resource.filename)" }
		} else {
			$failed = true
			let value = (failure-state $previous $result.message)
			$state = ($state | upsert resources ($state.resources | upsert $resource.id $value))
			event $runtime ERROR resource_failure $resource.id $"attempt=($value.failureCount)/3 ($result.message)"
			if $value.disabled { event $runtime ERROR resource_disabled $resource.id 'manual reset required' }
		}
		atomic-json $state_path $state
	}
	ensure (not $failed) 'One or more proxy client resources failed; see fetch-apps-update.log'
}

# 保存代理客户端下载配置，安装每日定时器并立即运行更新
export def apply [ctx: record] {
	let runtime = {
		workDir: $ctx.dir
		targetDir: $"/var/www/3x-fake-site/($ctx.config.subscriptionPath)($ctx.constants.proxyClientsSuffix)"
		logPath: ($ctx.paths.log | path join fetch-apps-update.log)
		resources: (resource-specs $ctx.constants.proxyClientsFilenames)
	}
	atomic-json /etc/3x-fetch-apps.json $runtime
	install-timer 3x-fetch-apps '/usr/local/sbin/3x-fetch-apps --update' $ctx.constants.dailyTaskHour
	checked -- systemctl start 3x-fetch-apps.service
}

# 检查更新任务、定时器、资源状态、下载文件权限和CDN回源访问
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

# 准备下载目录，按参数重置单个资源或执行资源更新
export def execute [config_path: string, state_dir: string, reset: any] {
	let runtime = (open $config_path)
	mkdir $state_dir ($runtime.logPath | path dirname)
	checked -- install -d -m 755 -o caddy -g caddy $runtime.targetDir
	let state_path = ($state_dir | path join state.json)
	if $reset != null {
		ensure ($runtime.resources | any {|r| $r.id == $reset }) 'Unknown resource ID'
		let state = (if ($state_path | path exists) { open $state_path } else { {resources: {}} })
		let value = (reset-state ($state.resources | get --optional $reset | default {}))
		atomic-json $state_path ($state | update resources ($state.resources | upsert $reset $value))
		event $runtime INFO resource_reset $reset 'failure state cleared'
	} else { update-resources $runtime $state_path }
}

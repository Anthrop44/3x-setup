#!/usr/bin/env nu
const FILE = path self
use common.nu *

export def resource-specs [filenames: record] {
	[
		{id: v2rayNWindowsX64, repo: '2dust/v2rayN', assetPattern: '^v2rayN-windows-64[.]zip$'}
		{id: v2rayNGAndroidArm64, repo: '2dust/v2rayNG', assetPattern: '^v2rayNG_[^/]+-fdroid_arm64-v8a[.]apk$'}
		{id: v2rayNMacOSArm64, repo: '2dust/v2rayN', assetPattern: '^v2rayN-macos-arm64[.]dmg$'}
		{id: v2rayNLinuxX64Deb, repo: '2dust/v2rayN', assetPattern: '^v2rayN-linux-64[.]deb$'}
		{id: v2rayNLinuxX64Rpm, repo: '2dust/v2rayN', assetPattern: '^v2rayN-linux-rhel-64[.]rpm$'}
	] | each {|r| $r | insert filename ($filenames | get $r.id) }
}

export def validate-download [path: string, size: int, digest: string] {
	if not ($path | path exists) { return false }
	if (ls $path | get size.0 | into int) != $size { return false }
	if $digest starts-with 'sha256:' {
		return ((open --raw $path | hash sha256) == ($digest | str substring 7.. | str lowercase))
	}
	$digest == ''
}

export def select-asset [release: record, pattern: string] {
	ensure ($release.draft? == false and $release.prerelease? == false and $release.id? != null and ($release.tag_name? | describe) == string) 'Invalid stable release metadata'
	let matches = ($release.assets | where {|asset| $asset.name =~ $pattern })
	ensure (($matches | length) == 1) $"Expected one release asset matching ($pattern)"
	let asset = $matches.0
	ensure ($asset.id? != null and ($asset.size | describe) == int and $asset.size > 0 and ($asset.browser_download_url starts-with 'https://')) 'Invalid release asset metadata'
	$asset
}

export def failure-state [previous: record, message: string] {
	let count = (($previous.failureCount? | default 0) + 1)
	$previous | merge {failureCount: $count, disabled: ($count >= 3), lastFailureAt: (date now | format date '%+'), lastError: $message}
}

export def reset-state [previous: record] {
	$previous | reject --optional lastFailureAt lastError | merge {failureCount: 0, disabled: false}
}

def event [runtime: record, level: string, name: string, resource: string, message: string] {
	let text = ($message | str replace --all "\n" ' ' | str replace --all "\r" ' ')
	$"(date now | format date '%+') level=($level) event=($name) resource=($resource) message=($text)\n" | save --append $runtime.logPath
}

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

def main [--update, --reset: string, --locked] {
	root-required
	let config_path = ($env.FETCH_APPS_CONFIG_PATH? | default '/etc/3x-fetch-apps.json')
	let state_dir = ($env.FETCH_APPS_STATE_DIR? | default '/var/lib/3x-fetch-apps')
	let lock_path = ($env.FETCH_APPS_LOCK_PATH? | default '/run/3x-fetch-apps.lock')
	ensure ($update or $reset != null) 'Use --update or --reset RESOURCE_ID'
	ensure (not ($update and $reset != null)) 'Choose either --update or --reset'
	if not $locked {
		let options = (if $reset != null { [--reset $reset] } else { [--update] })
		let lock_options = (if $reset != null { [] } else { [--nonblock --conflict-exit-code 75] })
		let result = (^flock ...$lock_options $lock_path nu --no-config-file $FILE --locked ...$options | complete)
		if $result.exit_code == 75 { return }
		print $result.stdout
		ensure ($result.exit_code == 0) $result.stderr
		return
	}
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

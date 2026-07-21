#!/bin/bash

# 安装并执行代理客户端更新任务

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$SCRIPT_DIR/config.json"
CONSTANTS_PATH="$SCRIPT_DIR/constants.json"
LOG_DIR="$SCRIPT_DIR/log"
INIT_LOG_PATH="$LOG_DIR/fetch-apps-init.log"
INSTALL_PATH="/usr/local/sbin/3x-fetch-apps"
RUNTIME_CONFIG_PATH="${FETCH_APPS_CONFIG_PATH:-/etc/3x-fetch-apps.json}"
STATE_DIR="${FETCH_APPS_STATE_DIR:-/var/lib/3x-fetch-apps}"
STATE_PATH="$STATE_DIR/state.json"
LOCK_PATH="${FETCH_APPS_LOCK_PATH:-/run/3x-fetch-apps.lock}"
TEMP_PATHS=()
CURRENT_RESOURCE="general"
UPDATE_LOG_PATH=""

write_event() {
	# 写入可由get-log.ps1获取的事件日志
	local level="$1"
	local event="$2"
	local resource="$3"
	local message="$4"
	local timestamp

	timestamp="$(date -Is)"
	message="${message//$'\r'/ }"
	message="${message//$'\n'/ }"
	printf '%s level=%s event=%s resource=%s message=%s\n' "$timestamp" "$level" "$event" "$resource" "$message" >>"$UPDATE_LOG_PATH"
}

cleanup_update() {
	# 清理更新过程中创建的临时文件
	local path

	for path in "${TEMP_PATHS[@]}"; do
		rm -f -- "$path"
	done
}

handle_update_error() {
	# 记录未被资源级处理捕获的错误
	local status="$1"
	local line="$2"

	if [ -n "$UPDATE_LOG_PATH" ]; then
		write_event "ERROR" "unexpected_error" "$CURRENT_RESOURCE" "line=$line status=$status"
	fi
	exit "$status"
}

ensure_state_file() {
	# 创建初始资源状态文件
	local temp_path

	install -d -m 755 "$STATE_DIR"
	if [ -f "$STATE_PATH" ]; then
		return
	fi
	temp_path="$(mktemp "$STATE_DIR/.state.XXXXXX")"
	printf '{"resources":{}}\n' >"$temp_path"
	chmod 600 "$temp_path"
	mv -f -- "$temp_path" "$STATE_PATH"
}

validate_download() {
	# 根据GitHub元数据验证下载文件
	local path="$1"
	local expected_size="$2"
	local expected_digest="$3"
	local actual_size
	local actual_digest

	if [ ! -f "$path" ]; then
		return 1
	fi
	actual_size="$(stat -c '%s' "$path")"
	if [ "$actual_size" != "$expected_size" ]; then
		return 1
	fi
	if [[ "$expected_digest" == sha256:* ]]; then
		actual_digest="$(sha256sum "$path" | awk '{print $1}')"
		if [ "$actual_digest" != "${expected_digest#sha256:}" ]; then
			return 1
		fi
	fi
}

record_resource_failure() {
	# 累计资源失败并在第三次后禁用
	local resource_id="$1"
	local message="$2"
	local previous_count
	local failure_count
	local disabled
	local timestamp
	local temp_path

	previous_count="$(jq -r --arg id "$resource_id" '.resources[$id].failureCount // 0' "$STATE_PATH")"
	failure_count=$((previous_count + 1))
	disabled=false
	if [ "$failure_count" -ge 3 ]; then
		disabled=true
	fi
	timestamp="$(date -Is)"
	temp_path="$(mktemp "$STATE_DIR/.state.XXXXXX")"
	jq \
		--arg id "$resource_id" \
		--arg timestamp "$timestamp" \
		--arg message "$message" \
		--argjson failureCount "$failure_count" \
		--argjson disabled "$disabled" \
		'.resources[$id] = ((.resources[$id] // {}) + {
			failureCount: $failureCount,
			disabled: $disabled,
			lastFailureAt: $timestamp,
			lastError: $message
		})' "$STATE_PATH" >"$temp_path"
	chmod 600 "$temp_path"
	mv -f -- "$temp_path" "$STATE_PATH"
	write_event "ERROR" "resource_failure" "$resource_id" "attempt=$failure_count/3 $message"
	if [ "$disabled" = true ]; then
		write_event "ERROR" "resource_disabled" "$resource_id" "manual reset required"
	fi
}

record_resource_success() {
	# 保存资源成功更新后的GitHub元数据
	local resource_id="$1"
	local repo="$2"
	local release_id="$3"
	local tag="$4"
	local asset_id="$5"
	local source_name="$6"
	local destination_name="$7"
	local size="$8"
	local digest="$9"
	local timestamp
	local temp_path

	timestamp="$(date -Is)"
	temp_path="$(mktemp "$STATE_DIR/.state.XXXXXX")"
	jq \
		--arg id "$resource_id" \
		--arg repo "$repo" \
		--arg releaseId "$release_id" \
		--arg tag "$tag" \
		--arg assetId "$asset_id" \
		--arg sourceName "$source_name" \
		--arg destinationName "$destination_name" \
		--arg size "$size" \
		--arg digest "$digest" \
		--arg timestamp "$timestamp" \
		'.resources[$id] = {
			repo: $repo,
			releaseId: $releaseId,
			tag: $tag,
			assetId: $assetId,
			sourceName: $sourceName,
			destinationName: $destinationName,
			size: ($size | tonumber),
			digest: $digest,
			failureCount: 0,
			disabled: false,
			updatedAt: $timestamp
		}' "$STATE_PATH" >"$temp_path"
	chmod 600 "$temp_path"
	mv -f -- "$temp_path" "$STATE_PATH"
}

fetch_release() {
	# 获取仓库最新稳定release并缓存响应
	local repo="$1"
	local output_path="$2"
	local error_path="$3"
	local error_text

	if ! curl \
		-fsSL \
		--retry 2 \
		--retry-all-errors \
		--connect-timeout 20 \
		--max-time 120 \
		-H 'Accept: application/vnd.github+json' \
		-H 'User-Agent: 3x-setup-fetch-apps' \
		"https://api.github.com/repos/$repo/releases/latest" \
		-o "$output_path" 2>"$error_path"; then
		error_text="$(tr '\r\n' '  ' <"$error_path" | tail -c 1000)"
		write_event "ERROR" "release_api_error" "$repo" "$error_text"
		return 1
	fi
	if ! jq -e '.draft == false and .prerelease == false and (.id != null) and (.tag_name | type == "string") and (.assets | type == "array")' "$output_path" >/dev/null; then
		write_event "ERROR" "release_api_invalid" "$repo" "latest release response is invalid"
		return 1
	fi
}

update_resource() {
	# 下载并原子更新一个代理客户端资源
	local resource_json="$1"
	local release_path="$2"
	local target_dir="$3"
	local resource_id
	local repo
	local asset_pattern
	local destination_name
	local destination_path
	local match_count
	local asset_json
	local release_id
	local tag
	local asset_id
	local source_name
	local download_url
	local expected_size
	local expected_digest
	local current_asset_id
	local temp_path
	local error_path
	local error_text

	resource_id="$(jq -r '.id' <<<"$resource_json")"
	repo="$(jq -r '.repo' <<<"$resource_json")"
	asset_pattern="$(jq -r '.assetPattern' <<<"$resource_json")"
	destination_name="$(jq -r '.filename' <<<"$resource_json")"
	destination_path="$target_dir/$destination_name"
	CURRENT_RESOURCE="$resource_id"

	if [ "$(jq -r --arg id "$resource_id" '.resources[$id].disabled // false' "$STATE_PATH")" = true ]; then
		return 0
	fi

	match_count="$(jq --arg pattern "$asset_pattern" '[.assets[] | select(.name | test($pattern))] | length' "$release_path")"
	if [ "$match_count" != 1 ]; then
		record_resource_failure "$resource_id" "asset match count=$match_count"
		return 1
	fi
	asset_json="$(jq -c --arg pattern "$asset_pattern" '.assets[] | select(.name | test($pattern))' "$release_path")"
	release_id="$(jq -r '.id' "$release_path")"
	tag="$(jq -r '.tag_name' "$release_path")"
	asset_id="$(jq -r '.id' <<<"$asset_json")"
	source_name="$(jq -r '.name' <<<"$asset_json")"
	download_url="$(jq -r '.browser_download_url' <<<"$asset_json")"
	expected_size="$(jq -r '.size' <<<"$asset_json")"
	expected_digest="$(jq -r '.digest // ""' <<<"$asset_json")"
	current_asset_id="$(jq -r --arg id "$resource_id" '.resources[$id].assetId // ""' "$STATE_PATH")"

	if [ "$current_asset_id" = "$asset_id" ] && validate_download "$destination_path" "$expected_size" "$expected_digest"; then
		return 0
	fi

	temp_path="$(mktemp "$target_dir/.${resource_id}.XXXXXX")"
	error_path="$(mktemp)"
	TEMP_PATHS+=("$temp_path" "$error_path")
	if ! curl \
		-fL \
		--retry 2 \
		--retry-all-errors \
		--connect-timeout 20 \
		--max-time 1800 \
		-H 'Accept: application/octet-stream' \
		-H 'User-Agent: 3x-setup-fetch-apps' \
		"$download_url" \
		-o "$temp_path" 2>"$error_path"; then
		error_text="$(tr '\r\n' '  ' <"$error_path" | tail -c 1000)"
		record_resource_failure "$resource_id" "download failed: $error_text"
		return 1
	fi
	if ! validate_download "$temp_path" "$expected_size" "$expected_digest"; then
		record_resource_failure "$resource_id" "download validation failed"
		return 1
	fi

	chown caddy:caddy "$temp_path"
	chmod 644 "$temp_path"
	mv -f -- "$temp_path" "$destination_path"
	record_resource_success "$resource_id" "$repo" "$release_id" "$tag" "$asset_id" "$source_name" "$destination_name" "$expected_size" "$expected_digest"
	write_event "INFO" "resource_updated" "$resource_id" "tag=$tag source=$source_name destination=$destination_name"
}

run_update() {
	# 检查全部资源并更新发生变化的资产
	local work_dir
	local target_dir
	local resource_json
	local repo
	local release_path
	local error_path
	local overall_failure=0
	declare -A release_paths=()
	declare -A release_status=()

	if [ "$(id -u)" -ne 0 ]; then
		printf '3x-fetch-apps --update must run as root\n' >&2
		exit 1
	fi
	if [ ! -f "$RUNTIME_CONFIG_PATH" ]; then
		printf 'Missing runtime config: %s\n' "$RUNTIME_CONFIG_PATH" >&2
		exit 1
	fi
	work_dir="$(jq -r '.workDir' "$RUNTIME_CONFIG_PATH")"
	target_dir="$(jq -r '.targetDir' "$RUNTIME_CONFIG_PATH")"
	UPDATE_LOG_PATH="$(jq -r '.logPath' "$RUNTIME_CONFIG_PATH")"
	install -d -m 755 "$(dirname "$UPDATE_LOG_PATH")"
	touch "$UPDATE_LOG_PATH"
	chmod 644 "$UPDATE_LOG_PATH"
	install -d -m 755 -o caddy -g caddy "$target_dir"
	ensure_state_file
	exec 9>"$LOCK_PATH"
	if ! flock -n 9; then
		exit 0
	fi
	trap cleanup_update EXIT
	trap 'handle_update_error $? $LINENO' ERR

	while IFS= read -r resource_json; do
		repo="$(jq -r '.repo' <<<"$resource_json")"
		if [ "$(jq -r --arg id "$(jq -r '.id' <<<"$resource_json")" '.resources[$id].disabled // false' "$STATE_PATH")" = true ]; then
			continue
		fi
		if [ -z "${release_status[$repo]+x}" ]; then
			release_path="$(mktemp)"
			error_path="$(mktemp)"
			TEMP_PATHS+=("$release_path" "$error_path")
			if fetch_release "$repo" "$release_path" "$error_path"; then
				release_status[$repo]=success
				release_paths[$repo]="$release_path"
			else
				release_status[$repo]=failed
				overall_failure=1
			fi
		fi
		if [ "${release_status[$repo]}" = failed ]; then
			continue
		fi
		if ! update_resource "$resource_json" "${release_paths[$repo]}" "$target_dir"; then
			overall_failure=1
		fi
	done < <(jq -c '.resources[]' "$RUNTIME_CONFIG_PATH")

	CURRENT_RESOURCE="general"
	if [ "$overall_failure" -ne 0 ]; then
		exit 1
	fi
	cd "$work_dir"
}

reset_resource() {
	# 手动清除单个资源的失败和禁用状态
	local resource_id="$1"
	local temp_path

	if [ "$(id -u)" -ne 0 ]; then
		printf '3x-fetch-apps --reset must run as root\n' >&2
		exit 1
	fi
	if ! jq -e --arg id "$resource_id" 'any(.resources[]; .id == $id)' "$RUNTIME_CONFIG_PATH" >/dev/null; then
		printf 'Unknown resource: %s\n' "$resource_id" >&2
		exit 1
	fi
	UPDATE_LOG_PATH="$(jq -r '.logPath' "$RUNTIME_CONFIG_PATH")"
	touch "$UPDATE_LOG_PATH"
	chmod 644 "$UPDATE_LOG_PATH"
	ensure_state_file
	exec 9>"$LOCK_PATH"
	flock 9
	temp_path="$(mktemp "$STATE_DIR/.state.XXXXXX")"
	jq --arg id "$resource_id" '.resources[$id] = ((.resources[$id] // {}) + {failureCount: 0, disabled: false}) | del(.resources[$id].lastFailureAt, .resources[$id].lastError)' "$STATE_PATH" >"$temp_path"
	chmod 600 "$temp_path"
	mv -f -- "$temp_path" "$STATE_PATH"
	write_event "INFO" "resource_reset" "$resource_id" "failure state cleared"
}

install_task() {
	# 安装更新器配置和systemd任务
	local username
	local subscription_path
	local proxy_clients_suffix
	local daily_task_hour
	local daily_task_time
	local target_dir
	local runtime_config_temp

	mkdir -p "$LOG_DIR"
	rm -f "$INIT_LOG_PATH"
	exec >>"$INIT_LOG_PATH" 2>&1
	username="$(jq -r '.username' "$CONSTANTS_PATH")"
	subscription_path="$(jq -r '.subscriptionPath' "$CONFIG_PATH")"
	proxy_clients_suffix="$(jq -r '.proxyClientsSuffix' "$CONSTANTS_PATH")"
	daily_task_hour="$(jq -r '.dailyTaskHour' "$CONSTANTS_PATH")"
	printf -v daily_task_time '%02d:00:00' "$daily_task_hour"
	target_dir="/var/www/3x-fake-site/${subscription_path}${proxy_clients_suffix}"
	runtime_config_temp="$(mktemp)"
	trap 'rm -f "$runtime_config_temp"' EXIT

	jq -n \
		--arg workDir "$SCRIPT_DIR" \
		--arg logPath "$LOG_DIR/fetch-apps-update.log" \
		--arg targetDir "$target_dir" \
		--arg v2rayNWindowsX64 "$(jq -r '.proxyClientsFilenames.v2rayNWindowsX64' "$CONSTANTS_PATH")" \
		--arg v2rayNGAndroidArm64 "$(jq -r '.proxyClientsFilenames.v2rayNGAndroidArm64' "$CONSTANTS_PATH")" \
		--arg v2rayNMacOSArm64 "$(jq -r '.proxyClientsFilenames.v2rayNMacOSArm64' "$CONSTANTS_PATH")" \
		--arg v2rayNLinuxX64Deb "$(jq -r '.proxyClientsFilenames.v2rayNLinuxX64Deb' "$CONSTANTS_PATH")" \
		--arg v2rayNLinuxX64Rpm "$(jq -r '.proxyClientsFilenames.v2rayNLinuxX64Rpm' "$CONSTANTS_PATH")" \
		'{
			workDir: $workDir,
			logPath: $logPath,
			targetDir: $targetDir,
			resources: [
				{id: "v2rayNWindowsX64", repo: "2dust/v2rayN", assetPattern: "^v2rayN-windows-64[.]zip$", filename: $v2rayNWindowsX64},
				{id: "v2rayNGAndroidArm64", repo: "2dust/v2rayNG", assetPattern: "^v2rayNG_[^/]+-fdroid_arm64-v8a[.]apk$", filename: $v2rayNGAndroidArm64},
				{id: "v2rayNMacOSArm64", repo: "2dust/v2rayN", assetPattern: "^v2rayN-macos-arm64[.]dmg$", filename: $v2rayNMacOSArm64},
				{id: "v2rayNLinuxX64Deb", repo: "2dust/v2rayN", assetPattern: "^v2rayN-linux-64[.]deb$", filename: $v2rayNLinuxX64Deb},
				{id: "v2rayNLinuxX64Rpm", repo: "2dust/v2rayN", assetPattern: "^v2rayN-linux-rhel-64[.]rpm$", filename: $v2rayNLinuxX64Rpm}
			]
		}' >"$runtime_config_temp"

	sudo install -m 755 -o root -g root "$SCRIPT_DIR/fetch-apps-init.sh" "$INSTALL_PATH"
	sudo install -m 600 -o root -g root "$runtime_config_temp" "$RUNTIME_CONFIG_PATH"
	rm -f "$runtime_config_temp"
	trap - EXIT
	sudo install -d -m 755 -o caddy -g caddy "$target_dir"
	touch "$LOG_DIR/fetch-apps-update.log"

	sudo tee /etc/systemd/system/3x-fetch-apps.service >/dev/null <<'EOF'
[Unit]
Description=Update proxy client release assets for 3x fake site
Wants=network-online.target
After=network-online.target caddy.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/3x-fetch-apps --update
EOF

	sed "s|{{DAILY_TASK_TIME}}|$daily_task_time|g" <<'EOF' | sudo tee /etc/systemd/system/3x-fetch-apps.timer >/dev/null
[Unit]
Description=Update proxy client release assets daily

[Timer]
OnCalendar=*-*-* {{DAILY_TASK_TIME}}
RandomizedDelaySec=1h
Persistent=true
Unit=3x-fetch-apps.service

[Install]
WantedBy=timers.target
EOF

	sudo systemctl daemon-reload
	sudo systemctl enable --now 3x-fetch-apps.timer
	sudo systemctl start 3x-fetch-apps.service

	chmod +x "$SCRIPT_DIR/fetch-apps-check.sh"
	exec bash "$SCRIPT_DIR/fetch-apps-check.sh" "$@"
}

case "${1:-}" in
--update)
	shift
	run_update "$@"
	;;
--reset)
	if [ "$#" -ne 2 ]; then
		printf 'Usage: 3x-fetch-apps --reset RESOURCE_ID\n' >&2
		exit 1
	fi
	reset_resource "$2"
	;;
*)
	install_task "$@"
	;;
esac

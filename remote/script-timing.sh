#!/bin/bash

# 脚本执行耗时公共函数

SCRIPT_TIMER_STARTED_SECONDS="${SECONDS:-0}"
SCRIPT_TIMER_REPORTED=0

script_timer_finish() {
	# 输出脚本执行耗时并保留退出码
	local exit_code="$1"
	local elapsed_seconds

	if [ "$SCRIPT_TIMER_REPORTED" -ne 0 ]; then
		return "$exit_code"
	fi
	SCRIPT_TIMER_REPORTED=1
	elapsed_seconds=$((SECONDS - SCRIPT_TIMER_STARTED_SECONDS))
	printf 'Execution time: %02d:%02d:%02d\n' "$((elapsed_seconds / 3600))" "$(((elapsed_seconds / 60) % 60))" "$((elapsed_seconds % 60))"
	return "$exit_code"
}

script_timer_on_exit() {
	# 在脚本退出时输出执行耗时
	local exit_code="$?"

	script_timer_finish "$exit_code"
}

script_timer_install_exit_trap() {
	# 安装默认退出计时处理器
	trap script_timer_on_exit EXIT
}

script_timer_install_exit_trap

use core.nu ensure

# 执行单个阶段并输出开始、耗时和成功或失败信息
# 阶段函数由登记表维护，执行器只处理阶段名和闭包
export def execute-stage [stage: record, ctx: record] {
	let started = (date now)
	print $"Starting ($stage.name) at ($started)"
	try {
		do $stage.run $ctx
		print $"Completed ($stage.name); execution time: ((date now) - $started)"
	} catch {|err|
		print --stderr $"FAILED ($stage.name); execution time: ((date now) - $started)"
		error make {msg: $err.msg}
	}
}

# 依次在独立Nu进程中执行阶段并保存日志，失败时停止
export def run-workflow [ctx: record, stages: list, --from: string] {
	let selected = (if $from == null { $stages } else {
		ensure ($from in $stages.name) $"Invalid starting stage: ($from)"
		$stages | skip until {|stage| $stage.name == $from }
	})
	mkdir $ctx.paths.log
	let flags = ([(if $ctx.noTLS { '--noTLS' } else { '' }) (if $ctx.noAPP { '--noAPP' } else { '' })] | where {|flag| $flag != '' })
	for stage in $selected {
		let log = ($ctx.paths.log | path join $"($stage.name).log")
		try {
			^nu --no-config-file $ctx.paths.main deploy --stage $stage.name ...$flags out+err> $log
		} catch { error make {msg: $"Stage ($stage.name) failed; see ($log)"} }
	}
}

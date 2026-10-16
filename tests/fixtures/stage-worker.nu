use ../../remote/lib/runner.nu execute-stage

# 执行测试阶段，输出上下文和错误流，并按阶段名模拟失败
def 'main deploy' [--stage: string, --noTLS, --noAPP] {
	let action = {|ctx|
		print ($ctx | to json --raw)
		print --stderr $"stderr from ($ctx.stage)"
		if $ctx.stage == failure { error make {msg: 'Fixture stage failed'} }
	}
	execute-stage {name: $stage, run: $action} {stage: $stage, noTLS: $noTLS, noAPP: $noAPP}
}

# 提供测试阶段工作进程的空默认入口
def main [] {}

use ../../remote/lib/runner.nu execute-stage

def 'main deploy' [--stage: string, --noTLS, --noAPP] {
	let action = {|ctx|
		print ($ctx | to json --raw)
		print --stderr $"stderr from ($ctx.stage)"
		if $ctx.stage == failure { error make {msg: 'Fixture stage failed'} }
	}
	execute-stage {name: $stage, run: $action} {stage: $stage, noTLS: $noTLS, noAPP: $noAPP}
}

def main [] {}

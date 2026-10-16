def --wrapped main [...args: string] {
	let destination = ($args | last)
	if ($args | take 7) != [-d -m '755' -o caddy -g caddy] or not ($destination starts-with $env.TEST_SANDBOX) {
		error make {msg: 'Refusing install outside test sandbox'}
	}
	mkdir $destination
}

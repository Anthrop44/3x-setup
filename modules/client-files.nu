use ../remote/common.nu [ensure capture token]

# OpenSSL supplies PBKDF2, AES and HMAC; orchestration stays in Nu
export def encrypt-page [plaintext: string, password: string] {
	let salt = (token 16)
	let iv = (token 16)
	let keys = (capture -- openssl kdf -keylen 64 -kdfopt digest:SHA256 -kdfopt $"pass:($password)" -kdfopt $"hexsalt:($salt)" -kdfopt iter:100000 PBKDF2 | str trim | str replace --all ':' '' | str lowercase)
	let aes = ($keys | str substring 0..<64)
	let mac = ($keys | str substring 64..<128)
	let encrypted = ($plaintext | ^openssl enc -aes-256-cbc -K $aes -iv $iv | complete)
	ensure ($encrypted.exit_code == 0) 'Page encryption failed'
	let data = ([($iv | decode hex) $encrypted.stdout] | bytes collect)
	let tag = ($data | ^openssl dgst -sha256 -mac HMAC -macopt $"hexkey:($mac)" -binary | complete)
	ensure ($tag.exit_code == 0) 'Page authentication failed'
	{salt: ($salt | decode hex | encode base64), iv: ($iv | decode hex | encode base64), ciphertext: ($encrypted.stdout | encode base64), tag: ($tag.stdout | encode base64)}
}

export def export-client-files [project: string, config: record, constants: record] {
	let template = (open --raw ($project | path join modules template.xhtml) | str replace --all "\r\n" "\n")
	let dir = ($project | path join remote fake-site $config.distributionPath)
	rm --recursive --force $dir
	mkdir $dir
	cp ($project | path join modules template.css) ($dir | path join template.css)
	mut rows = []
	for client in $config.clients {
		mut content = $template
		let replacements = ($config | select cdnDomain directDomain subscriptionPath | merge {clientPath: $client.path, proxyClientsSuffix: $constants.proxyClientsSuffix})
		for item in ($replacements | transpose key value) { $content = ($content | str replace --all $"{($item.key)}" $item.value) }
		for item in ($constants.proxyClientsFilenames | transpose key value) { $content = ($content | str replace --all $"{proxyClientsFilenames.($item.key)}" $item.value) }
		ensure (not ($content =~ '\{(?:cdnDomain|directDomain|subscriptionPath|proxyClientsSuffix|clientPath|proxyClientsFilenames\.)')) 'Unresolved distribution template placeholder'
		let matches = ($content | parse --regex '(?s)<main id="encrypted">(?P<body>.*?)</main>')
		ensure (($matches | length) == 1) 'Template must contain one main#encrypted element'
		let encrypted = (encrypt-page $matches.0.body $client.password)
		let tag = $'<main id="encrypted" data-salt="($encrypted.salt)" data-iv="($encrypted.iv)" data-ciphertext="($encrypted.ciphertext)" data-tag="($encrypted.tag)"></main>'
		$content | str replace $'<main id="encrypted">($matches.0.body)</main>' $tag | save --force ($dir | path join $"($client.path).html")
		$rows = ($rows | append {clients: $client.client, distributionURL: $"https://($config.cdnDomain)/($config.distributionPath)/($client.path).html", Password: $client.password})
	}
	$rows | to tsv | save --force ($project | path join clients.tsv)
}

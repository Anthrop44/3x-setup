#!/usr/bin/env nu
const ROOT = path self ..
use ../remote/common.nu *
use ../remote/schema.nu *
use ../remote/check-common.nu *
use ../remote/root-init.nu deployment-stages
use ../remote/3x-inbound-init.nu inbound-payloads
use ../remote/3x-ui-api.nu inbound
use ../remote/3x-panel-init.nu [subscription-settings configure-outbounds happy-eyeballs]
use ../remote/cf-host-init.nu host-payloads
use ../remote/3x-client-init.nu [client-policy stale-clients]
use ../remote/3x-client-check.nu [validate-links proxy-config]
use ../remote/vless-encryption.nu [select-vless-encryption validate-vless-encryption]
use ../remote/caddyfile-common.nu render-caddyfile
use ../remote/fetch-apps.nu [resource-specs validate-download select-asset failure-state reset-state update-resources]
use ../remote/cloudflare-ufw.nu parse-networks
use ../modules/setup-config.nu prepare-config
use ../modules/client-files.nu [encrypt-page export-client-files]
use ../modules/generate-ssh-key.nu initialize-key
use ../modules/ssh.nu [shell-quote remote-nu ssh-target scp-target]

def rejects [body: closure] {
	ensure (try { do $body | ignore; false } catch { true }) 'Expected rejection'
}

def main [] {
	for path in (glob ($ROOT | path join '**/*.nu')) { ensure (nu-check --debug $path) $"Invalid Nu syntax: ($path)" }
	let constants = (open ($ROOT | path join remote constants.json))
	let config = {ip: '192.0.2.1', cdnDomain: cdn.example.com, directDomain: direct.example.com, cdnPort: 23456, clients: [{client: alice} {client: bob, traffic: 20, password: '01234567'}], cdnOptDomains: [opt.example.com]}
	validate-config $config $constants
	validate-config ($config | update ip '[2001:db8::1]') $constants
	for bad in [($config | update clients []) ($config | update ip '999.0.0.1') ($config | insert unknown true) ($config | insert sshPort 23456) ($config | update clients [{client: CON}]) ($config | update clients [{client: alice} {client: ALICE}]) ($config | update cdnOptDomains [CDN.example.com]) ($config | update clients [{client: alice, traffic: -1}])] { rejects { validate-config $bad $constants } }
	for password in ['1234' '1234567' '123456789' '1234567x' '１２３４５６７８' 12345678 null ''] {
		rejects { validate-config ($config | update clients.0 {client: alice, password: $password}) $constants }
	}
	rejects { validate-config $config ($constants | update proxyClientsFilenames.v2rayNWindowsX64 '../escape.zip') }
	ensure ((deployment-stages | length) == 17) 'Missing deployment stages'
	ensure ((deployment-stages --noAPP | length) == 15) '--noAPP does not skip both app stages'
	rejects { checked -- nu --no-config-file -c 'exit 17' }
	rejects { capture -- nu --no-config-file -c 'exit 19' }
	ensure ((ssh-target {ip: '[2001:db8::1]'}) == 'root@2001:db8::1') 'Invalid SSH IPv6 target'
	ensure ((scp-target {ip: '[2001:db8::1]'} '/tmp/test') == 'root@[2001:db8::1]:/tmp/test') 'Invalid SCP IPv6 target'
	let quoted = (shell-quote 'a b"c''d;$x')
	ensure ($quoted starts-with "'") 'Missing shell quoting'
	print 'PASS schemas, CLI stages, exit status and SSH addressing'

	with-temp {|temp|
		mkdir ($temp | path join remote fake-site) ($temp | path join modules)
		cp ($ROOT | path join modules template.xhtml) ($temp | path join modules template.xhtml)
		cp ($ROOT | path join modules template.css) ($temp | path join modules template.css)
		write-json ($temp | path join remote config.json) $config
		write-json ($temp | path join remote constants.json) $constants
		let setup = (prepare-config $temp --initial)
		let again = (prepare-config $temp)
		ensure ($setup == $again) 'Synchronization changed existing generated fields'
		ensure ($setup == (prepare-config $temp --initial)) 'Rebuild changed existing generated fields'
		ensure ($setup.config.clients | all {|c| $c.password =~ '^[0-9]{8}$' }) 'Missing eight-digit client password'
		ensure ($setup.config.clients.1.password == '01234567') 'Existing password lost its leading zero'
		ensure ((open ($temp | path join remote config.json)) == $setup.config) 'Generated passwords were not saved to config.json'
		validate-config $setup.config $constants --complete
		rejects { validate-config ($setup.config | update clients.0 {|c| $c | reject password }) $constants --complete }
		write-json ($temp | path join remote config.json) ($setup.config | update clients {|cfg| $cfg.clients | append {client: charlie} })
		let added = (prepare-config $temp)
		ensure (($added.config.clients | take 2) == $setup.config.clients and $added.config.clients.2.password =~ '^[0-9]{8}$') 'New client changed existing passwords or did not receive a password'
		write-json ($temp | path join remote config.json) $setup.config
		export-client-files $temp $setup.config $constants
		let page = (open --raw ($temp | path join remote fake-site $setup.config.distributionPath $"($setup.config.clients.0.path).html"))
		ensure (not ($page | str contains $"https://($config.cdnDomain)/($setup.config.subscriptionPath)/")) 'Plaintext subscription leaked into distribution page'
		ensure ($page | str contains 'data-tag=') 'Missing page authentication'
		let tsv = (open --raw ($temp | path join clients.tsv) | from tsv --no-infer)
		ensure (($tsv | length) == 2 and $tsv.0.clients == alice) 'Incorrect client URL export'
		for row in ($setup.config.clients | enumerate) {
			let client = $row.item
			let exported = ($tsv | get $row.index)
			ensure ($exported.Password == $client.password and $exported.distributionURL == $"https://($config.cdnDomain)/($setup.config.distributionPath)/($client.path).html") 'Incorrect client password or URL export'
			let html = (open --raw ($temp | path join remote fake-site $setup.config.distributionPath $"($client.path).html"))
			ensure (not ($html | str contains $client.password) and not ($html | str contains 'four_digits')) 'Plaintext password leaked into distribution page'
			let payload = ($html | parse --regex 'data-salt="(?P<salt>[^"]+)" data-iv="(?P<iv>[^"]+)" data-ciphertext="(?P<ciphertext>[^"]+)" data-tag="(?P<tag>[^"]+)"' | first)
			let keys = (capture -- openssl kdf -keylen 64 -kdfopt digest:SHA256 -kdfopt $"pass:($exported.Password)" -kdfopt $"hexsalt:($payload.salt | decode base64 | encode hex)" -kdfopt iter:100000 PBKDF2 | str trim | str replace --all ':' '')
			let decoded = ($payload.ciphertext | decode base64 | ^openssl enc -d -aes-256-cbc -K ($keys | str substring 0..<64) -iv ($payload.iv | decode base64 | encode hex) | complete)
			ensure ($decoded.exit_code == 0 and ($decoded.stdout | str contains $"https://($config.cdnDomain)/($setup.config.subscriptionPath)/($client.path)")) 'Exported password cannot decrypt the corresponding page'
			let signed = ([($payload.iv | decode base64) ($payload.ciphertext | decode base64)] | bytes collect)
			let tag = ($signed | ^openssl dgst -sha256 -mac HMAC -macopt $"hexkey:($keys | str substring 64..<128)" -binary | complete)
			ensure ($tag.exit_code == 0 and ($tag.stdout | encode base64) == $payload.tag) 'Exported password cannot authenticate the corresponding page'
		}
		export-client-files $temp $again.config $constants
		ensure ((open --raw ($temp | path join clients.tsv) | from tsv --no-infer) == $tsv) 'Page regeneration changed exported passwords'
		initialize-key $temp
		let original = (open --raw ($temp | path join id_ed25519))
		initialize-key $temp
		ensure ((open --raw ($temp | path join id_ed25519)) == $original) 'Existing private key was overwritten'
		mv ($temp | path join id_ed25519) ($temp | path join key.backup)
		rejects { initialize-key $temp }

		let ctx = {dir: ($temp | path join remote), config: $setup.config, constants: $constants, noTLS: true, noAPP: true}
		write-json ($ctx.dir | path join paths.json) {xhttpPath: abcdef0123456789abcd}
		cp ($ROOT | path join remote Caddyfile.template) ($ctx.dir | path join Caddyfile.template)
		let caddy = (render-caddyfile $ctx)
		ensure ($caddy | str contains 'tls /etc/caddy/3x-direct-cert.pem /etc/caddy/3x-direct-key.pem') 'Missing initial file TLS'
		ensure (not ($caddy | str contains 'issuer acme')) '--noTLS should not render ACME'
		ensure ((render-caddyfile $ctx --acme) | str contains 'disable_tlsalpn_challenge') 'Missing HTTP-01 configuration'
		let seed = ('s' | fill --width 64 --character s | encode base64 --url --nopad)
		let public = ('p' | fill --width 1184 --character p | encode base64 --url --nopad)
		let encryption = {decryption: $"mlkem768x25519plus.xorpub.600s.($seed)", encryption: $"mlkem768x25519plus.xorpub.0rtt.($public)"}
		let auth = ($encryption | insert id mlkem768_xorpub)
		ensure ((select-vless-encryption {auths: [{id: x25519_xorpub} {id: mlkem768} $auth]}) == $encryption) 'Wrong VLESS authentication selected'
		rejects { select-vless-encryption {auths: []} }
		rejects { select-vless-encryption {auths: [$auth $auth]} }
		rejects { validate-vless-encryption ($encryption | update decryption 'mlkem768x25519plus.xorpub.600s.short') }
		rejects { validate-vless-encryption ($encryption | update encryption 'mlkem768x25519plus.xorpub.0rtt.short') }
		rejects { validate-vless-encryption ($encryption | update encryption ($encryption.encryption | str replace '.xorpub.' '.native.')) }
		let payloads = (inbound-payloads $ctx (open ($ctx.dir | path join paths.json)) {privateKey: secret, publicKey: public} '0011223344556677' 'aabbccddeeff0011' $encryption)
		ensure (($payloads | get port) == [443 443 $constants.xhttpPort]) 'Wrong inbound ports'
		ensure (($payloads.2.settings | select decryption encryption) == $encryption and $payloads.1.settings.encryption == none and $payloads.1.settings.decryption == none) 'Wrong inbound encryption settings'
		ensure ('fallbacks' not-in $payloads.2.settings) 'Even empty fallbacks conflict with VLESS encryption'
		let reality = $payloads.1.streamSettings.realitySettings
		let direct_proxy = (proxy-config $ctx uuid $reality 12345 --xhttp={} --cdn-alpn='')
		ensure ($direct_proxy.outbounds.0.settings.vnext.0.users.0.encryption == none) 'Reality encryption changed'
		let xhttp_proxy = (proxy-config $ctx uuid $reality 12345 --xhttp=$payloads.2.settings)
		ensure ($xhttp_proxy.outbounds.0.settings.vnext.0.users.0 == {id: uuid, encryption: $encryption.encryption, flow: xtls-rprx-vision}) 'XHTTP proxy test does not use encryption and Vision'
		ensure ($xhttp_proxy.outbounds.0.settings.vnext.0.port == $constants.xhttpPort and $xhttp_proxy.outbounds.0.streamSettings.security == none) 'Wrong loopback test endpoint'
		for alpn in [h2 h3] {
			let outbound = (proxy-config $ctx uuid $reality 12345 --xhttp=$payloads.2.settings --cdn-alpn=$alpn | get outbounds.0)
			ensure ($outbound.settings.vnext.0.address == $config.cdnDomain and $outbound.settings.vnext.0.port == 443 and $outbound.streamSettings.security == tls and $outbound.streamSettings.tlsSettings.alpn == [$alpn] and $outbound.streamSettings.tlsSettings.serverName == $config.cdnDomain and $outbound.streamSettings.xhttpSettings.host == $config.cdnDomain) 'Wrong CDN test endpoint or TLS'
			ensure (not ($outbound | to json --raw | str contains $seed)) 'ML-KEM private seed leaked into client configuration'
		}
		let encoded = ($payloads | each {|p| $p | update settings {|r| $r.settings | to json --raw } | update streamSettings {|r| $r.streamSettings | to json --raw } | update sniffing {|r| $r.sniffing | to json --raw } })
		ensure ((inbound $encoded TCP | get streamSettings.realitySettings.settings.publicKey) == public) 'Failed to decode 3X-UI JSON strings'
		let hosts = (host-payloads $ctx 9)
		ensure (($hosts | length) == 4 and $hosts.0.groupId == '3xsetupxhttpcdn1h2' and $hosts.3.sortOrder == 3 and $hosts.3.alpn == [h3]) 'Wrong Host group mapping'
		let policy = (client-policy $setup.config.clients.1)
		ensure ($policy.totalGB == 21474836480 and $policy.reset == 30) 'Wrong client traffic quota'
		ensure ((stale-clients $setup.config.clients [$policy]) | is-empty) 'Unchanged client would be deleted'
		ensure ((stale-clients $setup.config.clients [($policy | update subId changed)]) == [bob]) 'Changed subscription would not be replaced'
		let settings = (subscription-settings $ctx {remarkModel: ''})
		ensure ($settings.subListen == '127.0.0.1' and $settings.subEncrypt and $settings.subUpdates == $constants.subUpdates) 'Wrong subscription settings'
		ensure ((configure-outbounds {outbounds: []} | get outbounds.0.streamSettings.sockopt.happyEyeballs) == (happy-eyeballs)) 'Missing direct outbound defaults'
		let links = [
			'hysteria2://auth@direct.example.com:443/#QUIC'
			'vless://uuid@direct.example.com:443/?flow=xtls-rprx-vision#TCP'
			$"vless://uuid@cdn.example.com:443/?type=xhttp&alpn=h2&encryption=($encryption.encryption)&flow=xtls-rprx-vision"
			$"vless://uuid@cdn.example.com:443/?type=xhttp&alpn=h3&encryption=($encryption.encryption)&flow=xtls-rprx-vision"
			$"vless://uuid@opt.example.com:443/?type=xhttp&alpn=h2&encryption=($encryption.encryption)&flow=xtls-rprx-vision"
			$"vless://uuid@opt.example.com:443/?type=xhttp&alpn=h3&encryption=($encryption.encryption)&flow=xtls-rprx-vision"
		]
		validate-links $ctx $links $encryption.encryption
		validate-links $ctx ($links | each { str replace 'encryption=mlkem' 'encryption=%6Dlkem' }) $encryption.encryption
		rejects { validate-links $ctx ($links | drop) $encryption.encryption }
		rejects { validate-links $ctx ($links | each { str replace ':443/' ':23456/' }) $encryption.encryption }
		rejects { validate-links $ctx ($links | each { str replace $encryption.encryption none }) $encryption.encryption }
		rejects { validate-links $ctx ($links | each { str replace $encryption.encryption $encryption.decryption }) $encryption.encryption }
		rejects { validate-links $ctx ($links | each { str replace '&flow=xtls-rprx-vision' '' }) $encryption.encryption }
		print 'PASS configuration stability, distribution generation, SSH keys, Caddy, API payloads and subscription validation'

		let plaintext = 'Subscription test: 中文 <>&'
		let encrypted = (encrypt-page $plaintext '01234567')
		let keys = (capture -- openssl kdf -keylen 64 -kdfopt digest:SHA256 -kdfopt pass:01234567 -kdfopt $"hexsalt:($encrypted.salt | decode base64 | encode hex)" -kdfopt iter:100000 PBKDF2 | str trim | str replace --all ':' '')
		let decrypted = ($encrypted.ciphertext | decode base64 | ^openssl enc -d -aes-256-cbc -K ($keys | str substring 0..<64) -iv ($encrypted.iv | decode base64 | encode hex) | complete)
		ensure ($decrypted.exit_code == 0 and $decrypted.stdout == $plaintext) 'Page encryption round trip failed'
		let signed = ([($encrypted.iv | decode base64) ($encrypted.ciphertext | decode base64)] | bytes collect)
		let tag = ($signed | ^openssl dgst -sha256 -mac HMAC -macopt $"hexkey:($keys | str substring 64..<128)" -binary | complete)
		ensure (($tag.stdout | encode base64) == $encrypted.tag) 'Page authentication tag mismatch'
		print 'PASS PBKDF2/AES-CBC/HMAC round trip'

		let file = ($temp | path join asset.bin)
		0x[00 01 ff fe 03] | save $file
		let digest = $"sha256:(open --raw $file | hash sha256)"
		ensure (validate-download $file 5 $digest) 'Valid binary rejected'
		ensure (not (validate-download $file 4 $digest)) 'Wrong download size accepted'
		ensure (not (validate-download $file 5 'sha256:00')) 'Wrong download digest accepted'
		let release = {id: 1, draft: false, prerelease: false, tag_name: 'v1', assets: [{id: 2, name: v2rayN-windows-64.zip, size: 5, browser_download_url: 'https://example.invalid/file', digest: $digest}]}
		ensure ((select-asset $release '^v2rayN-windows-64[.]zip$').id == 2) 'Asset selection failed'
		rejects { select-asset ($release | update assets ($release.assets | append $release.assets)) '.*' }
		let failed = (failure-state (failure-state (failure-state {} 'one') 'two') 'three')
		ensure ($failed.disabled and $failed.failureCount == 3) 'Third failure did not disable resource'
		let reset = (reset-state $failed)
		ensure (not $reset.disabled and $reset.failureCount == 0 and 'lastError' not-in $reset) 'Reset failed'
		rejects { parse-networks "invalid\n" }
		ensure ((parse-networks "192.0.2.0/24\n2001:db8::/32\n" | length) == 2) 'Cloudflare parser failed'
		print 'PASS asset validation, failure state, reset and Cloudflare list validation'
		if $nu.os-info.name != windows {
			let mocks = ($temp | path join mocks)
			mkdir $mocks
			let release_path = ($temp | path join release.json)
			write-json $release_path $release
			'#!/usr/bin/env nu
def --wrapped main [...args: string] {
	if "-o" in $args {
		let index = ($args | enumerate | where item == "-o" | get index.0)
		open --raw $env.TEST_ASSET | save --force ($args | get ($index + 1))
	} else { open $env.TEST_RELEASE | to json --raw | print }
}
' | save ($mocks | path join curl)
			"#!/usr/bin/env nu\nexit 0\n" | save ($mocks | path join chown)
			checked -- chmod 755 ($mocks | path join curl) ($mocks | path join chown)
			let destination = ($temp | path join downloads)
			mkdir $destination
			let runtime = {targetDir: $destination, logPath: ($temp | path join updater.log), resources: [{id: fixture, repo: fixture/repo, filename: client.bin, assetPattern: '^v2rayN-windows-64[.]zip$'}]}
			let state_path = ($temp | path join state.json)
			with-env {PATH: ($env.PATH | prepend $mocks), TEST_ASSET: $file, TEST_RELEASE: $release_path} {
				update-resources $runtime $state_path
				ensure ((open $state_path).resources.fixture.failureCount == 0) 'Updater did not record success'
				write-json $release_path ($release | update assets.0.id 3 | update assets.0.digest 'sha256:00')
				for attempt in 1..3 { rejects { update-resources $runtime $state_path } }
				ensure (open $state_path).resources.fixture.disabled 'Updater did not disable failing resource'
				ensure (validate-download ($destination | path join client.bin) 5 $digest) 'Failed update overwrote last good asset'
				update-resources $runtime $state_path
				ensure ((open $state_path).resources.fixture.failureCount == 3) 'Disabled resource was retried'
			}
			print 'PASS offline updater: download, atomic replacement, failure isolation and disabling'
		}


		# Test the effective SSH policy without changing the host configuration
		if (which sshd | is-not-empty) and $nu.os-info.name != windows {
			let host_key = ($temp | path join host_key)
			checked -- ssh-keygen -q -t ed25519 -N '' -f $host_key
			let include = ($temp | path join deployment.conf)
			ssh-config 22222 | save $include
			let ssh_config_path = ($temp | path join sshd_config)
			let base = $"HostKey ($host_key)\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nPermitRootLogin yes\n"
			prioritize-ssh-include $base $include | save $ssh_config_path
			ssh-policy 22222 --config $ssh_config_path
			$"\nMatch User root\n    PasswordAuthentication yes\n" | save --append $ssh_config_path
			rejects { ssh-policy 22222 --config $ssh_config_path }
			print 'PASS effective SSH configuration and conflict rejection'
		}
	}
	print 'All local regression checks passed'
}

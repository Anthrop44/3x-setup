use ../../lib/core.nu ensure

# 校验ML-KEM-768 xorpub加解密参数的格式和密钥长度
export def validate-vless-encryption [settings: record] {
	# ML-KEM-768 authentication uses a 64-byte seed and a 1184-byte public key
	ensure (($settings.decryption? | default '') =~ '^mlkem768x25519plus[.]xorpub[.][0-9]+(-[0-9]+)?s([.][0-9]+-[0-9]+-[0-9]+)*[.][A-Za-z0-9_-]{86}$') 'Invalid ML-KEM-768 (xorpub) decryption'
	ensure (($settings.encryption? | default '') =~ '^mlkem768x25519plus[.]xorpub[.][01]rtt([.][0-9]+-[0-9]+-[0-9]+)*[.][A-Za-z0-9_-]{1579}$') 'Invalid ML-KEM-768 (xorpub) encryption'
}

# 从面板响应中选择并校验唯一的ML-KEM-768 xorpub密钥对
export def select-vless-encryption [response: record] {
	let auths = ($response.auths? | default [] | where {|auth| $auth.id? == mlkem768_xorpub })
	ensure (($auths | length) == 1) 'Expected one ML-KEM-768 (xorpub) key pair from 3X-UI'
	validate-vless-encryption $auths.0
	$auths.0 | select decryption encryption
}

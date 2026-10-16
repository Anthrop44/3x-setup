use ../remote/lib/core.nu [ensure capture checked]

# 校验密钥类型为Ed25519或Ed25519-SK，并返回SHA-256指纹
def fingerprint [path: string] {
	let line = (capture -- ssh-keygen -l -f $path -E sha256 | str trim)
	ensure ($line =~ '\(ED25519(-SK)?\)$') $"Expected an Ed25519 key: ($path)"
	$line | split row --regex '\s+' | get 1
}

# 准备部署密钥并导出公钥，拒绝覆盖不匹配的现有密钥
export def initialize-key [project: string] {
	let private = ($project | path join id_ed25519)
	let public = ($project | path join remote id_ed25519.pub)
	if ($public | path exists) {
		ensure ($private | path exists) 'Remote public key exists but local private key is missing'
		ensure ((fingerprint $private) == (fingerprint $public)) 'Refusing to overwrite a mismatched public key'
		return
	}
	let create = (not ($private | path exists))
	if $create {
		ensure (not ($"($private).pub" | path exists)) 'An orphaned id_ed25519.pub already exists'
		checked -- ssh-keygen -q -t ed25519 -f $private -C https://github.com/Anthrop44/3x-setup -N ''
	}
	let key = (capture -- ssh-keygen -y -f $private | str trim)
	ensure ($key =~ '^(ssh-ed25519|sk-ssh-ed25519@openssh\.com)\s+') 'Expected an Ed25519 private key'
	$"($key)\n" | save --force $public
	if $create { rm --force $"($private).pub" }
}

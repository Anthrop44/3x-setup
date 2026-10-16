const ROOT = path self | path dirname | path dirname
use core.nu ensure

# 根据远端根目录返回配置、状态、日志和模板的绝对路径
export def project-paths [directory: string] {
	let root = ($directory | path expand)
	{
		root: $root
		main: ($root | path join main.nu)
		config: ($root | path join config.json)
		constants: ($root | path join constants.json)
		state: ($root | path join paths.json)
		jobs: ($root | path join jobs)
		log: ($root | path join log)
		caddyTemplate: ($root | path join templates Caddyfile.template)
	}
}

# 加载配置和常量，组合路径及功能开关为执行上下文
export def context [directory: string, no_tls: bool, no_app: bool] {
	let paths = (project-paths $directory)
	{dir: $paths.root, paths: $paths, config: (open $paths.config), constants: (open $paths.constants), noTLS: $no_tls, noAPP: $no_app}
}

# 校验仓库中两个schema使用的全部断言
# format仅作注解，IP和域名格式另由schema中的显式pattern校验
export def validate-schema [value: any, schema: record, location: string = '$'] {
	if 'type' in $schema {
		let actual = ($value | describe)
		let valid = (match $schema.type {
			object => ($actual starts-with record)
			array => (($actual starts-with list) or ($actual starts-with table))
			integer => ($actual == int)
			number => ($actual in [int float])
			string => ($actual == string)
			boolean => ($actual == bool)
			null => ($value == null)
			_ => { error make {msg: $"Unsupported schema type: ($schema.type)"} }
		})
		ensure $valid $"($location): expected ($schema.type)"
	}
	if 'enum' in $schema { ensure ($value in $schema.enum) $"($location): value is outside enum" }
	if 'not' in $schema {
		let matches = (try { validate-schema $value $schema.not $location; true } catch { false })
		ensure (not $matches) $"($location): forbidden value"
	}
	if 'oneOf' in $schema {
		let count = ($schema.oneOf | where {|branch| try { validate-schema $value $branch $location; true } catch { false } } | length)
		ensure ($count == 1) $"($location): must match exactly one schema branch"
	}
	if ($schema.type? | default '') == object {
		let properties = ($schema.properties? | default {})
		for key in ($schema.required? | default []) { ensure ($key in $value) $"($location).($key): required" }
		for entry in ($value | transpose key value) {
			if $entry.key in $properties {
				validate-schema $entry.value ($properties | get $entry.key) $"($location).($entry.key)"
			} else {
				ensure ($schema.additionalProperties? != false) $"($location).($entry.key): unknown property"
			}
		}
	}
	if ($schema.type? | default '') == array {
		if ($schema.uniqueItems? | default false) { ensure (($value | uniq | length) == ($value | length)) $"($location): duplicate items" }
		if 'minItems' in $schema { ensure (($value | length) >= $schema.minItems) $"($location): too few items" }
		if 'items' in $schema { for item in ($value | enumerate) { validate-schema $item.item $schema.items $"($location)[($item.index)]" } }
	}
	if ($schema.type? | default '') == string {
		if 'minLength' in $schema { ensure (($value | str length) >= $schema.minLength) $"($location): too short" }
		if 'maxLength' in $schema { ensure (($value | str length) <= $schema.maxLength) $"($location): too long" }
	}
	if 'pattern' in $schema { ensure ($value =~ $schema.pattern) $"($location): invalid format" }
	if 'minimum' in $schema { ensure ($value >= $schema.minimum) $"($location): below minimum" }
	if 'maximum' in $schema { ensure ($value <= $schema.maximum) $"($location): above maximum" }
}

# 校验配置schema及名称、域名、文件名和端口冲突，可要求字段完整
export def validate-config [config: record, constants: record, --complete] {
	validate-schema $config (open ($ROOT | path join config.schema.json)) config
	validate-schema $constants (open ($ROOT | path join constants.schema.json)) constants
	ensure ($config.clients | is-not-empty) 'clients must not be empty'
	for key in [client path] {
		let values = ($config.clients | each {|c| $c | get --optional $key } | compact | each { str lowercase })
		ensure (($values | uniq | length) == ($values | length)) $"Duplicate client ($key)"
	}
	let domains = ([$config.cdnDomain] | append ($config.cdnOptDomains? | default []) | each { str lowercase })
	ensure (($domains | uniq | length) == ($domains | length)) 'cdnOptDomains must be unique and exclude cdnDomain'
	let filenames = ($constants.proxyClientsFilenames | values)
	ensure (($filenames | each { str lowercase } | uniq | length) == ($filenames | length)) 'Duplicate proxy client filename'
	for name in $filenames { ensure ($name =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$') 'Unsafe proxy client filename' }
	let ports = ([$constants.directXhttpPort $constants.fakeSitePort $constants.xhttpPort $constants.subscriptionPort $constants.'3xpanelPort' $config.cdnPort 80 443] | append (if 'sshPort' in $config { [$config.sshPort] } else { [] }))
	ensure (($ports | uniq | length) == ($ports | length)) 'Deployment ports must be unique'
	if $complete {
		for key in [sshPort subscriptionPath distributionPath] { ensure ($key in $config) $"Missing ($key); run init.nu first" }
		ensure ($config.clients | all {|c| 'path' in $c }) 'Missing client subscription path'
		ensure ($config.clients | all {|c| 'password' in $c }) 'Missing client distribution password'
	}
}

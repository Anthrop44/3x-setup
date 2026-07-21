#!/bin/bash

# Caddyfile公共函数

write_file_tls_config() {
	# 写入Caddy文件证书TLS配置
	local output_path="$1"

	printf 'tls %s %s\n' "$DIRECT_CERT_FILE" "$DIRECT_KEY_FILE" >"$output_path"
}

render_caddyfile() {
	# 渲染Caddyfile模板
	sed \
		-e "s|{{AUTO_HTTPS_CONFIG}}|$AUTO_HTTPS_CONFIG|g" \
		-e "s|{{DIRECT_DOMAIN}}|$DIRECT_DOMAIN|g" \
		-e "s|{{CDN_DOMAIN}}|$CDN_DOMAIN|g" \
		-e "s|{{CDN_PORT}}|$CDN_PORT|g" \
		-e "s|{{SUBSCRIPTION_URI_PATH}}|$SUBSCRIPTION_URI_PATH|g" \
		-e "s|{{SUBSCRIPTION_PORT}}|$SUBSCRIPTION_PORT|g" \
		-e "s|{{XHTTP_PATH}}|$XHTTP_PATH|g" \
		-e "s|{{XHTTP_PORT}}|$XHTTP_PORT|g" \
		-e "s|{{FAKE_SITE_PORT}}|$FAKE_SITE_PORT|g" \
		-e "s|{{REALITY_TARGET_PORT}}|$REALITY_TARGET_PORT|g" \
		"$SCRIPT_DIR/Caddyfile.template" | awk \
		-v direct_tls_path="$DIRECT_DOMAIN_TLS_CONFIG_PATH" '
			function print_file(path, indent, line) {
				# 输出TLS配置文件
				while ((getline line < path) > 0) {
					print indent line
				}
				close(path)
			}
			{
				if (index($0, "{{DIRECT_DOMAIN_TLS_CONFIG}}") > 0) {
					indent = $0
					sub(/\{\{DIRECT_DOMAIN_TLS_CONFIG\}\}.*/, "", indent)
					print_file(direct_tls_path, indent)
				} else {
					print
				}
			}'
}

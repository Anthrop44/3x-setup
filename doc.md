# 开发文档

- vless+Reality+Vision直连“偷自己”
- vless+XHTTP+Cloudflare CDN“偷自己”

主要在Debian 13 minimal上测试，理论上应兼容所有Debian系Linux Server

## 执行顺序

1. init.ps1
2. root-init.sh
3. user-init.sh
4. service-check.sh
5. caddy-init.sh
6. caddy-check.sh
7. 3x-panel-init.sh
8. 3x-panel-check.sh
9. 3x-inbound-init.sh
10. 3x-inbound-check.sh
11. 3x-client-init.sh
12. 3x-client-check.sh
13. direct-tls-init.sh
14. direct-tls-check.sh
15. get-log.ps1

## 基本架构

- client get subscription
	- client -> {cdnDomain}/{subscriptionPath}/{subscriptionID}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{subscriptionPort}
	- 3x-ui subscription
- XHTTP with Cloudflare CDN
	- client -> {cdnDomain}/{xhttpPath}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{xhttpPort}
	- Xray (XHTTP)
- Reality Direct Connection
	- client -> {directDomain}:443
	- vps -> 127.0.0.1:443
	- Xray (Reality)
- directDomain cert
	- CA -> {directDomain}:80
	- Caddy (ACME HTTP-01 cert for {directDomain})
- GFW detection: {cdnDomain}
	- GFW -> {cdnDomain}/{*}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{FAKE_SITE_PORT}
	- Caddy (fake site)
- GFW detection: {directDomain}
	- GFW -> {directDomain}:443
	- vps -> 127.0.0.1:443
	- Xray -> 127.0.0.1:{FAKE_SITE_PORT}
	- Caddy (fake site)

## 3x-ui面板设置

- 数据库类型：`SQLite`
- 自定义面板端口：`{3xpanelPort}`
- SSL证书：`跳过`
- 面板只监听`127.0.0.1`

## Reality入站

- 基础配置
	- 协议：`vless`
	- 地址：`0.0.0.0`
	- 分享地址策略：`自定义`
	- 自定义分享地址：`{directDomain}`
	- 端口：443
- 协议
	- 解密：`none`
	- 加密：`none`
- 传输 > 传输：`RAW`
- 安全 > 安全：`Reality`
	- 目标：`127.0.0.1:{realityTargetPort}`
	- SNI：`{directDomain}`
- 嗅探 > 启用：`Enabled`
	- HTTP：`Enabled`
	- TLS：`Enabled`
	- QUIC：`Enabled`
	- FAKEDNS：`Disabled`

## XHTTP入站

- 基础配置
	- 协议：`vless`
	- 地址：`127.0.0.1`
	- 分享地址策略：`入站监听地址`
	- 端口：`{xhttpPort}`
- 协议
	- 解密：`none`
	- 加密：`none`
- 传输
	- 传输：`XHTTP`
	- 路径：`{xhttpPath}`
	- 模式：`auto`
	- 外部代理 > `Enabled`
		- 强制TLS：`TLS`
		- 地址：`{cdnDomain}`
		- 端口：`443`
		- SNI：`{cdnDomain}`
- 安全 > 安全：`无`
- 嗅探 > 启用：`Enabled`
	- HTTP：`Enabled`
	- TLS：`Enabled`
	- QUIC：`Enabled`
	- FAKEDNS：`Disabled`

## Caddy配置

- 80：给{directDomain}做ACME HTTP-01签发和续期，默认返回伪装站
- {CDN_PORT}：订阅和XHTTP路径反代到对应服务，其他Host和路径默认返回伪装站
- 127.0.0.1:{realityTargetPort}：触发{directDomain}证书自动化，不对公网开放
- {FAKE_SITE_PORT}：只提供伪装站

## 系统网络配置

- UFW只允许Cloudflare IP段访问{CDN_PORT}
- UFW开放80给Caddy完成{directDomain}的ACME HTTP-01签发和续期
- UFW开放443给Xray Reality直连入口
- 内核启用BBR拥塞控制，持久配置写入`/etc/sysctl.d/99-3x-bbr.conf`

## hints

初始化阶段{directDomain}还没有TLS证书，因此存在DNS劫持风险，不能取代{ip}

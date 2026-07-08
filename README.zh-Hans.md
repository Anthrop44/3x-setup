# 3X-UI一键部署脚本

最好用的基于3X-UI的代理服务器一键部署脚本。一键完成服务器安全性加固、伪装站搭建、Xray入站创建、3X-UI客户端同步和TLS证书管理等，100%透明开源可审计。**如果你觉得这个repo对你有帮助，可以点个Star和Fork，谢谢！**

本方案基于3X-UI API在同一台服务器上部署多个“偷自己”方案：
- Hysteria2直连
- VLESS+Reality+Vision直连
- VLESS+XHTTP+Cloudflare CDN（优选ip）
- VLESS+XHTTP+Cloudflare CDN（使用自己的Cloudflare域名）

本方案需要一台内存至少500MB、使用Debian 13或更高版本操作系统的专用代理服务器和本地Windows环境（虽然用AI稍改一下也能适配其它操作系统）

以下是使用教程，不详细介绍原理。有命令行基础的用户可以阅读开发文档`doc.md`

## Cloudflare设置

- 在Cloudflare里创建两个A/AAAA记录，指向代理服务器真实ip
	- `cdnDomain`走Cloudflare CDN回源，开启小橙云
	- `directDomain`关闭小橙云
- 设置`cdnDomain`高位回源端口，记为`cdnPort`
- SSL/TLS加密模式选择`完全（严格）`
- 启用始终使用HTTPS
- 启用TLS1.3
- 最低TLS版本1.3
- 启用gRPC
- 为`cdnDomain`生成Cloudflare源站ECC证书和私钥
	- 进入`SSL/TLS`->`源站服务器`
	- 点击创建证书
	- 私钥类型选择`ECC`
	- 主机名填`cdnDomain`，也可以填覆盖它的通配符域名
	- 证书格式选择`PEM`
	- 把源站证书保存为`cert.pem`，私钥保存为`key.pem`

`cert.pem`形如：

```pem
-----BEGIN CERTIFICATE-----
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx+xxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxx/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx+xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx+xxxxxxxxx/xxxxxxxx==
-----END CERTIFICATE-----
```

`key.pem`形如：

```pem
-----BEGIN PRIVATE KEY-----
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxx+xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/xx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/xxxxxxxxxxxxxxxxxxxxx
-----END PRIVATE KEY-----
```

如果`cdnDomain`或`directDomain`是子域名，建议同时让主域名和`www`子域名开启小橙云并指向同一服务器，降低根域名裸露带来的指纹风险

## 本地文件准备

先重建代理服务器并把本repo clone到**本地**，然后根据下方指引手动在`remote/`中准备以下文件：

```txt
remote/
	├ cert.pem
	├ key.pem
	├ config.json
	└ fake-site/
		├ index.html
		└ ...
```

---

把上一步从Cloudflare搞到的证书`cert.pem`和私钥`key.pem`放到`remote/`里

---

填写`config.json`时，可先创建

```json
{
	"$schema": "config.schema.json"
}
```

然后根据`remote/config.schema.json`，利用IDE如VS Code的json LSP提示来补全剩下的内容直到没有警告为止，不会的可以问AI

---

准备静态伪装站：（若不会可让AI代写）
- 必须存在`remote/fake-site/index.html`
- 伪装站应像一个正常静态网站，避免只放空白页或明显的测试文本
- 部署时脚本会把整个`remote/fake-site/`复制到服务器，由Caddy在探测路径和fallback路径返回

## 首次部署

在准备好以上所有文件后即可开始部署

在本机安装[PowerShell 7](https://github.com/PowerShell/PowerShell)，确保Windows自带OpenSSH可用，然后执行：

```powershell
pwsh init.ps1
```

`init.ps1`会自动生成密钥对、生成订阅链接、上传文件并启动远端初始化，若需要输入密码按终端提示操作即可。它会在`clients/`中生成包含简单使用教程的订阅链接，可以直接分发给客户。整个服务器初始化过程可能持续5~20分钟，具体时间取决于服务器配置，但在触发远端执行代码后断开SSH连接不会影响服务器继续初始化，所以不需要开着终端干等

## 更新客户信息

若要增删客户或编辑客户信息等，请编辑`remote/config.json`中的`clients`后执行：

```powershell
pwsh sync-clients.ps1
```

脚本会上传新的`remote/config.json`并同步客户端信息，重启Xray，并重新导出本地`clients/*.md`

**`init.ps1`和`sync-clients.ps1`不会修改`remote/config.json`中已有的`clients`键值。因此，只要不丢失`remote/config.json`或更改`cdnDomain`，即使重建服务器也不会丢失任何客户的订阅信息，所以未来若要修改入站甚至更换服务器，客户只需在代理客户端内更新一次订阅，不需要重新获取新的订阅链接**

## 连接3X-UI面板

一般来说本方案不需要手动管理3X-UI面板，但若你确实有需求，可以执行：

```powershell
pwsh ssh-tunnel.ps1
```

然后根据提示登陆3X-UI面板

## Warning

本方案测试时3X-UI版本是v3.4.2。未来若3X-UI API发生变更，可能会出问题，但最好不要为了使用本方案而固定3X-UI版本。万一遇到问题请发issue

本项目不是幂等部署器，需要对重建后的干净服务器执行，不能用于已有业务的服务器

不要泄漏`remote/config.json`等私有配置。**一旦泄漏，请立刻重建服务器并彻底重写`remote/config.json`**

如果要用同一个域名多次重建服务器测试本脚本，请优先使用`pwsh init.ps1 -noTLS`临时使用自签证书以避免触发CA rate limit发不出证书。由于没有公信证书，这种情况下Hysteria2入站不可用。自签证书仅用于测试，**绝对不要长期使用！测试完成后必须立刻重建服务器！**

地区运营商可能会阻断部分ip的QUIC，这会导致Hysteria2入站不可用，属不可抗力

本方案默认面向中国大陆。若您有在其它地区使用的需求，可以编辑`remote/clash-rule.txt`

## 致谢

- [Project X](https://github.com/XTLS/Xray-core)
- [3X-UI](https://github.com/MHSanaei/3x-ui)
- [saas.sin.fan](https://saas.sin.fan/)

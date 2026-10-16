# 3X-UI一键部署脚本

最好用的基于Xray-core和3X-UI的代理服务器一键部署脚本。一键完成服务器安全性加固、伪装站搭建、Xray入站创建、3X-UI客户端同步和TLS证书管理等，100%透明开源可审计。**如果你觉得这个repo对你有帮助，可以点个Star和Fork，谢谢！**

本方案基于3X-UI API在同一台服务器上部署多个同址伪装（“偷自己”）方案：
- VLESS+XHTTP+TLS直连
- VLESS Encryption（ML-KEM-768，xorpub）+Vision+XHTTP+Cloudflare CDN

本方案需要一台专用代理服务器，内存至少1GB、使用新版Debian或Ubuntu操作系统，有独立ip。如果你不知道怎么挑服务器商，可以访问<https://www.nodeseek.com/>（我与该网站无任何关系）

以下是使用教程，不详细介绍原理。有命令行基础的用户可以阅读开发文档`doc.md`

## Cloudflare设置

- 去Cloudflare里买个域名，或把一个域名托管到Cloudflare
- 在Cloudflare里找到这个域名的DNS设置，创建两个A记录（若机器有ipv6，也可以创建AAAA记录），指向代理服务器真实ip
	- `cdnDomain`走Cloudflare CDN回源，开启小橙云
	- `directDomain`关闭小橙云
- 设置`cdnDomain`高位回源端口，记为`cdnPort`
	- 进入`规则` -> `概述` -> `Origin Rules` -> `创建规则`
	- `如果传入请求匹配` -> `自定义筛选表达式` -> 编辑表达式：`http.host in {"cdnDomain"}`（把`cdnDomain`改成你真正的域名）
	- `目标端口`：重写到`cdnPort`
- SSL/TLS加密模式选择`完全（严格）`
- 启用始终使用HTTPS
- 启用TLS1.3
- 最低TLS版本1.3。如果用户要用Windows 10，也可以降为1.2
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
- `remote/fake-site/index.html`必须存在且以`<!doctype html>`开头
- 伪装站应像一个正常静态网站，避免只放空白页或明显的测试文本
- 部署时脚本会把整个`remote/fake-site/`复制到服务器，由Caddy在探测路径和fallback路径返回

## 最小本地环境和部署

在准备好以上所有文件后，在本机[安装Nushell（一种跨平台的Shell，这样Windows、macOS和Linux都能用）](https://www.nushell.sh/zh-CN/book/installation.html)

Windows用户请执行

```ps1
# Winget换源为教育网联合镜像站以便在中国大陆使用，如果你能连winget，这步可以跳过
winget source remove winget
winget source add winget https://mirrors.cernet.edu.cn/winget-source --trust-level trusted
# 安装Nushell
winget install nushell
```

macOS用户请执行
```zsh
brew install nushell
```

Linux用户自己看文档

装好Nushell后就可以开始部署。执行：

```nu
nu init.nu
```

`init.nu`会自动生成密钥对、订阅链接分发页，上传所有远端文件并启动初始化，若需要输入密码按终端提示操作即可。它生成的`clients.tsv`包含每位客户应收到的订阅分发页URL及`Password`列中的八位数字解锁密码，将对应URL和密码发给客户即可。密码自动保存到`remote/config.json`的`clients[].password`，重建和同步时复用，页面不显示明文密码。整个服务器初始化过程通常持续5~15分钟，具体时间取决于服务器配置，但在触发远端执行代码后断开SSH连接不会影响服务器继续初始化，所以不需要开着终端干等

## 更新客户信息和Cloudflare优选域名

若要更改客户信息或增删Cloudflare优选域名，请编辑`remote/config.json`中的`clients`和`cdnOptDomains`后执行：

```nu
nu sync-config.nu
```

脚本会上传新的`remote/config.json`并同步客户端信息和Cloudflare优选域名，重启Xray，并重新导出`clients.tsv`

如需保留普通TLS节点并为每个CDN地址追加ECH H2/H3节点，在`remote/config.json`加入`"cdnEchConfigList": "https://1.1.1.1/dns-query"`即可；删除本字段关闭ECH变体。DoH地址需能由客户端直接访问，CDN域名的Cloudflare HTTPS记录需包含ECH配置。ECH节点保留TLS指纹偏好，Direct节点不变。客户端及其Xray核心需支持ECH，并保留订阅中的`ech`参数，详见`doc.md`。已有部署需先更新远端脚本和schema，仅同步配置不会上传代码

**`init.nu`和`sync-config.nu`不会修改`remote/config.json`中已有的键值，因此只要不丢失或手动修改`remote/config.json`，即使重建服务器也不会丢失客户分发URL或订阅URL。未来若要修改入站甚至更换服务器，客户只需在代理客户端内更新一次订阅，不需要重新获取新的分发URL**

代理客户端更新和错误事件保存在`~/3x-setup/log/fetch-apps-update.log`，可执行`get-log.nu`下载。某项资源连续3个每日任务失败后会被禁用；修复上游或网络问题后，在VPS以root执行`/usr/local/sbin/3x-fetch-apps --reset RESOURCE_ID`，再启动`3x-fetch-apps.service`或等待下一次每日任务；`RESOURCE_ID`就是`proxyClientsFilenames`中对应的键名

订阅中的连接节点统一显示为`Direct h2/h3`、`Cloudflare h2/h3`、`Cloudflare ECH h2/h3`，不同CDN地址允许同名。另有一个信息空节点显示`用户名 已用流量/剩余流量`，随订阅更新统计，无限流量的剩余额度显示`∞`

## 连接3X-UI面板

一般来说本方案不需要手动管理3X-UI面板，但若你确实有需求，可以执行：

```nu
nu ssh-tunnel.nu
```

## 更新软件

若要更新Debian软件包和3X-UI，并立刻检查一次代理客户端更新，请执行：

```nu
nu update-all.nu
```

请定期执行此操作或重新部署代理服务器以跟进上游安全更新

## Warning

本方案可能无法在Windows 10的客户端上使用，因为Windows 10没有完整的TLS 1.3支持

本方案测试时3X-UI版本是v3.10.2，Xray-core版本是v26.10.10。未来若3X-UI API发生变更，可能会出问题，但最好不要为了使用本方案而固定3X-UI版本。万一遇到问题请发issue

本项目不是幂等部署器，需要对重建后的干净服务器执行，不能用于已有业务的服务器

不要泄露`remote/config.json`等私有配置。**一旦泄露，请立刻重建服务器并更换ip和域名**

如果要用同一个域名多次重建服务器测试本脚本，请优先使用`nu init.nu --noTLS`临时使用自签证书以避免触发CA rate limit发不出证书。直连XHTTP节点在生产环境需要公信证书，部署中的本机检查会显式信任初始自签证书。自签证书仅用于测试，**绝对不要长期使用！测试完成后必须立刻重建服务器！**

地区运营商可能会阻断部分ip的QUIC，这会导致直连XHTTP H3节点不可用，H2节点使用TCP

部署及维护均以root运行，工作目录为`/root/3x-setup`。部署完成后，root只允许SSH公钥认证，密码及交互式认证均禁用；您在仓库根目录下的私钥`./id_ed25519`将会是登陆代理服务器的**唯一**方式。请妥善备份和保存之

## 致谢

- [Project X](https://github.com/XTLS)
- [3X-UI](https://github.com/MHSanaei/3x-ui)

## TG群组（闲聊&技术支持）

<https://t.me/+AJmzOqlwGt8xYjI0>

非商业群组，禁止一切营利行为，谢谢理解！

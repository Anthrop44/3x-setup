# 开发文档

所有本地部署、远端部署、检查和维护逻辑均使用Nushell0.116.1+，JSON直接作为record/list处理，不依赖PowerShell、jq或Python

本地依赖Nushell、OpenSSH（ssh、scp、ssh-keygen）、OpenSSL 3和tar；Windows需将这些程序加入PATH，Git for Windows提供的OpenSSL也可使用

## 入口

- `nu init.nu`：首次部署；缺少`remote/config.json`时创建schema骨架并退出
- `nu init.nu --prepare-only`：只完成本地校验、补齐字段、密钥准备与分发页生成，不连接服务器
- `nu init.nu --noAPP --noTLS`：跳过代理应用分发与ACME，用自签证书测试；本机直连检查显式信任初始自签证书
- `nu init.nu --accept-new-host`：在清除重建服务器旧指纹后自动接受新指纹
- `nu sync-config.nu`：同步`clients`、`cdnOptDomains`和`cdnEchConfigList`，其它部署参数必须保持不变
- `nu get-log.nu`：下载所有阶段日志，已有非空`log/`轮转为`log0/`等目录
- `nu ssh-tunnel.nu --startup-timeout-seconds 60`：保留终端交互认证，访问仅本机监听的面板
- `nu update-all.nu`：更新APT软件与3X-UI，并触发已安装的代理客户端更新器

所有入口按脚本路径查找配置与根目录`id_ed25519`，不依赖当前工作目录；`--noAPP`和`--noTLS`采用Nushell双连字符参数语法

## 本地模块

`modules/setup-config.nu`读取schema、补齐`sshPort`、`subscriptionPath`、`distributionPath`、`clients[].path`和`clients[].password`，检查端口、域名、客户名、路径和文件名冲突，已有字段保持不变；密码为八位数字字符串，缺失时生成并保存到`remote/config.json`，重建或同步时复用；配置同步不生成缺失的初始订阅路径或SSH端口

`remote/lib/config.nu`统一管理远端配置和资源路径，并实现这两个schema使用的断言：类型、required、additionalProperties、oneOf、not、enum、pattern、长度、数值范围和uniqueItems；format是注解，域名格式由schema中的pattern验证

`modules/generate-ssh-key.nu`生成或导出Ed25519部署公钥，支持已有Ed25519-SK密钥；私钥缺失或已有公钥不匹配时拒绝覆盖

`modules/client-files.nu`读取XHTML/CSS模板，使用各客户的`password`加密并导出分发页，`clients.tsv`的`Password`列保存对应密码；页面正文使用OpenSSL的PBKDF2-SHA256（100000次、64字节密钥）、AES-256-CBC与HMAC-SHA256加密认证，前32字节用于AES、后32字节用于HMAC，HMAC覆盖IV和密文；浏览器通过WebCrypto先验签再解密。HTML不包含明文密码，用户需输入八位数字密码解锁

`modules/ssh.nu`负责使用`directDomain`构造SSH/SCP目标和远端命令引用；首次部署和所有维护连接均使用该域名，需要提前将其解析到服务器并关闭Cloudflare代理。维护连接使用OpenSSH默认主机验证，SSH返回255时最多尝试一次日志下载，成功后重试。日志下载采用`accept-new`，已有指纹冲突不会被覆盖

## 远端目录与调用边界

```text
remote/
├── bootstrap.sh              # 安装Nu后进入main.nu deploy
├── main.nu                   # deploy、sync、update、check、list-stages
├── workflows/
│   ├── stages.nu             # 阶段名称、说明、实现位置与函数的唯一登记表
│   ├── deploy.nu             # 首次部署步骤
│   ├── sync.nu               # 配置同步步骤与分发目录替换
│   └── update.nu             # APT与3X-UI更新
├── features/
│   ├── system.nu             # 依赖、公钥、SSH、防火墙、BBR及检查
│   ├── caddy/
│   │   ├── mod.nu            # 导出安装与基础检查
│   │   ├── setup.nu
│   │   ├── config.nu         # Caddyfile渲染与安装
│   │   └── tls.nu            # 证书启用与检查
│   ├── panel/
│   │   ├── mod.nu            # 导出面板安装与检查
│   │   ├── setup.nu
│   │   ├── api.nu            # Cookie、CSRF会话与API请求
│   │   ├── inbounds.nu
│   │   ├── hosts.nu          # 直连与CDN的Host组
│   │   ├── clients.nu
│   │   └── encryption.nu
│   └── apps.nu               # 应用分发、下载、状态和检查
├── checks/connectivity.nu    # 跨Caddy、Xray与CDN的端到端检查
├── jobs/                     # systemd入口，只负责参数、权限与锁
│   ├── cloudflare-ufw.nu
│   └── fetch-apps.nu
├── lib/
│   ├── core.nu               # 断言、进程执行、JSON、临时目录与重试
│   ├── config.nu             # 配置校验、context与路径
│   ├── runner.nu             # 阶段子进程、日志、耗时与失败即停
│   ├── systemd.nu
│   └── network.nu
├── templates/Caddyfile.template
├── config.json / config.schema.json
├── constants.json / constants.schema.json
├── cert.pem / key.pem / id_ed25519.pub
└── fake-site/
```

查找业务逻辑从`features/`开始，同一业务的安装或同步函数`apply`与检查函数`verify`放在一起；跨业务链路检查放在`checks/`

调用方向为`main.nu`→`workflows/`→`features/`与`checks/`→`lib/`，定时任务从`jobs/`进入相同业务模块；业务模块不调度工作流，公共库不导入业务模块

工作流只排列需要执行的阶段名，`workflows/stages.nu`统一关联实现函数与源文件；增加部署阶段不会隐式改变同步流程

所有上传文件仍位于`remote/`，本地与远端共用的辅助函数保存在`remote/lib/`，初次部署会完整打包该目录，包括嵌套模块和模板

## 远端执行

`remote/bootstrap.sh`是唯一自有Bash脚本：以root安装curl/GnuPG/sudo等基础依赖，执行Nushell官方Fury源安装命令，再`exec nu --no-config-file ./main.nu deploy`。无人值守APT增加`-y`，GnuPG增加`--batch --yes`

初始SSH命令通过`setsid --wait`启动Bash引导，断线后远端子进程继续执行；引导输出在`log/bootstrap.log`。3X-UI官方安装器仍以其上游发布的Bash格式运行

`remote/main.nu`是统一入口，`workflows/deploy.nu`排列部署阶段，`lib/runner.nu`为每个阶段启动独立的无用户配置Nu进程，stdout/stderr写入`log/{阶段}.log`，记录耗时、完成或失败；失败立即中止后续阶段

执行顺序：`root-init`→`system-init`→`service-check`→`caddy-init`→`caddy-check`→`3x-panel-init`→`3x-panel-check`→`3x-inbound-init`→`3x-inbound-check`→`cf-host-init`→`cf-host-check`→`3x-client-init`→`3x-client-check`→`connectivity-check`→`fetch-apps-init`→`fetch-apps-check`→`direct-tls-init`→`direct-tls-check`

在本地仓库中可以直接列出阶段，不需要root或用户配置：

```nu
nu remote/main.nu list-stages
nu remote/main.nu list-stages --workflow sync
nu remote/main.nu list-stages --noAPP --json
```

在VPS的`/root/3x-setup`中运行诊断命令：

```nu
nu main.nu check clients
nu main.nu check connectivity
nu main.nu check tls
nu main.nu deploy --stage 3x-client-check
nu main.nu deploy --from cf-host-init --noAPP --noTLS
```

`check`支持`system`、`caddy`、`panel`、`inbounds`、`hosts`、`clients`、`connectivity`、`apps`和`tls`，只执行检查逻辑；连通性检查会创建并清理临时测试进程

`--noAPP`省略两个fetch-apps阶段，`--noTLS`仍执行TLS检查但不接触CA；`--from`和`--stage`是显式排障工具，不是自动恢复机制，首次部署不幂等，不应盲目重跑已完成的初始化阶段

`root-init`安装依赖和root公钥，`system-init`优先加载`00-3x-setup.conf`，校验sshd实际配置后才重启；SSH只接受公钥，UFW只开放80/tcp、443/tcp、443/udp和SSH端口，CDN回源端口仅对Cloudflare网段开放，启用BBR

`caddy-init`安装伪装站、Cloudflare源站证书与直连自签证书，生成XHTTP路径并渲染Caddyfile；`3x-panel-init`安装面板、启用本机订阅服务和Happy Eyeballs；随后通过CSRF/Cookie会话同步`Direct`、`Cloudflare`两个本机XHTTP入站、H2/H3 Host组和客户。直连入站的`decryption`和`encryption`均为`none`，通过`disableFlow: true`禁用Vision；CDN入站通过`getNewVlessEnc`生成并选择`mlkem768_xorpub`，将私有`decryption`和公开`encryption`保存到面板入站设置，客户使用Vision流控；检查会验证两类策略、ML-KEM-768密钥长度和xorpub模式

`3x-client-check`校验所有客户端配额、入站关联、订阅中的公网443端口、直连无VLESS加密与无flow、CDN加密参数与Vision流控

`connectivity-check`校验Xray状态和监听地址，启动临时Xray/SOCKS实例分别执行两个XHTTP后端的本机回环、Caddy直连H2/H3与Cloudflare公网H2/H3端到端测试，直连使用`encryption=none`与空flow，CDN使用入站的公开加密参数与Vision；直连检查同时信任初始自签证书与系统根证书，兼容ACME前的首次部署和生产配置同步，结束或失败时清理临时进程

`direct-tls-check`比较每个fallback入口与已安装伪装站首页，检查HTTP跳转、服务和失败单元；按已安装Caddyfile选择当前证书来源，ACME启用后即使配置同步使用`--noTLS`也会检查公信证书、域名、证书私钥匹配和系统信任链，不再依赖初始自签证书的有效期

## 定时任务

所有systemd任务直接执行Nu，依赖脚本保存在`/root/3x-setup`，不要删除该目录

- `jobs/cloudflare-ufw.nu`：通过`features/system.nu`下载并校验官方IPv4/IPv6列表后刷新UFW回源规则，flock防止并发
- `jobs/fetch-apps.nu`：通过`features/apps.nu`精确匹配GitHub稳定release的asset，检查大小和可用SHA-256，在同目录下载后原子替换；状态保存在`/var/lib/3x-fetch-apps/state.json`，错误和更新记录在`log/fetch-apps-update.log`。元数据失败或下载失败均按资源累计，连续3次失败后禁用，保留旧文件；`/usr/local/sbin/3x-fetch-apps --reset RESOURCE_ID`恢复资源

直连TLS完全由Caddy终止并自动续期，无需证书同步timer或因续期重启Xray；`features/caddy/tls.nu`提供证书与私钥校验

每日任务均按`dailyTaskHour`运行，附加0到1小时随机延迟，`Persistent=true`

## 配置同步与日志

`sync-config.nu`将配置和完整分发目录打包上传到唯一暂存目录，远端再次校验配置，只允许更改客户、优选域名和`cdnEchConfigList`；systemd临时服务在SSH断开后继续同步。API检查通过后才替换线上分发目录，保留旧目录直到替换成功

`workflows/sync.nu`显式执行`cf-host-init`→`cf-host-check`→`3x-client-init`→`3x-client-check`→`connectivity-check`→`direct-tls-check`，不再从部署流程中途运行到末尾；同步不申请证书，TLS检查根据正在使用的Caddyfile选择证书来源

本地`sync-config.nu`和`update-all.nu`分别调用远端`main.nu sync`和`main.nu update`；日常同步只上传配置与分发目录

部署或同步失败不会自动重试已经执行的有副作用阶段。引导未完成或SSH端口尚未切换时，`get-log.nu`可能无法连接，需要通过初始SSH端口查看`/root/3x-setup/log/bootstrap.log`

## 本地验证

运行`nu --no-config-file tests/run.nu`：解析全部Nu代码并检查Bash语法，验证工作流选择、配置字段稳定性和变更限制、Caddy模板渲染、API payload、Host组、订阅、代理测试配置、下载校验、失败计数与重置

测试通过临时Nu进程验证阶段失败即停、stdout/stderr日志、`--from`和开关传递；通过临时目录中的命令替身验证更新任务的重置与真实flock冲突；还会打包解包远端目录，验证脱离本地模块、配置和当前工作目录后仍可列出阶段，并用临时配置验证真实入口的阶段调度与`--noTLS`传递

测试依赖Nu、OpenSSL、tar、Bash、chmod和flock，所有测试数据写入临时目录，不修改系统配置或连接VPS

## 网络架构

- client get distribution page
	- client -> {cdnDomain}/{distributionPath}/{clientPath}.html:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> /var/www/3x-fake-site/{distributionPath}/{clientPath}.html
- client get subscription
	- client -> {cdnDomain}/{subscriptionPath}/{subscriptionID}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{subscriptionPort}
	- 3X-UI subscription
- client download proxy application
	- by cdn
		- client -> {cdnDomain}/{subscriptionPath}{proxyClientsSuffix}/{proxyClientFilename}:443
		- Cloudflare cdn -> ip:{CDN_PORT}
		- vps -> 127.0.0.1:{CDN_PORT}
		- Caddy -> /var/www/3x-fake-site/{subscriptionPath}{proxyClientsSuffix}/{proxyClientFilename}
	- direct
		- client -> {directDomain}/{subscriptionPath}{proxyClientsSuffix}/{proxyClientFilename}:443
		- Caddy -> /var/www/3x-fake-site/{subscriptionPath}{proxyClientsSuffix}/{proxyClientFilename}
- XHTTP TLS Direct Connection
	- H2: client -> {directDomain}/{xhttpPath}:443/tcp
	- H3: client -> {directDomain}/{xhttpPath}:443/udp
	- Caddy (TLS termination, H2/H3)
	- Caddy -> 127.0.0.1:{directXhttpPort} (h2c)
	- Xray (VLESS + XHTTP, encryption=none, flow empty)
- XHTTP with Cloudflare CDN
	- client -> {cdnDomain}/{xhttpPath}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{xhttpPort} (h2c)
	- Xray (XHTTP + VLESS Encryption ML-KEM-768 xorpub + Vision)
- directDomain cert
	- noTLS：脚本生成自签测试证书，不访问CA
	- TLS：direct-tls-init.nu触发ACMEHTTP-01，为{directDomain}申请公信证书；Caddy自动续期并加载新证书
- GFW detection: {cdnDomain}
	- GFW -> {cdnDomain}/{*}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{FAKE_SITE_PORT}
	- Caddy (fake site)
- GFW detection: {directDomain}
	- GFW -> {directDomain}:443/tcp or 443/udp
	- Caddy (TLS termination, H1/H2/H3)
	- Non-XHTTP paths -> /var/www/3x-fake-site

## 3X-UI面板设置

3X-UI通过官方脚本安装，数据库类型为SQLite；面板端口来自`3xpanelPort`，面板路径来自`3xpanelUriPath`，面板用户名和密码来自`3xusername`与`3xpassword`

面板SSL模式为无，因为公网不直接访问面板；面板监听地址强制设置为`127.0.0.1`，需要通过`ssh-tunnel.nu`访问

订阅功能启用，json订阅关闭；订阅服务监听`127.0.0.1:subscriptionPort`，普通路径为`/subscriptionPath/`，反向代理URI为`https://cdnDomain/subscriptionPath/`

订阅加密开启，显示流量信息，客户端应用中的订阅更新间隔来自`subUpdates`，备注模板为`{{HOST}}|{{EMAIL}} {{TRAFFIC_USED}}/{{TRAFFIC_LEFT}}`，通过分段避免空字段留下多余空格。开启`subInfoNodeEnable`，关闭`subShowIdentityOnAllLinks`：连接节点只显示Host备注，首个空节点单独显示`用户名 已用流量/剩余流量`；无限流量的剩余额度显示`∞`。该项由3X-UI原生生成`127.0.0.1:1080`的SOCKS占位链接，随订阅更新统计，不创建真实Xray监听。订阅标题和公告写为“请勿分享！”

Xray模板会确保存在`tag=direct`的`freedom`出站，并在`sockopt`中写入Happy Eyeballs设置，减少双栈解析和连接时的异常延迟

## 3X-UI客户端

- `remote/config.json`的clients决定需要批量创建的客户端
- `client`：3X-UI客户端名
- `path`：客户端订阅ID，作为订阅链接中的`{subscriptionID}`
- `password`：分发页解锁密码，八位数字字符串，可含前导零；缺失时自动生成，重建和同步时复用已有值
- 每个客户端会关联`Direct`和`Cloudflare`两个入站；直连与每个CDN地址均生成独立的H2/H3节点
- 配置`cdnEchConfigList`时，每个CDN地址额外生成ECH H2/H3节点，普通TLS节点及其Host组ID、排序和指纹保持不变
- `traffic`：可选，每月流量上限，单位GB；缺省或0表示不限量

## VLESS XHTTP入站

`Direct`与`Cloudflare`均使用下列配置，分别由Caddy直连入口和Cloudflare回源入口反代

- 基础配置
	- 备注：`Direct`或`Cloudflare`
	- 协议：`vless`
	- 地址：`127.0.0.1`
	- 分享地址策略：`入站监听地址`，公网地址、端口和TLS由Host组覆盖
	- 端口：`Direct`为`{directXhttpPort}`，`Cloudflare`为`{xhttpPort}`
- 协议
	- `Direct`：解密与加密均为`none`，`disableFlow: true`，订阅与Xray客户端flow留空；公网加密由自己的Caddy TLS承担
	- `Cloudflare`：由`getNewVlessEnc`生成`mlkem768_xorpub`密钥对，客户端流控为`xtls-rprx-vision`，保护经过Cloudflare的内层代理数据
	- 面板客户保存的Vision偏好仅在CDN入站生效，直连入站显式禁用
	- 不包含`fallbacks`字段，网站回落由Caddy按路径处理
- 传输
	- 传输：`XHTTP`
	- 路径：`{xhttpPath}`
	- 模式：`auto`
- 安全：`无`，本机后端使用h2c，公网TLS由Caddy终止
- 嗅探：启用HTTP、TLS和QUIC，禁用FAKEDNS

## XHTTP主机

- 直连Host组：`Direct h2`和`Direct h3`
	- 入站：`Direct`
	- 地址和SNI：`{directDomain}`
	- 端口：`443`
	- 安全：`tls`
	- ALPN：分别仅为`h2`和`h3`
	- 指纹：`{fingerprint}`

- 对`cdnOptDomains`中的每个域名按数组顺序创建两个Host组
	- 备注：统一为`Cloudflare h2`、`Cloudflare h3`，不同地址允许同名，Host组ID仍各自独立
	- 基本
		- 入站：`Cloudflare`
		- 地址：`{cdnOptDomains[i]}`
		- 端口：`443`
	- 安全
		- 安全：`tls`
		- SNI：`{cdnDomain}`
		- ALPN：H2 Host仅为`h2`，H3 Host仅为`h3`
		- 指纹：`{fingerprint}`
- 原生CDN地址的备注同样为`Cloudflare h2`和`Cloudflare h3`
	- 基本
		- 入站：`Cloudflare`
		- 地址：`{cdnDomain}`
		- 端口：`443`
	- 安全
		- 安全：`tls`
		- SNI：`{cdnDomain}`
		- ALPN：分别仅为`h2`和`h3`
		- 指纹：`{fingerprint}`

### Cloudflare ECH

在`remote/config.json`增加`"cdnEchConfigList": "https://1.1.1.1/dns-query"`可为原生及优选CDN地址追加ECH节点；删除该字段关闭ECH变体。DoH地址必须能由客户端直接访问，Xray按`cdnDomain`的HTTPS记录动态获取ECHConfigList并按TTL缓存，也支持Xray的固定Base64配置及`域名+DNS地址`格式

Cloudflare边缘需启用ECH，并为`cdnDomain`提供含`ech`参数的HTTPS记录。ECH节点的SNI和HTTP Host仍是`cdnDomain`，连接地址仍可使用优选域名；外层SNI由Cloudflare的ECH配置决定。保留`fingerprint`设置不代表握手字节不变，ECH会引入内外层ClientHello

普通Host组的`echConfigList`为空；ECH组在原ID末尾追加`ech`，备注统一为`Cloudflare ECH h2`、`Cloudflare ECH h3`，统一排在普通组后。所有CDN节点名称都不包含Vanilla、OPT、用户名或流量，直连仅显示`Direct h2`、`Direct h3`。3X-UI通过订阅链接的`ech`参数下发配置，客户端及其Xray核心需支持ECH与对应指纹组合，导入后应确认ECH设置未被丢弃

ECH终止于Cloudflare，不改变Caddy源站证书、回源设置和Xray入站。Direct节点仍只使用普通TLS。连通性检查覆盖每个CDN地址的普通及ECH H2/H3链路；Xray获取ECH配置失败时应使连接失败，不能将普通TLS连通视为ECH测试成功

已有部署需要先更新远端相关脚本和schema，并按上文配置面板订阅备注模板及信息空节点，才能使用新字段及节点展示；`sync-config.nu`仅上传配置及分发目录，不更新远端代码或面板全局设置。首次部署会完成这些设置

## Caddy配置

`remote/templates/Caddyfile.template`由`remote/features/caddy/config.nu`通过字面占位符替换渲染，最终安装到`/etc/caddy/Caddyfile`

全局配置在初始阶段是`auto_https disable_redirects`，避免Caddy自动处理不需要的HTTPS重定向；公信TLS阶段改为`auto_https disable_redirects ignore_loaded_certs`，让Caddy忽略已加载的文件证书并为`directDomain`走ACME签发

`:80`只做永久跳转，把任意Host的HTTP请求跳到同Host的HTTPS路径；这个入口同时支持ACMEHTTP-01，因为Caddy会接管挑战路径

`:fakeSitePort`只在本机或内部链路中提供伪装站文件，根目录为`/var/www/3x-fake-site`

`directDomain:443`监听公网443/tcp与443/udp，支持H1/H2/H3；`/xhttpPath*`通过h2c反代到`127.0.0.1:directXhttpPort`，其余路径提供伪装站。初始阶段使用`/etc/caddy/3x-direct-*.pem`自签文件证书；公信TLS阶段切换为ACMEHTTP-01，之后由Caddy自动续期，不再向Xray复制证书

`:cdnPort`使用Cloudflare源站证书`/etc/caddy/3x-origin-*.pem`；`/subscriptionPath/*`反代到`127.0.0.1:subscriptionPort`，`/xhttpPath*`通过h2c反代到`127.0.0.1:xhttpPort`，其他路径由伪装站`file_server`返回，因此`/{subscriptionPath}{proxyClientsSuffix}/*`中的客户端文件无需额外Caddy路由即可下载

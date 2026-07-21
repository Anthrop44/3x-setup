# 开发文档

**本文档由AI生成并经过人工粗略检查，若发现bug请发issue**

本方案默认安全，不需要任何额外加固，服务器只对公网暴露80、443和自定义SSH端口，对Cloudflare ip段暴露自定义高位cdn回源端口。3X-UI面板不暴露公网，通过SSH通道访问。普通HTTP(S)访问和主动探测会回落到本机自托管的伪装站。XHTTP和订阅链接隐藏路径由脚本自动随机生成以确保无特征隐蔽性

默认完整执行顺序：`init.ps1` > 上传`remote/`触发远端执行 > `root-init.sh` > `user-init.sh` > `service-check.sh` > `caddy-init.sh` > `caddy-check.sh` > `3x-panel-init.sh` > `3x-panel-check.sh` > `3x-inbound-init.sh` > `3x-inbound-check.sh` > `cf-host-init.sh` > `cf-host-check.sh` > `3x-client-init.sh` > `3x-client-check.sh` > `fetch-apps-init.sh` > `fetch-apps-check.sh` > `direct-tls-init.sh` > `direct-tls-check.sh` > 回到本地Windows环境 > `get-log.ps1`

## 配置文件

`remote/config.json`保存用户私有敏感配置。`{"$schema": "config.schema.json"}`

`remote/constants.json`保存非敏感配置。`{"$schema": "constants.schema.json"}`

## 本地脚本和模块

`init.ps1`是首次部署入口。若`remote/config.json`不存在，它会先创建仅包含`{"$schema": "config.schema.json"}`的初始文件并成功退出，等待用户填写配置后再次执行；配置文件已存在时，它会导入`modules/generate-ssh-key.psm1`并调用`Initialize-DeploymentSshKey`准备部署所需的`remote/id_ed25519.pub`，检查`cert.pem`、`key.pem`、`id_ed25519.pub`和`fake-site/index.html`存在且正确，再通过`modules/setup-config.psm1`校验`remote/config.json`和`remote/constants.json`，自动补齐`sshPort`、`subscriptionPath`、`distributionPath`和`clients[].path`，检查部署端口、客户端名、客户订阅路径和代理客户端固定文件名不重复，随后写回`remote/config.json`并调用`modules/client-files.psm1`导出加密的`remote/fake-site/{distributionPath}/{clients.path}.html`、同目录`template.css`及根目录`clients.tsv`；所有文件生成完成后，将`remote/`中的文本文件统一为LF

上传阶段使用Windows OpenSSH的`scp`和`ssh`；脚本把`remote/`打包成`3x-setup.tar`上传到root家目录，再通过`ssh root@ip`启动`root-init.sh`，允许用户在终端中交互输入密码，并用`StrictHostKeyChecking=no`和`UserKnownHostsFile=NUL`直接跳过OpenSSH主机指纹确认；远端服务器root已绑定本地公钥时也可非交互执行；`init.ps1`从开始执行远端命令起计时，在SSH正常退出后输出远端初始化耗时，再执行`get-log.ps1`

`pwsh init.ps1 -noTLS`会把`--noTLS`传给远端链路；Caddy仍会安装`directDomain`自签测试证书并完成Reality/XHTTP检查，但`direct-tls-init.sh`不会渲染ACME配置，也不会访问CA；该模式下HY2入站不可用

`pwsh init.ps1 -noAPP`会把`--noAPP`传给远端链路，`3x-client-check.sh`会跳过`3x-fetch-apps`代理客户端静态分发，直接执行`direct-tls-init.sh`

---

`get-log.ps1`负责日志下载；它让远端把`~/3x-setup/log/`打包到`/tmp`，用SFTP下载到本地，再解包到`log/`；如果本地`log/`非空，会先轮转为`log0/`、`log1/`等目录，避免覆盖上一次结果。如果失败，请检查并放通云服务器商的防火墙设置，因为本方案自带端口加固

---

`sync-config.ps1`用于已有服务器的客户和Cloudflare优选域名同步；它与`init.ps1`复用同一套schema校验和自动字段补齐逻辑，会补齐缺失的`distributionPath`和`clients[].path`，但要求初始部署生成的`subscriptionPath`已经存在；随后用OpenSSH/SFTP上传`remote/config.json`和包含最新`template.css`的完整`remote/fake-site/{distributionPath}/`，执行`cf-host-init.sh --noTLS --noAPP`，依次同步Host和客户，成功后删除并重建`/var/www/3x-fake-site/{distributionPath}`，最后下载日志。分发文件先完整上传到用户工作目录并检查样式表存在，上传或远端同步失败时不会删除当前线上目录；`--noTLS`避免触发证书流程，`--noAPP`避免配置同步安装或更新代理客户端静态分发资源。此入口只支持修改`clients`和`cdnOptDomains`，其它部署参数变化需要重建VPS

---

`ssh-tunnel.ps1`用于访问3X-UI面板；它读取`localSshPort`、`3xpanelPort`和`3xpanelUriPath`，启动`ssh -N -L`把本地端口转发到远端`127.0.0.1:3xpanelPort`，等待端口可连接后输出面板URL和登录凭据，并通过`Start-Process`在默认浏览器中打开面板；进程退出时清理隧道

---

`update-all.ps1`用于维护已有服务器；它依次执行`sudo -n apt-get update`、`sudo -n apt-get dist-upgrade -y`和`sudo -n x-ui update`，随后用`sudo -n systemctl start 3x-fetch-apps.service`立刻执行一次`fetch-apps-init.sh`安装的代理客户端检查更新任务。脚本同步等待全部命令完成，任一命令失败都会停止并返回错误；使用`init.ps1 -noAPP`部署时没有该service，因此脚本会在系统与3X-UI更新后失败

---

`modules/assert-exit-code.psm1`导出`Assert-ExitCode`，供本地脚本和其它模块统一检查外部命令退出码；退出码非0时抛出调用方提供的错误消息

---

`modules/generate-ssh-key.psm1`导出`Initialize-DeploymentSshKey`，用于准备部署所需的`remote/id_ed25519.pub`；它先检查`$env:USERPROFILE\.ssh\id_ed25519`，如果`remote/id_ed25519.pub`已存在且对应该私钥，则打印成功信息后退出；如果已有公钥不对应该私钥，则拒绝覆盖并报错。私钥不存在时调用`ssh-keygen -t ed25519`生成Ed25519密钥放在本机`.ssh/`目录；私钥已存在时用`ssh-keygen -y`重新导出公钥

---

`modules/setup-config.psm1`封装配置处理；它用`Test-Json`校验schema，用加密随机数生成16位十六进制token，补齐空白字段，确保客户端数组非空、`client`非空、`path`非空、客户端名不重复、订阅ID不重复，并检查`proxyClientsFilenames`中的固定文件名不重复

---

`modules/client-files.psm1`负责生成本地分发文件；它读取`modules/template.xhtml`和`modules/template.css`，删除并重建`remote/fake-site/{distributionPath}/`，把最新样式表写为该目录的`template.css`，为每个`clients[]`生成引用该样式表的`{clients.path}.html`，同时在根目录生成客户名到`https://cdnDomain/distributionPath/path.html`的`clients.tsv`映射。页面把普通订阅链接写成`https://cdnDomain/subscriptionPath/path`，并把`proxyClientsFilenames`渲染为固定的代理客户端下载URL。渲染后的`#encrypted`正文会被加密以防简单爬虫。可以通过修改`modules/template.xhtml`和`modules/template.css`编辑内容与样式模板

## 远端初始化脚本

`remote/root-init.sh`以root执行，是远端链路的入口；它安装基础依赖，创建并配置免密码sudo用户，把上传目录复制到`/home/username/3x-setup`，修正权限，并把`id_ed25519.pub`安装到该用户的`authorized_keys`，然后`sudo -Hu`切换身份执行`user-init.sh`

---

`remote/user-init.sh`修改SSH端口，启用公钥认证，禁用密码登录和root登录，重启`ssh`或`sshd`；配置UFW默认拒绝入站、允许出站，只开放`80/tcp`、`443/tcp`、`443/udp`和`sshPort/tcp`；`cdnPort`只对Cloudflare IP段开放；生成`/usr/local/sbin/3x-update-cloudflare-ufw.sh`，从Cloudflare官方IP列表刷新`cdnPort`白名单规则，并安装`3x-cloudflare-ufw.service`和每日运行的`3x-cloudflare-ufw.timer`；启用BBR；进入`service-check.sh`

---

`remote/service-check.sh`检查通用服务状态；它记录系统信息、SSH服务状态、UFW状态、`cdnPort`Cloudflare规则、Cloudflare UFW定时器、BBR内核参数、监听端口和失败systemd单元；关键检查失败会中断链路，成功后进入Caddy阶段

---

`remote/caddy-init.sh`和`remote/caddy-check.sh`负责Caddy安装和回源验证；生成20位`xhttpPath`写入`paths.json`，安装Caddy官方Debian源和软件包，部署`fake-site/`到`/var/www/3x-fake-site`，安装Cloudflare源站证书到`/etc/caddy/3x-origin-*.pem`，为`directDomain`生成30天自签证书到`/etc/caddy/3x-direct-*.pem`，渲染`Caddyfile.template`并重载Caddy

检查脚本验证Caddy服务、Caddyfile语法、Cloudflare源站证书、当前`directDomain`证书、伪装站文件、本机伪装站入口和`directDomain`证书入口；这个阶段不要求`directDomain`已经是公信证书，因为证书签发放在最后的`direct-tls-init.sh`

---

`remote/3x-panel-init.sh`和`remote/3x-panel-check.sh`负责安装3X-UI并设置面板；初始化脚本通过官方安装脚本非交互安装3X-UI，设置SQLite、面板端口、面板路径、用户名、密码、无面板SSL，监听`127.0.0.1`；随后显式启用并启动`x-ui.service`，保证VPS重启后3X-UI/Xray-core自动恢复。接着登录本机面板API，仅启用普通订阅，设置订阅监听、反代URI、加密订阅、流量信息显示、备注模板和Happy Eyeballs参数等并重启面板

---

`remote/3x-inbound-init.sh`和`remote/3x-inbound-check.sh`负责创建三条空入站；初始化脚本登录3x-ui API，先确认`/etc/caddy/3x-direct-*.pem`存在，然后创建Hysteria2、Reality和XHTTP三个入站；Hysteria2使用TLS文件证书和随机salamander密码，Reality通过3X-UI API生成X25519密钥并随机生成shortId，XHTTP只配置`127.0.0.1:xhttpPort`监听和传输参数，不再向`streamSettings.externalProxy`写入订阅主机

检查脚本读取入站列表，要求每个入站只有一条且关键字段符合预期，包括端口、协议、分享地址策略、排序、Reality目标、XHTTP路径和sniffing设置，并要求XHTTP的`externalProxy`缺失或为空；这个阶段不重启Xray，等待客户端创建后统一重启

---

`remote/cf-host-init.sh`和`remote/cf-host-check.sh`负责通过3X-UI独立Host API配置XHTTP订阅入口；初始化脚本查找唯一的`Cloudflare`入站，先为普通CDN地址创建或更新独立H2、H3 Host，再按`cdnOptDomains`数组顺序为每个优选地址创建或更新同样的Host对，最后删除该XHTTP入站中配置未定义的其它Host组

Host组使用包含协议后缀的固定ID，重复同步会原地替换对应组；从旧版单Host配置首次同步时会创建新的H2/H3 Host并删除旧Host。优选域名数量减少或清空时，多余组会被删除。在3X-UI GUI中手工添加的XHTTP Host也会在下次同步时删除

---

`remote/3x-client-init.sh`和`remote/3x-client-check.sh`负责按`config.json`同步客户；初始化脚本要求`clients`非空、`client`和`path`存在且不重复、`traffic`为非负整数；随后找到三条入站ID，读取当前3X-UI客户端，删除不在配置中或订阅ID、流量、重置周期不匹配的客户端，再为缺失客户端创建关联三条入站的新客户端，最后重启Xray并等待运行

检查脚本逐个验证客户端配置、入站关联和订阅链接。订阅链接包含`cdnDomain`普通地址和每个`cdnOptDomains[]`优选地址各自对应的1条H2和1条H3 XHTTP入口。检查脚本用本机临时Xray配置跑Reality和XHTTP的SOCKS代理端到端请求但不会验证HY2入站

---

`remote/fetch-apps-init.sh`和`remote/fetch-apps-check.sh`负责代理客户端静态分发；初始化脚本把自身安装为`/usr/local/sbin/3x-fetch-apps`，在`/var/www/3x-fake-site/{subscriptionPath}{proxyClientsSuffix}`创建隐藏目录，并安装与Cloudflare任务使用相同`dailyTaskHour`和1小时随机延迟的`3x-fetch-apps.timer`

更新器通过GitHub`releases/latest`API获取v2rayN和v2rayNG的最新稳定release，严格匹配目标assets；状态保存在`/var/lib/3x-fetch-apps/state.json`。asset发生变化或文件缺失、校验失败时才重新下载，临时文件通过大小和可用SHA-256 digest校验后才原子替换旧文件

连续3个更新任务任务失败后会禁用该资源，旧文件和其他资源不受影响。更新、错误、禁用和重置事件写入`fetch-apps-update.log`；执行`sudo /usr/local/sbin/3x-fetch-apps --reset RESOURCE_ID`可手动恢复，`RESOURCE_ID`就是`proxyClientsFilenames`中对应的键名。检查脚本验证service、两个timer、全部资源状态、文件权限和本机CDN固定URL后进入TLS阶段

---

`remote/direct-tls-init.sh`和`remote/direct-tls-check.sh`负责把`directDomain`切到公信证书；非`--noTLS`模式下，初始化脚本把Caddy全局配置改为`auto_https disable_redirects ignore_loaded_certs`，为`directDomain:realityTargetPort`写入ACME配置并禁用TLS-ALPN挑战，只走HTTP-01，重载Caddy后等待证书可用，再把Caddy证书目录里的`directDomain.crt`和`directDomain.key`复制到稳定路径`/etc/caddy/3x-direct-*.pem`，最后重启`x-ui`加载新证书。随后它会安装root拥有的`/usr/local/sbin/3x-sync-direct-tls`、`3x-direct-tls-sync.service`和每日timer；timer按`dailyTaskHour`及0到1小时随机延迟运行，仅当Caddy管理的证书和私钥均有效、匹配`directDomain`且与稳定路径不同，才原子替换两份文件并重启`x-ui`。`sudo /usr/local/sbin/3x-sync-direct-tls --check`只校验证书同步状态而不修改文件或重启服务

`--noTLS`模式下，脚本只记录跳过公信TLS，不渲染ACME配置、不触发CA也不安装证书同步任务；检查脚本会验证Caddy和x-ui状态、Caddyfile、证书文件、端口监听、HTTP到HTTPS跳转、伪装站正文和失败单元。非`--noTLS`模式验证公信`directDomain`证书、Cloudflare Origin、Staging或FakeLE证书，并验证证书同步timer等

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
	- client -> {cdnDomain}/{subscriptionPath}{proxyClientsSuffix}/{proxyClientFilename}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> /var/www/3x-fake-site/{subscriptionPath}{proxyClientsSuffix}/{proxyClientFilename}
- Hysteria2 Direct Connection
	- client -> {directDomain}:443/udp
	- vps -> 0.0.0.0:443/udp
	- Xray (Hysteria2 over TLS)
- Reality Direct Connection
	- client -> {directDomain}:443/tcp
	- vps -> 0.0.0.0:443/tcp
	- Xray (Reality)
- XHTTP with Cloudflare CDN
	- client -> {cdnDomain}/{xhttpPath}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{xhttpPort}
	- Xray (XHTTP)
- directDomain cert
	- noTLS：脚本生成自签测试证书，不访问CA
	- TLS：direct-tls-init.sh触发ACMEHTTP-01，为{directDomain}申请公信证书；Caddy续期后，3x-direct-tls-sync.timer会把新证书同步给Xray并重启x-ui
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

## 3X-UI面板设置

3X-UI通过官方脚本安装，数据库类型为SQLite；面板端口来自`3xpanelPort`，面板路径来自`3xpanelUriPath`，面板用户名和密码来自`3xusername`与`3xpassword`

面板SSL模式为无，因为公网不直接访问面板；面板监听地址强制设置为`127.0.0.1`，需要通过`ssh-tunnel.ps1`访问

订阅功能启用，json订阅关闭；订阅服务监听`127.0.0.1:subscriptionPort`，普通路径为`/subscriptionPath/`，反向代理URI为`https://cdnDomain/subscriptionPath/`

订阅加密开启，显示流量信息，客户端应用中的订阅更新间隔来自`subUpdates`，备注模板为`{{INBOUND}} {{EMAIL}} {{TRAFFIC_TOTAL}}`，订阅标题和公告写为“请勿分享！”

Xray模板会确保存在`tag=direct`的`freedom`出站，并在`sockopt`中写入Happy Eyeballs设置，减少双栈解析和连接时的异常延迟

## 3X-UI客户端

- `remote/config.json`的clients决定需要批量创建的客户端
- `client`：3X-UI客户端名
- `path`：客户端订阅ID，作为订阅链接中的`{subscriptionID}`
- 每个客户端会关联`QUIC`、`TCP`和`Cloudflare`三个入站
- `traffic`：可选，每月流量上限，单位GB；缺省或0表示不限量

## Hysteria2入站

- 基础配置
	- 备注：`QUIC`
	- 协议：`hysteria`
	- 地址：`0.0.0.0`
	- 分享地址策略：`自定义`
	- 自定义分享地址：`{directDomain}`
	- 端口：`443`
- 安全
	- SNI：`{directDomain}`
	- 数字证书：`/etc/caddy/3x-direct-cert.pem`和`/etc/caddy/3x-direct-key.pem`
- 高级配置 > FinalMask
	- UDP：`salamander`

## VLESS Reality入站

- 基础配置
	- 备注：`TCP`
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
	- 指纹：`{fingerprint}`
- 嗅探 > 启用：`Enabled`
	- HTTP：`Enabled`
	- TLS：`Enabled`
	- QUIC：`Enabled`
	- FAKEDNS：`Disabled`

## VLESS XHTTP入站

- 基础配置
	- 备注：`Cloudflare`
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
- 安全 > 安全：`无`
- 嗅探 > 启用：`Enabled`
	- HTTP：`Enabled`
	- TLS：`Enabled`
	- QUIC：`Enabled`
	- FAKEDNS：`Disabled`

## XHTTP主机

- 对`cdnOptDomains`中的每个域名按数组顺序创建两个Host组
	- 备注：`Cloudflare OPT 1 h2`、`Cloudflare OPT 1 h3`、`Cloudflare OPT 2 h2`、`Cloudflare OPT 2 h3`等
	- 基本
		- 入站：`Cloudflare`
		- 地址：`{cdnOptDomains[i]}`
		- 端口：`443`
	- 安全
		- 安全：`tls`
		- SNI：`{cdnDomain}`
		- ALPN：H2 Host仅为`h2`，H3 Host仅为`h3`
		- 指纹：`{fingerprint}`
- 备注：`Cloudflare Vanilla h2`和`Cloudflare Vanilla h3`
	- 基本
		- 入站：`Cloudflare`
		- 地址：`{cdnDomain}`
		- 端口：`443`
	- 安全
		- 安全：`tls`
		- SNI：`{cdnDomain}`
		- ALPN：分别仅为`h2`和`h3`
		- 指纹：`{fingerprint}`

## Caddy配置

`remote/Caddyfile.template`通过正则替换渲染，最终安装到`/etc/caddy/Caddyfile`

全局配置在初始阶段是`auto_https disable_redirects`，避免Caddy自动处理不需要的HTTPS重定向；公信TLS阶段改为`auto_https disable_redirects ignore_loaded_certs`，让Caddy忽略已加载的文件证书并为`directDomain`走ACME签发

`:80`只做永久跳转，把任意Host的HTTP请求跳到同Host的HTTPS路径；这个入口同时支持ACMEHTTP-01，因为Caddy会接管挑战路径

`:fakeSitePort`只在本机或内部链路中提供伪装站文件，根目录为`/var/www/3x-fake-site`

`directDomain:realityTargetPort`绑定`127.0.0.1`，提供Reality fallback要访问的HTTPS伪装站；初始阶段使用`/etc/caddy/3x-direct-*.pem`文件证书；公信TLS阶段临时改成ACME配置，签发成功后再把证书复制回稳定路径供Xray读取

`:cdnPort`使用Cloudflare源站证书`/etc/caddy/3x-origin-*.pem`；`/subscriptionPath/*`反代到`127.0.0.1:subscriptionPort`，`/xhttpPath*`反代到`127.0.0.1:xhttpPort`，其他路径由伪装站`file_server`返回，因此`/{subscriptionPath}{proxyClientsSuffix}/*`中的客户端文件无需额外Caddy路由即可下载

## Hints

日志是第一排查入口；`get-log.ps1`下载的每个阶段日志都在`log/`下，最近失败通常出现在链路中最后一个没有打印“完成”的文件里

本方案并不需要ECH，加了也没用

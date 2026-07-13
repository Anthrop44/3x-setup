# 开发文档

**本文档由AI生成并经过人工粗略检查，若发现bug请发issue**

本方案默认安全，不需要任何额外加固，服务器只对公网暴露80、443和自定义SSH端口，对Cloudflare ip段暴露自定义高位cdn回源端口。3X-UI面板不暴露公网，通过SSH通道访问。普通HTTP(S)访问和GFW主动探测会回落到本机自托管的伪装站。XHTTP和订阅链接隐藏路径由脚本自动随机生成以确保无特征隐蔽性

本项目的完整执行顺序：`init.ps1` > `generate-ssh-key.ps1` > 上传`remote/`触发远端执行 > `root-init.sh` > `user-init.sh` > `service-check.sh` > `caddy-init.sh` > `caddy-check.sh` > `3x-panel-init.sh` > `3x-panel-check.sh` > `3x-inbound-init.sh` > `3x-inbound-check.sh` > `3x-client-init.sh` > `3x-client-check.sh` > `fetch-apps-init.sh` > `fetch-apps-check.sh` > `direct-tls-init.sh` > `direct-tls-check.sh` > 回到本地Windows环境 > `get-log.ps1`

`init.ps1 -noTLS`会把`--noTLS`传给远端链路；Caddy仍会安装`directDomain`自签测试证书并完成Reality/XHTTP检查，但`direct-tls-init.sh`不会渲染ACME配置，也不会访问CA；该模式下HY2入站不能视为可用，因为客户端需要信任`directDomain`的公信证书

## 本地脚本和模块

`init.ps1`是首次部署入口；它开头先调用`generate-ssh-key.ps1`准备部署所需的`remote/id_ed25519.pub`，然后把`remote/`中的文本文件统一为LF，检查必要文件是否存在，再通过`modules/setup-config.psm1`校验`remote/config.json`和`remote/constants.json`，自动补齐`subscriptionPath`和`clients[].path`，检查客户端名、客户订阅路径和代理客户端固定文件名不重复，最后写回`remote/config.json`并调用`modules/client-files.psm1`导出`clients/*.md`。Clash订阅路径不单独保存，而是由`subscriptionPath`追加`constants.json`中的`clashSuffix`派生

上传阶段默认使用Windows OpenSSH的`scp`和`ssh`；脚本把`remote/`打包成`3x-setup.tar`上传到root家目录，再通过`ssh root@ip`启动`root-init.sh`，允许用户在终端中交互输入密码，并用`StrictHostKeyChecking=no`和`UserKnownHostsFile=NUL`直接跳过OpenSSH主机指纹确认；默认流程不读取`initialPassword`，也不要求非交互式登录；远端初始化完成后执行`get-log.ps1`。传入`-PuTTY`时才改用PuTTY组件`pscp.exe`和`plink.exe`，此时要求`remote/config.json`提供`initialPassword`，并沿用自动处理PuTTY首次连接hostkey确认的逻辑。PuTTY模式主要用于方便AI Agents非交互式使用`init.ps1`

**`init.ps1`在远端服务器root绑了公钥的情况下可以不依赖PuTTY非交互式执行，这是最推荐的方式**

---

`sync-clients.ps1`用于已有服务器的客户增删；它与`init.ps1`复用同一套schema校验和自动字段补齐逻辑，会补齐缺失的`clients[].path`，但要求初始部署生成的`subscriptionPath`已经存在；随后用OpenSSH/SFTP上传`remote/config.json`，在远端执行`3x-client-init.sh --noTLS`，最后下载日志；这里传`--noTLS`只是为了不触发证书流程，因为客户同步只需要更新3X-UI客户端

---

`get-log.ps1`负责日志下载；它让远端把`~/3x-setup/log/`打包到`/tmp`，用SFTP下载到本地，再解包到`log/`；如果本地`log/`非空，会先轮转为`log0/`、`log1/`等目录，避免覆盖上一次结果

---

`ssh-tunnel.ps1`用于访问3X-UI面板；它读取`localSshPort`、`3xpanelPort`和`3xpanelUriPath`，启动`ssh -N -L`把本地端口转发到远端`127.0.0.1:3xpanelPort`，等待端口可连接后输出面板URL和登录凭据，并通过`Start-Process`在默认浏览器中打开面板；进程退出时清理隧道

---

`generate-ssh-key.ps1`用于准备部署所需的`remote/id_ed25519.pub`；它先检查`$env:USERPROFILE\.ssh\id_ed25519`，如果`remote/id_ed25519.pub`已存在且对应该私钥，则打印成功信息后退出；如果已有公钥不对应该私钥，则拒绝覆盖并报错。私钥不存在时调用`ssh-keygen -t ed25519`生成无密码Ed25519密钥，私钥留在本机`.ssh/`目录；私钥已存在时用`ssh-keygen -y`重新导出公钥。无论新生成还是复用私钥，写入`remote/id_ed25519.pub`的公钥comment都会固定为`https://github.com/Anthrop44/3x-setup`

---

`modules/setup-config.psm1`封装配置处理；它用`Test-Json`校验schema，用加密随机数生成16位十六进制token，补齐空白字段，确保客户端数组非空、`client`非空、`path`非空、客户端名不重复、订阅ID不重复，并检查`clashSuffix`和`proxyClientsSuffix`不冲突、`proxyClientsFilenames`中的固定文件名不重复

---

`modules/client-files.psm1`负责生成本地分发文件；它读取`modules/template.md`，确保`clients/`存在，删除旧的`clients/*.md`，为每个`clients[]`生成一个同名Markdown文件，把普通订阅链接写成`https://cdnDomain/subscriptionPath/path`，把Clash/mihomo订阅链接写成`https://cdnDomain/{subscriptionPath}{clashSuffix}/path`，并把`proxyClientsFilenames`渲染为固定的代理客户端下载URL。可以通过修改`modules/template.md`编辑内容模板

## 远端初始化脚本

`remote/root-init.sh`以root执行，是远端链路的入口；它安装基础依赖`jq`、`openssl`、`openssh-server`、`sudo`、`curl`、`ca-certificates`、`ufw`、`procps`和`sqlite3`，读取`constants.json`创建sudo用户，配置免密码sudo，把上传目录复制到`/home/username/3x-setup`，修正权限，并把`id_ed25519.pub`安装到该用户的`authorized_keys`

权限处理会把目录设为`755`、普通文件设为`644`、根目录下`.sh`设为`755`，并把`key.pem`收紧到`600`；最后脚本验证新用户可以免交互sudo，把root阶段日志复制到用户工作目录，然后用`sudo -Hu`切换身份执行`user-init.sh`

---

`remote/user-init.sh`配置系统安全基线；它把SSH切换到`config.json`里的`sshPort`，启用公钥认证，禁用密码登录和root登录，重启`ssh`或`sshd`；随后配置UFW默认拒绝入站、允许出站，只开放`80/tcp`、`443/tcp`、`443/udp`和`sshPort/tcp`

同一脚本还生成`/usr/local/sbin/3x-update-cloudflare-ufw.sh`，从Cloudflare官方IP列表刷新`cdnPort`白名单规则，并安装`3x-cloudflare-ufw.service`和每日运行的`3x-cloudflare-ufw.timer`；timer按VPS本地时区在`dailyTaskHour`整点后随机延迟0到1小时执行。最后脚本加载并要求内核支持BBR，把`fq`和`bbr`写入`/etc/sysctl.d/99-3x-bbr.conf`后进入`service-check.sh`

---

`remote/service-check.sh`检查通用服务状态；它记录系统信息、SSH服务状态、UFW状态、`cdnPort`Cloudflare规则、Cloudflare UFW定时器、BBR内核参数、监听端口和失败systemd单元；关键检查失败会中断链路，成功后进入Caddy阶段

---

`remote/caddy-init.sh`和`remote/caddy-check.sh`负责Caddy安装和回源验证；初始化脚本随机生成20位`xhttpPath`写入`paths.json`，安装Caddy官方Debian源和软件包，部署`fake-site/`到`/var/www/3x-fake-site`，安装Cloudflare源站证书到`/etc/caddy/3x-origin-*.pem`，为`directDomain`先生成30天自签证书到`/etc/caddy/3x-direct-*.pem`，渲染`Caddyfile.template`并重载Caddy

检查脚本验证Caddy服务、Caddyfile语法、Cloudflare源站证书、当前`directDomain`证书、伪装站文件、本机伪装站入口和`directDomain`证书入口；这个阶段不要求`directDomain`已经是公信证书，因为证书签发放在最后的`direct-tls-init.sh`

---

`remote/3x-panel-init.sh`和`remote/3x-panel-check.sh`负责安装3X-UI并设置面板；初始化脚本通过官方安装脚本非交互安装3X-UI，设置SQLite、面板端口、面板路径、用户名、密码、无面板SSL，并强制面板监听`127.0.0.1`；随后登录本机面板API，开启普通订阅和Clash订阅，设置订阅监听为`127.0.0.1:subscriptionPort`，配置反代URI、Clash规则、加密订阅、流量信息显示和备注模板

同一阶段还读取Xray模板并确保存在`direct`自由出站，给它写入Happy Eyeballs参数`tryDelayMs=0`、`prioritizeIPv6=false`、`interleave=1`、`maxConcurrentTry=4`，再重启Xray和面板；检查脚本验证面板只监听本机、订阅服务只监听本机、数据库设置符合预期、Clash规则与文件一致、Xray模板包含Happy Eyeballs设置，并探测订阅入口和CDN默认入口

---

`remote/3x-inbound-init.sh`和`remote/3x-inbound-check.sh`负责创建三条空入站；初始化脚本登录3x-ui API，先确认`/etc/caddy/3x-direct-*.pem`存在，然后创建Hysteria2、Reality和XHTTP三个入站；Hysteria2使用TLS文件证书和随机salamander密码，Reality通过3X-UI API生成X25519密钥并随机生成shortId，XHTTP监听`127.0.0.1:xhttpPort`，配置外部代理/主机到`cdnDomain:443`和`cdnOptDomain:443`

检查脚本读取入站列表，要求每个入站只有一条且关键字段符合预期，包括端口、协议、分享地址策略、排序、Reality目标、XHTTP路径、外部代理和sniffing设置；这个阶段不重启Xray，等待客户端创建后统一重启

---

`remote/3x-client-init.sh`和`remote/3x-client-check.sh`负责按`config.json`同步客户；初始化脚本要求`clients`非空、`client`和`path`存在且不重复、`traffic`为非负整数；随后找到三条入站ID，读取当前3X-UI客户端，删除不在配置中或订阅ID、流量、重置周期不匹配的客户端，再为缺失客户端创建关联三条入站的新客户端，最后重启Xray并等待运行

客户端的`traffic`会换算成`totalGB=traffic*1073741824`，大于0时设置`reset=30`，否则`reset=0`；检查脚本逐个验证客户端配置、入站关联、分享链接和订阅链接都使用443，包含`cdnDomain`和`cdnOptDomain`两条XHTTP主机，且不暴露`cdnPort`或`xhttpPort`，再用本机临时Xray配置跑Reality和XHTTP的SOCKS代理端到端请求；HY2不在这个端到端代理测试中，因为生产可用性取决于后续公信TLS

---

`remote/fetch-apps-init.sh`和`remote/fetch-apps-check.sh`负责代理客户端静态分发；初始化脚本把自身安装为`/usr/local/sbin/3x-fetch-apps`，在`/var/www/3x-fake-site/{subscriptionPath}{proxyClientsSuffix}`创建隐藏目录，并安装与Cloudflare任务使用相同`dailyTaskHour`和1小时随机延迟的`3x-fetch-apps.timer`

更新器通过GitHub`releases/latest`API获取v2rayN、v2rayNG、Clash Verge Rev和Clash Meta for Android的最新稳定release，严格匹配10个目标asset；状态保存在`/var/lib/3x-fetch-apps/state.json`。asset发生变化或文件缺失、校验失败时才重新下载，临时文件通过大小和可用SHA-256 digest校验后才原子替换旧文件

资源级错误按每日任务计数，每次任务内部HTTP最多尝试3次；连续3个每日任务失败后只禁用该资源，旧文件和其他资源不受影响。更新、错误、禁用和重置事件写入`fetch-apps-update.log`；执行`sudo /usr/local/sbin/3x-fetch-apps --reset RESOURCE_ID`可手动恢复，`RESOURCE_ID`就是`proxyClientsFilenames`中对应的键名。检查脚本验证service、两个timer、10项状态、文件权限和本机CDN固定URL后进入TLS阶段

---

`remote/direct-tls-init.sh`和`remote/direct-tls-check.sh`负责把`directDomain`切到公信证书；非`--noTLS`模式下，初始化脚本把Caddy全局配置改为`auto_https disable_redirects ignore_loaded_certs`，为`directDomain:realityTargetPort`写入ACME配置并禁用TLS-ALPN挑战，只走HTTP-01，重载Caddy后等待证书可用，再把Caddy证书目录里的`directDomain.crt`和`directDomain.key`复制到稳定路径`/etc/caddy/3x-direct-*.pem`，最后重启`x-ui`加载新证书

`--noTLS`模式下，脚本只记录跳过公信TLS，不渲染ACME配置也不触发CA；检查脚本会验证Caddy和x-ui状态、Caddyfile、证书文件、端口监听、HTTP到HTTPS跳转、伪装站正文和失败单元；只有非`--noTLS`模式才要求`directDomain`证书不是自签、Cloudflare Origin、Staging或FakeLE证书

## 配置文件

`remote/config.schema.json`描述用户必须准备的敏感配置；必填项包括`ip`、`sshPort`、`cdnPort`、`directDomain`、`cdnDomain`和`clients`；`initialPassword`仅供`init.ps1 -PuTTY`非交互式首次登录使用，默认OpenSSH流程不需要填写；`sshPort`和`cdnPort`必须大于10000，`directDomain`和`cdnDomain`必须是合法hostname

`subscriptionPath`和`clients[].path`是自动生成字段，长度固定为16，建议不要手动设置；Clash订阅路径不属于`config.json`字段，而是由`subscriptionPath`追加非空的`clashSuffix`派生；`clients[].client`只能包含英文字母、数字和连字符，并排除Windows保留文件名；`clients[].traffic`为可选非负整数，单位GB

`remote/constants.json`保存默认端口、账号、隐藏路径后缀、每日任务时间和代理客户端固定文件名；`clashSuffix`与`proxyClientsSuffix`必须是不同的非空字母数字字符串。`dailyTaskHour`是0到23的integer，默认4；两个每日timer都按VPS本地时区在该整点后独立随机延迟0到1小时。`proxyClientsFilenames`的10个值必须是互不重复的安全basename，修改它们会改变公开下载URL

`remote/paths.json`不在仓库中，由远端`caddy-init.sh`生成，目前保存随机`xhttpPath`；后续Caddy、3X-UI入站、检查脚本都会读取它，所以不要在远端初始化中途删除

## 服务器安全配置

SSH部署后只允许`sshPort/tcp`，禁用密码登录，禁用root登录，使用`remote/id_ed25519.pub`对应私钥登录到`username`用户；该用户拥有免密码sudo，目的是让后续检查和服务配置可以非交互执行

UFW策略是默认拒绝入站、默认允许出站；固定开放`80/tcp`给ACMEHTTP-01和HTTP跳转，开放`443/tcp`给Reality直连和HTTPS伪装回退，开放`443/udp`给Hysteria2，开放`sshPort/tcp`给管理登录

`cdnPort/tcp`只允许CloudflareIP段访问；脚本会安装systemd timer每天刷新Cloudflare ip列表，刷新时先拉取并校验格式，再删除旧的带`3x-cloudflare-cdn`注释的规则并写入新规则；若拉取失败或格式异常，会保留现有规则并失败退出

内核网络配置要求支持BBR；脚本加载`tcp_bbr`，检查`net.ipv4.tcp_available_congestion_control`包含`bbr`，并持久写入`net.core.default_qdisc=fq`和`net.ipv4.tcp_congestion_control=bbr`

3X-UI面板、订阅服务、XHTTP入站、伪装站内部端口和Reality证书入口均设计为本机监听或受控入口，不应直接暴露到公网；检查脚本会阻止面板和XHTTP在`0.0.0.0`或`::`上监听

## 网络架构

- client get subscription
	- client -> {cdnDomain}/{subscriptionPath}/{subscriptionID}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{subscriptionPort}
	- 3X-UI subscription
- client get Clash/Mihomo subscription
	- client -> {cdnDomain}/{subscriptionPath}{clashSuffix}/{subscriptionID}:443
	- Cloudflare cdn -> ip:{CDN_PORT}
	- vps -> 127.0.0.1:{CDN_PORT}
	- Caddy -> 127.0.0.1:{subscriptionPort}
	- 3X-UI Clash/Mihomo subscription
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
	- TLS：direct-tls-init.sh触发ACMEHTTP-01，为{directDomain}申请公信证书
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

订阅功能启用，json订阅关闭，Clash订阅启用，Clash路由启用；订阅服务监听`127.0.0.1:subscriptionPort`，普通路径为`/subscriptionPath/`，Clash路径为`/{subscriptionPath}{clashSuffix}/`，反向代理URI分别是`https://cdnDomain/subscriptionPath/`和`https://cdnDomain/{subscriptionPath}{clashSuffix}/`

订阅加密开启，显示流量信息，备注模板为`{{INBOUND}} {{EMAIL}} {{TRAFFIC_TOTAL}}`，订阅标题和公告写为“请勿分享！”；Clash规则来自`remote/clash-rule.txt`

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

- 备注：`Cloudflare OPT`
	- 基本
		- 入站：`Cloudflare`
		- 地址：`{cdnOptDomain}`
		- 端口：`443`
	- 安全
		- 安全：`tls`
		- SNI：`{cdnDomain}`
- 备注：`Cloudflare Vanilla`
	- 基本
		- 入站：`Cloudflare`
		- 地址：`{cdnDomain}`
		- 端口：`443`
	- 安全
		- 安全：`tls`
		- SNI：`{cdnDomain}`

## Caddy配置

`remote/Caddyfile.template`通过正则替换渲染，最终安装到`/etc/caddy/Caddyfile`

全局配置在初始阶段是`auto_https disable_redirects`，避免Caddy自动处理不需要的HTTPS重定向；公信TLS阶段改为`auto_https disable_redirects ignore_loaded_certs`，让Caddy忽略已加载的文件证书并为`directDomain`走ACME签发

`:80`只做永久跳转，把任意Host的HTTP请求跳到同Host的HTTPS路径；这个入口同时支持ACMEHTTP-01，因为Caddy会接管挑战路径

`:fakeSitePort`只在本机或内部链路中提供伪装站文件，根目录为`/var/www/3x-fake-site`

`directDomain:realityTargetPort`绑定`127.0.0.1`，提供Reality fallback要访问的HTTPS伪装站；初始阶段使用`/etc/caddy/3x-direct-*.pem`文件证书；公信TLS阶段临时改成ACME配置，签发成功后再把证书复制回稳定路径供Xray读取

`:cdnPort`使用Cloudflare源站证书`/etc/caddy/3x-origin-*.pem`；`/subscriptionPath/*`和`/{subscriptionPath}{clashSuffix}/*`反代到`127.0.0.1:subscriptionPort`，`/xhttpPath*`反代到`127.0.0.1:xhttpPort`，其他路径由伪装站`file_server`返回，因此`/{subscriptionPath}{proxyClientsSuffix}/*`中的客户端文件无需额外Caddy路由即可下载

## Hints

本项目不追求幂等；很多远端脚本会新增系统用户、改SSH、改UFW、安装Caddy和3X-UI、写systemd单元，建议只在重装后的干净Debian VPS上跑完整初始化

CA有签发频率限制；反复测试完整部署时优先使用`pwsh init.ps1 -noTLS`，确认系统、Caddy、3X-UI、Reality和XHTTP流程都通，再重建后执行`pwsh init.ps1`

日志是第一排查入口；`get-log.ps1`下载的每个阶段日志都在`log/`下，最近失败通常出现在链路中最后一个没有打印“完成”的文件里

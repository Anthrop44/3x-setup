# 开发文档

本地依赖Nushell 0.116.1+、OpenSSH（ssh、scp、ssh-keygen）、OpenSSL 3和tar；Windows需将这些程序加入PATH，也可使用Git for Windows提供的OpenSSL

## 入口

- `nu init.nu`：首次部署；缺少`remote/config.json`时创建schema骨架并退出
- `nu init.nu --prepare-only`：完成本地校验、补齐字段、密钥准备、分发页生成与ECH可获取性预检，不连接部署服务器
- `nu init.nu --noAPP --noTLS`：跳过代理应用分发与ACME，用自签证书测试；本机直连检查显式信任初始自签证书
- `nu init.nu --accept-new-host`：在清除重建服务器旧指纹后自动接受新指纹
- `nu sync-config.nu`：同步`config.json`中的`clients`及`constants.json`中的`cdnOptDomains`和`cdnEchConfigList`，并更新`ban-outbound.txt`，其它部署参数必须保持不变
- `nu get-log.nu`：下载所有阶段日志，已有非空`log/`轮转为`log0/`等目录
- `nu ssh-tunnel.nu --startup-timeout-seconds 60`：保留终端交互认证，访问仅本机监听的面板
- `nu update-all.nu`：更新APT软件与3X-UI，并触发已安装的代理客户端更新器

所有入口按脚本路径查找配置与根目录`id_ed25519`，不依赖当前工作目录

## 本地模块

- `modules/setup-config.nu`：按schema校验配置和冲突，补齐`sshPort`、`subscriptionPath`、`distributionPath`、`clients[].path`和`clients[].password`，保留已有值；同步时不补初始订阅路径或SSH端口
- `remote/lib/config.nu`：共用的配置校验和资源路径管理，仅实现仓库schema所需的断言；`format`是注解，域名由`pattern`验证
- `modules/generate-ssh-key.nu`：生成或导出Ed25519部署公钥，支持已有Ed25519-SK密钥；私钥缺失或公钥不匹配时拒绝覆盖
- `modules/client-files.nu`：生成加密分发页，将密码导出到`clients.tsv`的`Password`列，HTML不含明文密码
- `modules/ssh.nu`：构造SSH/SCP目标与远端命令，统一设置20秒连接超时、30秒保活，支持回退到初始端口

分发页使用PBKDF2-SHA256（100000次）派生64字节密钥，前32字节用于AES-256-CBC，后32字节用于HMAC-SHA256；HMAC覆盖IV和密文，浏览器通过WebCrypto先验签再解密

所有SSH连接均使用`directDomain`，需提前解析到服务器并关闭Cloudflare代理。维护连接使用OpenSSH默认主机验证，返回255时最多尝试一次日志下载，成功后重试；日志下载采用`accept-new`，不会覆盖冲突指纹

## 远端目录与调用边界

- `remote/bootstrap.sh`: 安装Nu并进入`main.nu deploy`
- `remote/main.nu`: `deploy`、`sync`、`update`、`check`、`list-stages`入口
- `remote/workflows/`: 部署、同步、更新流程；`stages.nu`统一登记阶段实现
- `remote/features/`: `system.nu`系统配置、`caddy/`站点与证书、`panel/`面板与入站、`apps.nu`应用分发
- `remote/checks/`: 跨Caddy、Xray和CDN的连通性检查
- `remote/jobs/`: systemd任务入口，处理参数、权限与锁
- `remote/lib/`: 配置、进程、日志、重试、systemd和网络工具
- `remote/templates/`: Caddyfile模板

调用方向：`main.nu` -> `workflows/` -> `features/`与`checks/` -> `lib/`；`jobs/`调用相同业务模块。业务模块不调度工作流，公共库不导入业务模块

同一业务的`apply`与`verify`放在一起；工作流只排列阶段名，部署和同步流程独立。初次部署完整打包`remote/`，本地与远端共用的辅助函数也放在`remote/lib/`

## 远端执行

`bootstrap.sh`以root安装基础依赖和Nushell，再执行`nu --no-config-file ./main.nu deploy`；初始SSH通过`setsid --wait`启动引导，断线后继续执行，输出写入`log/bootstrap.log`

`lib/runner.nu`为每个阶段启动独立的无用户配置Nu进程，将stdout/stderr写入`log/{阶段}.log`并记录耗时；失败立即中止后续阶段

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

主要检查：

- `3x-client-check`：客户配额、入站关联、订阅公网端口及直连/CDN各自的加密与flow策略
- `connectivity-check`：Xray状态和监听地址、两个XHTTP后端的本机回环、直连H2/H3；临时Xray/SOCKS进程在结束或失败时清理，直连检查同时信任初始自签证书和系统根证书
- `direct-tls-check`：伪装站首页、HTTP跳转、服务状态及证书；根据已安装Caddyfile选择证书来源，ACME启用后即使传入`--noTLS`，也检查公信证书的域名、私钥匹配和系统信任链

## 定时任务

所有systemd任务直接执行Nu，依赖脚本保存在`/root/3x-setup`，不要删除该目录

- `jobs/cloudflare-ufw.nu`：通过`features/system.nu`下载并校验官方IPv4/IPv6列表后刷新UFW回源规则，flock防止并发
- `jobs/fetch-apps.nu`：通过`features/apps.nu`精确匹配GitHub稳定release的asset，检查大小和可用SHA-256，在同目录下载后原子替换；状态保存在`/var/lib/3x-fetch-apps/state.json`，错误和更新记录在`log/fetch-apps-update.log`。元数据失败或下载失败均按资源累计，连续3次失败后禁用，保留旧文件；`/usr/local/sbin/3x-fetch-apps --reset RESOURCE_ID`恢复资源

每日任务均按`dailyTaskHour`运行，附加0到1小时随机延迟，`Persistent=true`

## 配置同步与日志

`sync-config.nu`将`config.json`、`constants.json`、`ban-outbound.txt`和完整分发目录打包上传到唯一暂存目录，远端再次校验配置、常量和出站禁用清单，只允许更改`config.json`中的`clients`及`constants.json`中的`cdnOptDomains`和`cdnEchConfigList`；systemd临时服务在SSH断开后继续同步。API检查通过后才替换线上分发目录，保留旧目录直到替换成功

`ban-outbound.txt`每行一项。域名规则支持`domain:`和`geosite:`，IP规则支持`geoip:`、IPv4、IPv6及CIDR。空行和以`#`开头的行会被忽略。两类规则独立匹配，均使用面板内置的`blocked`出站。清空清单后同步会移除项目管理的规则，面板自带的规则继续生效

`workflows/sync.nu`显式执行`cf-host-init` -> `cf-host-check` -> `3x-routing-init` -> `3x-client-init` -> `3x-client-check` -> `connectivity-check` -> `direct-tls-check`；同步不申请证书

部署或同步失败不会自动重试已经执行的有副作用阶段。`get-log.nu`先尝试`sshPort`，连不上时回退到`constants.json`的`initialSshPort`，因此引导未完成或SSH端口尚未切换时也能取到日志

## 本地验证

```nu
nu --no-config-file tests/run.nu
```

覆盖语法、配置稳定性与同步限制、工作流调度与失败即停、日志、Caddy模板、面板API与订阅、连通性测试配置、下载校验与失败重置、flock冲突，以及远端打包后的独立运行

依赖Nu、OpenSSL、tar、Bash、chmod和flock；数据写入临时目录，不修改系统配置或连接VPS

## 网络架构

- 直连：客户端 -> `directDomain:443` -> Caddy -> `127.0.0.1:directXhttpPort` -> Xray
- CDN：客户端 -> `cloudflare-ech.com`或优选域名`:443`（ECH） -> Cloudflare -> 服务器`cdnPort` -> Caddy -> `127.0.0.1:xhttpPort` -> Xray；内层SNI和HTTP Host均为`cdnDomain`

分发页和订阅通过`cdnDomain`访问，路径分别为`/{distributionPath}/{clientPath}.html`和`/{subscriptionPath}/{subscriptionID}`；应用下载同时支持直连和CDN，路径见下文Caddy配置

## 3X-UI面板设置

面板使用SQLite，无TLS，仅监听`127.0.0.1`，通过`ssh-tunnel.nu`访问；端口、路径和凭据见`remote/constants.schema.json`

订阅服务监听`127.0.0.1:subscriptionPort`，路径为`/subscriptionPath/`，反向代理URI为`https://cdnDomain/subscriptionPath/`；启用订阅加密，关闭JSON订阅，更新间隔取`subUpdates`

订阅开启`subInfoNodeEnable`，关闭`subShowIdentityOnAllLinks`：连接节点只显示Host备注，首个信息节点显示`用户名 已用流量/剩余流量`，不限量显示`∞`。备注模板为`{{HOST}}|{{EMAIL}} {{TRAFFIC_USED}}/{{TRAFFIC_LEFT}}`，分段处理空字段；信息节点是3X-UI生成的`127.0.0.1:1080`SOCKS占位链接，不创建真实监听。标题和公告为“请勿分享！”

Xray模板启用内置DNS，使用面板默认的`UseIP`查询策略和空上游列表，保留已有DNS配置；这不会单独开放DNS监听端口或改变出站域名解析策略。模板还会确保存在`tag=direct`的`freedom`出站，并在`sockopt`中写入Happy Eyeballs设置

## 3X-UI客户端

`remote/config.json`的`clients`定义客户，每位客户关联`Direct`和`Cloudflare`两个入站

- `client`：客户名
- `path`：自动生成的订阅ID
- `password`：自动生成的八位数字分发页密码，可含前导零，重建和同步时复用
- `traffic`：每月流量上限（GB），省略或0表示不限量

## VLESS XHTTP入站

两个入站均监听`127.0.0.1`，使用VLESS、XHTTP、`auto`模式和`xhttpPath`，由Caddy通过h2c反代；公网地址、端口和TLS由Host组覆盖，网站回落由Caddy处理，不设置`fallbacks`。嗅探启用HTTP、TLS和QUIC，禁用FAKEDNS

| 配置 | `Direct` | `Cloudflare` |
| --- | --- | --- |
| 端口 | `directXhttpPort` | `xhttpPort` |
| VLESS加密 | `decryption`与`encryption`均为`none` | `getNewVlessEnc`生成`mlkem768_xorpub`密钥对 |
| flow | `disableFlow: true`，客户端flow留空 | `xtls-rprx-vision` |

## XHTTP主机

所有Host组使用公网443端口、TLS和`fingerprint`，每个地址分别生成仅含`h2`或`h3`的ALPN配置

| Host组备注 | 入站 | 连接地址 | SNI | ECH |
| --- | --- | --- | --- | --- |
| `Direct h2/h3` | `Direct` | `directDomain` | `directDomain` | 无 |
| `Cloudflare ECH h2/h3` | `Cloudflare` | `cloudflare-ech.com`及`cdnOptDomains` | `cdnDomain` | `cdnEchConfigList` |

CDN组按公共地址、优选域名数组顺序排列，每个地址先H2后H3；不同地址允许同名，ID独立且保留`ech`后缀，更新时删除旧非ECH组

### Cloudflare ECH

`remote/constants.json`中的`cdnEchConfigList`必填，默认值为：

```json
"cdnEchConfigList": "cloudflare-ech.com+https://dns.alidns.com/dns-query"
```

该配置通过阿里云DoH查询公共域名`cloudflare-ech.com`的HTTPS记录并按TTL缓存，不提交`cdnDomain`；schema仅允许该公共域名加HTTPS DoH地址，DoH须能由客户端直接访问，参见[Xray文档](https://xtls.github.io/config/transports/tls.html#tlsobject)

Cloudflare区域须启用ECH并接受公共域名的ECH配置；内层SNI和HTTP Host为`cdnDomain`，外层SNI由ECH配置决定，通常为`cloudflare-ech.com`，参见[Cloudflare说明](https://developers.cloudflare.com/ssl/edge-certificates/ech/)。`cdnOptDomains`可为空，但不得与`cdnDomain`或公共地址重复，也不能通过CNAME指向`cdnDomain`

订阅通过`ech`参数下发配置，`+`须编码为`%2B`并在导入后还原；客户端及其Xray核心须支持ECH与对应指纹，导入后应确认配置未丢失。[Xray无法取得ECH配置时连接失败](https://github.com/XTLS/Xray-core/blob/main/transport/internet/tls/ech.go)，本项目不提供普通CDN节点回退

ECH仅保护代理建连的内层域名，Cloudflare仍可见该域名。分发页、订阅更新、CDN客户端下载和手动访问仍使用`cdnDomain`，未经代理访问时可能通过DNS或普通TLS暴露；公开DNS、证书及流量关联也不受ECH保护

## Caddy配置

`remote/templates/Caddyfile.template`由`remote/features/caddy/config.nu`通过字面占位符替换渲染，最终安装到`/etc/caddy/Caddyfile`

全局配置在初始阶段是`auto_https disable_redirects`，避免Caddy自动处理不需要的HTTPS重定向；公信TLS阶段改为`auto_https disable_redirects ignore_loaded_certs`，让Caddy忽略已加载的文件证书并为`directDomain`走ACME签发

`:80`只做永久跳转，把任意Host的HTTP请求跳到同Host的HTTPS路径；这个入口同时支持ACMEHTTP-01，因为Caddy会接管挑战路径

`:fakeSitePort`只在本机或内部链路中提供伪装站文件，根目录为`/var/www/3x-fake-site`

`directDomain:443`监听公网443/tcp与443/udp，支持H1/H2/H3；`/xhttpPath*`通过h2c反代到`127.0.0.1:directXhttpPort`，其余路径提供伪装站。初始阶段使用`/etc/caddy/3x-direct-*.pem`自签文件证书；公信TLS阶段切换为ACMEHTTP-01，之后由Caddy自动续期，不再向Xray复制证书

`:cdnPort`使用Cloudflare源站证书`/etc/caddy/3x-origin-*.pem`；`/subscriptionPath/*`反代到`127.0.0.1:subscriptionPort`，`/xhttpPath*`通过h2c反代到`127.0.0.1:xhttpPort`，其他路径由伪装站`file_server`返回，因此`/{subscriptionPath}{proxyClientsSuffix}/*`中的客户端文件无需额外Caddy路由即可下载

## 本地ECH预检

`init.nu`和`sync-config.nu`在打包、上传及远端操作前，通过`modules/ech-preflight.nu`使用Nushell内置HTTP和二进制命令，向`cdnEchConfigList`指定的DoH发送HTTPS记录查询；检查DNS响应、目标名称和ECHConfigList格式，最多尝试3次。忽略环境HTTP代理，系统级隧道仍可能影响实际路由。失败即停止，不上传文件

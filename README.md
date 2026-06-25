# 3x-ui一键部署脚本

一键初始化服务器并通过3x-ui API部署“偷自己”双栈方案：
- 直连：vless+Reality+Vision
- Cloudflare CDN：vless+XHTTP

本方案可以实现极高的伪装性、安全性和鲁棒性

## Cloudflare域名设置

- {cdnDomain} A/AAAA->{ip}，开启小橙云，规则设置回源端口{cdnPort}
- {directDomain} A/AAAA->{ip}，关闭小橙云
- SSL/TLS加密模式：完全（严格）
- 始终使用https
- 启用tls1.3
- 最低tls版本1.3
- gRPC已开启
- 获取{cdnDomain}源站证书公私钥

如果{cdnDomain}或{directDomain}是子域名，最好将主域名和www子域名都开启小橙云A/AAAA到{ip}

## 手动配置

```txt
remote/
	├ fake-site/		# 伪装站
	│	├ index.html
	│	└ ……
	├ config.json		# 自定义配置文件
	├ id_ed25519.pub	# SSH公钥
	├ cert.pem			# Cloudflare ECC PEM证书
	└ key.pem			# Cloudflare ECC PEM私钥
```

`remote/config.json`中的`subscriptionPath`和`initialClientSubId`是可选字段，推荐不填，程序会自动生成

没有`id_ed25519.pub`可以用`generate-ssh-key.ps1`生成一对，然后把生成的`id_ed25519.pub`（公钥，可以分发）放进`remote/`，把`id_ed25519`（私钥，注意保密）放进`%USERPROFILE%/.ssh/`

确保`remote/config.json`符合schema

## 远程部署

`pwsh init.ps1`启动一键部署脚本后等待20分钟左右

`pwsh ssh-tunnel.ps1`启动ssh转发通道，进入3x-ui面板配置客户端

- 用户名：{3xusername}
- 密码：{3xpassword}

客户端 > 添加客户端
- 基本 > 关联入站 > 全选
- 凭据 > Flow > `xtls-rprx-vision`
创建

二维码 > 复制订阅信息

需要管理几个用户就创几个客户端

# Warning

本脚本并不幂等，需要在重建后的vps上干净安装

频繁重新部署可能会触发CA速率限制，不要这样

泄漏`log/`或`remote/config.json`约等于失去server，请重建

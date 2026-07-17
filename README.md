[简体中文](README.zh-Hans.md)

# 3X-UI One-Click Deployment Script

The best one-click proxy server deployment script based on 3X-UI. Achieve server security hardening, masquerade site setup, Xray inbound creation, 3X-UI client synchronization, and TLS certificate management all in a single command. 100% transparent, open-source, and auditable. **If you find this repo helpful, please consider clicking Star & Fork. Thanks!**

This solution is based on the 3X-UI API to deploy multiple "steal-from-self" (co-located masquerading) configurations on the same server:
- Hysteria2 direct connection
- VLESS+Reality+Vision direct connection
- VLESS+XHTTP+Cloudflare CDN (Optimized IPs)
- VLESS+XHTTP+Cloudflare CDN (using your own Cloudflare domain)

This solution requires a dedicated proxy server with at least 500MB of RAM running Debian 13 or higher, and a local Windows environment (though with some minor AI assistance, it can be adapted to other operating systems).

The following is a usage tutorial and does not explain the underlying principles in detail. Users with command-line experience can read the development documentation `doc.md`.

## Cloudflare Settings

- Create two A/AAAA records in Cloudflare pointing to the real IP of your proxy server:
	- `cdnDomain`: Proxied through Cloudflare CDN (enable the orange cloud).
	- `directDomain`: DNS only (disable the orange cloud).
- Set a high-numbered origin pull port for `cdnDomain`, and note it down as `cdnPort`.
- Select **Full (strict)** for the SSL/TLS encryption mode.
- Enable **Always Use HTTPS**.
- Enable **TLS 1.3**.
- Set **Minimum TLS Version** to 1.3.
- Enable **gRPC**.
- Generate a Cloudflare Origin CA ECC certificate and private key for `cdnDomain`:
	- Go to **SSL/TLS** -> **Origin Server**.
	- Click **Create Certificate**.
	- Choose **ECC** for the Private Key type.
	- Enter `cdnDomain` in the hostnames field, or use a wildcard domain that covers it.
	- Select **PEM** for the certificate format.
	- Save the origin certificate as `cert.pem` and the private key as `key.pem`.

`cert.pem` looks like this:

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

`key.pem` looks like this:

```pem
-----BEGIN PRIVATE KEY-----
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
xxxxxxxxxxxxxxxxx+xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/xx
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/xxxxxxxxxxxxxxxxxxxxx
-----END PRIVATE KEY-----
```

If `cdnDomain` or `directDomain` is a subdomain, it is recommended to also enable the orange cloud for the main domain and the `www` subdomain and point them to the same server. This reduces the risk of fingerprinting exposure caused by an exposed root domain.

## Local File Preparation

First rebuild the proxy server and clone this repo **locally**, then manually prepare the following files inside `remote/` according to the guidelines below:

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

Place the certificate `cert.pem` and private key `key.pem` obtained from Cloudflare in the previous step into `remote/`.

---

To fill in `config.json`, you can first create:

```json
{
	"$schema": "config.schema.json"
}
```

Then, based on `remote/config.schema.json`, use an IDE like VS Code with JSON LSP autocomplete to fill in the rest of the file until no warnings remain. If you get stuck, you can ask an AI for help.

---

Prepare the static masquerade site: (If you don't know how, you can let an AI generate it)
- `remote/fake-site/index.html` must exist.
- The masquerade site should look like a normal static website. Avoid blank pages or obvious placeholder/test text.
- During deployment, the script will copy the entire `remote/fake-site/` folder to the server. Caddy will then serve it on the probe and fallback paths.

## First Deployment

Once all the files above are ready, you can begin the deployment.

Install [PowerShell 7](https://github.com/PowerShell/PowerShell) on your local machine, ensure the built-in Windows OpenSSH is available, and then run:

```powershell
pwsh init.ps1
```

`init.ps1` will automatically generate key pairs, subscription links, encrypted client distribution pages, upload all remote files, and trigger the remote initialization. If a password is required, simply follow the terminal prompts. The `clients.tsv` file it generates contains the subscription distribution page URL that each client should receive — just send the listed URL directly to your clients. The entire server initialization process may take 5 to 20 minutes, depending on the server configuration. However, disconnecting the SSH connection after initiating remote execution will not interrupt the process, so there is no need to keep the terminal open and wait.

## Updating Client Information

To add, remove, or edit client information, edit the `clients` field in `remote/config.json` and then run:

```powershell
pwsh sync-clients.ps1
```

The script will upload the new `remote/config.json`, sync the client information, restart Xray, and re-generate `clients.tsv`.

**`init.ps1` and `sync-clients.ps1` will not modify existing key-value pairs in `remote/config.json`. As long as `remote/config.json` isn't lost or manually altered, client distribution URLs and subscription URLs will not be lost even if proxy server is rebuilt. In the future, if you need to modify inbound settings or even switch servers, clients only need to update their subscription once within the proxy client—no need to obtain new distribution URLs.**

Proxy-client update events and errors are stored in `~/3x-setup/log/fetch-apps-update.log` and can be downloaded by running `get-log.ps1`. A resource is disabled after three consecutive failed daily runs. After fixing the upstream or network problem, run `sudo /usr/local/sbin/3x-fetch-apps --reset RESOURCE_ID` on the VPS and then start `3x-fetch-apps.service`, or wait for the next daily run. `RESOURCE_ID` is the corresponding key in `proxyClientsFilenames`.

## Updating the Server

To update Debian packages and 3X-UI, then immediately check for proxy-client updates, run:

```powershell
pwsh update-all.ps1
```

The script connects with the deployed sudo user, runs `apt-get update`, `apt-get dist-upgrade -y`, and `x-ui update` in order, then starts `3x-fetch-apps.service` once and waits for all commands to finish. The client-update task must have been installed during deployment; a deployment created with `init.ps1 -NoAPP` does not include it.

## Connecting to the 3X-UI Panel

Generally, this solution does not require manual management of the 3X-UI panel. However, if you do need to access it, run:

```powershell
pwsh ssh-tunnel.ps1
```

## Warning

This solution was tested using 3X-UI version v3.5.0. If the 3X-UI API changes in the future, issues may arise. However, it is not recommended to pin the 3X-UI version just to use this solution. If you encounter any issues, please open an issue.

This project is not an idempotent deployer. It must be executed on a freshly rebuilt, clean server and should not be used on servers running existing production services.

Do not leak private configurations like `remote/config.json`. **If leaked, rebuild the server immediately and completely rewrite `remote/config.json`.**

If you want to test this script by rebuilding the server multiple times with the same domain, please use `pwsh init.ps1 -noTLS` to temporarily use self-signed certificates. This avoids triggering CA rate limits which would block certificate issuance. Note that due to the lack of a trusted certificate, the Hysteria2 inbound will not work under this mode. Self-signed certificates are for testing only—**never use them in production! You must rebuild the server immediately after testing!**

Regional ISPs may block QUIC traffic on certain IPs, which will make the Hysteria2 inbound unavailable. This is beyond our control.

This solution is configured for Mainland China by default. You can edit `remote/clash-rule.txt` to use it at other regions.

## Acknowledgements

- [Project X](https://github.com/XTLS/Xray-core)
- [3X-UI](https://github.com/MHSanaei/3x-ui)
- [saas.sin.fan](https://saas.sin.fan/)

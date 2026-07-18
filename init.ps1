<#
.SYNOPSIS
	远程初始化VPS脚本
.DESCRIPTION
	将 remote/ 目录打包上传到VPS，并远程后台启动 root-init.sh 完成VPS环境初始化
#>

[CmdletBinding()]
param(
	[switch]$NoTLS,
	[switch]$NoAPP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConfigSchemaPath = Join-Path $RemoteDir "config.schema.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"
$ConstantsSchemaPath = Join-Path $RemoteDir "constants.schema.json"
$TarPath = Join-Path $ProjectDir "3x-setup.tar"
$FakeSiteDir = Join-Path $RemoteDir "fake-site"
$ClientsTsvPath = Join-Path $ProjectDir "clients.tsv"
$ModuleDir = Join-Path $ProjectDir "modules"

# 自动准备部署所需的SSH密钥对
& (Join-Path $ProjectDir "generate-ssh-key.ps1")

Import-Module (Join-Path $ModuleDir "setup-config.psm1") -Force
Import-Module (Join-Path $ModuleDir "client-files.psm1") -Force

function Assert-ExitCode
{
	<#
	.SYNOPSIS
		检查命令退出码
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$ExitCode,

		[Parameter(Mandatory = $true)]
		[string]$FailureMessage
	)

	if ($ExitCode -ne 0)
	{
		throw $FailureMessage
	}
}

function Complete-SetupPorts
{
	<#
	.SYNOPSIS
		检查部署端口互不冲突并补齐SSH端口
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[Parameter(Mandatory = $true)]
		[pscustomobject]$Constants
	)

	$ReservedPorts = [ordered]@{
		realityTargetPort = [int]$Constants.realityTargetPort
		fakeSitePort = [int]$Constants.fakeSitePort
		xhttpPort = [int]$Constants.xhttpPort
		subscriptionPort = [int]$Constants.subscriptionPort
		"3xpanelPort" = [int]$Constants."3xpanelPort"
		cdnPort = [int]$Config.cdnPort
		"443" = 443
		"80" = 80
	}
	$PortConflicts = @($ReservedPorts.GetEnumerator() | Group-Object -Property Value | Where-Object { $_.Count -gt 1 })
	if ($PortConflicts.Count -gt 0)
	{
		$ConflictDetails = @($PortConflicts | ForEach-Object {
				$Names = @($_.Group | ForEach-Object { [string]$_.Key }) -join ", "
				"$($_.Name) ($Names)"
			}) -join "; "
		throw "reserved ports must be unique: $ConflictDetails"
	}

	$SshPortProperty = $Config.PSObject.Properties["sshPort"]
	if ($null -eq $SshPortProperty)
	{
		do
		{
			$SshPort = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(10001, 65536)
		} while ($ReservedPorts.Values -contains $SshPort)
		$Config | Add-Member -MemberType NoteProperty -Name "sshPort" -Value $SshPort
		return
	}

	$SshPort = [int]$SshPortProperty.Value
	if ($ReservedPorts.Values -contains $SshPort)
	{
		$ConflictName = [string]@($ReservedPorts.GetEnumerator() | Where-Object { $_.Value -eq $SshPort } | Select-Object -First 1).Key
		throw "sshPort conflicts with ${ConflictName}: $SshPort"
	}
}

# 验证必需文件存在
$RequiredFiles = @(
	"fake-site/index.html",
	"cert.pem",
	"key.pem",
	"id_ed25519.pub",
	"config.json",
	"config.schema.json",
	"constants.json",
	"constants.schema.json",
	"clash-rule.txt",
	"Caddyfile.template",
	"root-init.sh",
	"user-init.sh",
	"service-check.sh",
	"caddy-init.sh",
	"caddy-check.sh",
	"3x-panel-init.sh",
	"3x-panel-check.sh",
	"3x-inbound-init.sh",
	"3x-inbound-check.sh",
	"cf-host-init.sh",
	"cf-host-check.sh",
	"3x-client-init.sh",
	"3x-client-check.sh",
	"fetch-apps-init.sh",
	"fetch-apps-check.sh",
	"direct-tls-init.sh",
	"direct-tls-check.sh"
)

foreach ($RelativePath in $RequiredFiles)
{
	$FullPath = Join-Path $RemoteDir $RelativePath
	if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf))
	{
		throw "missing file: $RelativePath"
	}
}

# 读取并解析 config.json 和 constants.json
$ConfigFiles = Read-SetupConfigFiles `
	-ConfigPath $ConfigPath `
	-ConfigSchemaPath $ConfigSchemaPath `
	-ConstantsPath $ConstantsPath `
	-ConstantsSchemaPath $ConstantsSchemaPath
$Config = $ConfigFiles.Config
$Constants = $ConfigFiles.Constants

# 补齐 config.json 自动生成字段
Complete-SetupConfig -Config $Config -IncludeSubscriptionPath
Complete-SetupPorts -Config $Config -Constants $Constants

# 检查 config.json 中的客户端名和订阅路径不重复
Assert-SetupClientConfigValid -Config $Config -RequireSubscriptionPath
Assert-SetupCdnOptDomainsValid -Config $Config
Assert-SetupConstantsValid -Constants $Constants

# 写回自动生成字段并导出客户分发页面和URL清单
Save-SetupConfig -Config $Config -ConfigPath $ConfigPath
$DistributionDir = Join-Path $FakeSiteDir ([string]$Config.distributionPath)
Export-ClientFiles -Config $Config -Constants $Constants -DistributionDir $DistributionDir -ClientsTsvPath $ClientsTsvPath

$RemoteHost = $Config.ip
$InitialSshPort = $Constants.initialSshPort

# 将 remote/ 中的文本文件转换成LF
$TextExtensions = @(".html", ".json", ".pem", ".pub", ".sh", ".template", ".txt")
Get-ChildItem -LiteralPath $RemoteDir -Recurse -File | ForEach-Object {
	if ($TextExtensions -contains $_.Extension)
	{
		$Content = Get-Content -LiteralPath $_.FullName -Raw
		$Content = $Content -replace "`r`n", "`n" -replace "`r", "`n"
		Set-Content -LiteralPath $_.FullName -Value $Content -NoNewline -Encoding utf8NoBOM
	}
}

# 打包 remote/ 为 3x-setup.tar
tar -cf $TarPath -C $RemoteDir .

$RemoteInitArgs = @()
if ($NoTLS.IsPresent)
{
	$RemoteInitArgs += "--noTLS"
}
if ($NoAPP.IsPresent)
{
	$RemoteInitArgs += "--noAPP"
}
$RemoteInitArgs = if ($RemoteInitArgs.Count -gt 0)
{
	" " + ($RemoteInitArgs -join " ")
} else
{
	""
}

$RemoteCommand = @"
mkdir -p /root/3x-setup && tar -xf /root/3x-setup.tar -C /root/3x-setup && (setsid bash -c 'exec bash /root/3x-setup/root-init.sh$RemoteInitArgs </dev/null' >/dev/null 2>&1 < /dev/null & RemotePid=`$!; echo 'Remote initialization has started in the background; waiting for it to complete'; wait `$RemotePid)
"@

Write-Host "Uploading 3x-setup.tar to $RemoteHost"
$UploadExitCode = 1
$InitExitCode = 1
try
{
	$ScpCommand = Get-Command "scp" -ErrorAction SilentlyContinue | Select-Object -First 1
	$SshCommand = Get-Command "ssh" -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($null -eq $ScpCommand)
	{
		throw "OpenSSH scp is required"
	}
	if ($null -eq $SshCommand)
	{
		throw "OpenSSH ssh is required"
	}
	$ScpPath = $ScpCommand.Source
	$SshPath = $SshCommand.Source
	$SshHostKeyOptions = @(
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=NUL",
		"-o", "LogLevel=ERROR"
	)

	& $ScpPath @SshHostKeyOptions -P $InitialSshPort $TarPath "root@${RemoteHost}:/root/3x-setup.tar"
	$UploadExitCode = $LASTEXITCODE
	Assert-ExitCode -ExitCode $UploadExitCode -FailureMessage "Failed to upload 3x-setup.tar"

	Write-Host "Starting remote initialization"
	$RemoteInitializationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	& $SshPath @SshHostKeyOptions -p $InitialSshPort "root@$RemoteHost" $RemoteCommand
	$InitExitCode = $LASTEXITCODE
} finally
{
	Remove-Item -LiteralPath $TarPath -Force -ErrorAction SilentlyContinue
}
Assert-ExitCode -ExitCode $InitExitCode -FailureMessage "Failed to start remote initialization"
$RemoteInitializationStopwatch.Stop()
Write-Host ("Remote initialization completed in {0}" -f $RemoteInitializationStopwatch.Elapsed.ToString("hh\:mm\:ss"))

# SSH正常退出后自动下载日志
& (Join-Path $ProjectDir "get-log.ps1")

<#
.SYNOPSIS
	同步远程3x-ui客户端
.DESCRIPTION
	上传 remote/config.json 到已有VPS，远程执行 3x-client-init.sh --noTLS，同步完成后下载日志
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConfigSchemaPath = Join-Path $RemoteDir "config.schema.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"
$ConstantsSchemaPath = Join-Path $RemoteDir "constants.schema.json"
$ClientsDir = Join-Path $ProjectDir "clients"
$ModuleDir = Join-Path $ProjectDir "modules"

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

# 读取并解析 config.json 和 constants.json
$ConfigFiles = Read-SetupConfigFiles `
	-ConfigPath $ConfigPath `
	-ConfigSchemaPath $ConfigSchemaPath `
	-ConstantsPath $ConstantsPath `
	-ConstantsSchemaPath $ConstantsSchemaPath
$Config = $ConfigFiles.Config
$Constants = $ConfigFiles.Constants

# 补齐 config.json 自动生成字段
Complete-SetupConfig -Config $Config

# 检查 config.json 中的客户端名和订阅路径不重复
Assert-SetupClientConfigValid -Config $Config -RequireSubscriptionPath

# 写回自动生成字段并导出本地客户端订阅文件
Save-SetupConfig -Config $Config -ConfigPath $ConfigPath
Export-ClientFiles -Config $Config -Constants $Constants -ClientsDir $ClientsDir

$RemoteHost = $Config.ip
$SshPort = $Config.sshPort
$Username = $Constants.username
$SshTarget = "${Username}@${RemoteHost}"
$SshHostKeyOptions = @(
	"-o", "StrictHostKeyChecking=no",
	"-o", "UserKnownHostsFile=NUL",
	"-o", "LogLevel=ERROR",
	"-o", "BatchMode=yes"
)

$SshPath = (Get-Command "ssh" -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$SftpPath = (Get-Command "sftp" -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ([string]::IsNullOrWhiteSpace($SshPath))
{
	throw "OpenSSH ssh is required"
}
if ([string]::IsNullOrWhiteSpace($SftpPath))
{
	throw "OpenSSH sftp is required"
}

$SftpBatchPath = Join-Path $ProjectDir "sync-clients-$([Guid]::NewGuid().ToString("N")).sftp"
$RemoteCommand = "cd ~/3x-setup && (setsid bash -c 'exec bash ./3x-client-init.sh --noTLS </dev/null' >/dev/null 2>&1 < /dev/null & RemotePid=`$!; echo 'Remote client sync has started in the background; waiting for it to complete'; wait `$RemotePid)"

try
{
	$ConfigSftpPath = $ConfigPath -replace "\\", "/"
	$SftpCommands = @(
		"put `"$ConfigSftpPath`" `"3x-setup/config.json`"",
		"bye"
	)
	Set-Content -LiteralPath $SftpBatchPath -Encoding ascii -Value $SftpCommands

	Write-Host "Uploading remote/config.json to $RemoteHost"
	& $SftpPath @SshHostKeyOptions -P $SshPort -b $SftpBatchPath $SshTarget
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to upload remote/config.json"
} finally
{
	Remove-Item -LiteralPath $SftpBatchPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Starting remote client sync"
& $SshPath @SshHostKeyOptions -p $SshPort $SshTarget $RemoteCommand
Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to sync remote clients"

& (Join-Path $ProjectDir "get-log.ps1")

$global:LASTEXITCODE = 0

<#
.SYNOPSIS
	SSH转发本地端口到3x-ui面板端口
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ModuleDir = Join-Path $ProjectDir "modules"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"
$LogScriptPath = Join-Path $ProjectDir "get-log.ps1"

Import-Module (Join-Path $ModuleDir "ssh-host-recovery.psm1") -Force

# 读取并解析 config.json 和 constants.json
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Constants = Get-Content -LiteralPath $ConstantsPath -Raw | ConvertFrom-Json
$RemoteHost = $Config.ip
$SshPort = $Config.sshPort
$Username = $Constants.username
$LocalSshPort = $Constants.localSshPort
$PanelPort = $Constants.'3xpanelPort'
$PanelUriPath = $Constants.'3xpanelUriPath'
$PanelUsername = $Constants.'3xusername'
$PanelPassword = $Constants.'3xpassword'
$SshTarget = "${Username}@${RemoteHost}"
$SshOptions = @(
	"-o", "ExitOnForwardFailure=yes",
	"-o", "BatchMode=yes"
)
$SshArguments = @(
	$SshOptions
	"-N"
	"-L"
	"${LocalSshPort}:127.0.0.1:${PanelPort}"
	"-p"
	$SshPort
	$SshTarget
)
$HostKeyRecoveryAttempted = $false

# 建立SSH转发
Write-Host "Establishing SSH forwarding..."
$SshProcess = Start-Process -FilePath "ssh" -ArgumentList $SshArguments -NoNewWindow -PassThru
$TunnelReady = $false
$Deadline = (Get-Date).AddSeconds(10)

while ((Get-Date) -lt $Deadline)
{
	if ($SshProcess.HasExited)
	{
		$TunnelExitCode = $SshProcess.ExitCode
		if ($TunnelExitCode -eq 255 -and -not $HostKeyRecoveryAttempted)
		{
			$RecoverySucceeded = $false
			Invoke-HostKeyRecovery `
				-LogScriptPath $LogScriptPath `
				-Attempted ([ref]$HostKeyRecoveryAttempted) `
				-Succeeded ([ref]$RecoverySucceeded)
			if ($RecoverySucceeded)
			{
				$SshProcess = Start-Process -FilePath "ssh" -ArgumentList $SshArguments -NoNewWindow -PassThru
				$Deadline = (Get-Date).AddSeconds(10)
				continue
			}
		}
		throw "SSH tunnel failed. Exit code: $TunnelExitCode"
	}

	$TcpClient = [System.Net.Sockets.TcpClient]::new()
	try
	{
		$ConnectTask = $TcpClient.ConnectAsync("127.0.0.1", [int]$LocalSshPort)
		if ($ConnectTask.Wait(500))
		{
			$TunnelReady = $true
			break
		}
	} finally
	{
		$TcpClient.Dispose()
	}

	Start-Sleep -Milliseconds 500
}

if (-not $TunnelReady)
{
	Stop-Process -Id $SshProcess.Id -Force
	throw "Timed out waiting for SSH tunnel on local port $LocalSshPort"
}

$PanelUrl = "http://127.0.0.1:$LocalSshPort/$PanelUriPath"
Write-Host "SSH tunnel established."
Write-Host "3X-UI panel: $PanelUrl"
Write-Host "username: $PanelUsername"
Write-Host "password: $PanelPassword"
Start-Process $PanelUrl
Write-Host "Press Ctrl+C to disconnect."

try
{
	Wait-Process -Id $SshProcess.Id
} finally
{
	if (-not $SshProcess.HasExited)
	{
		Stop-Process -Id $SshProcess.Id -Force
	}
}

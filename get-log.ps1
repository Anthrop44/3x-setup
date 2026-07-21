<#
.SYNOPSIS
	下载远程初始化日志
.DESCRIPTION
	从 remote/config.json 和 remote/constants.json 读取连接信息，让远端先打包 log/ ，再下载并解包到本地
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"
$ModuleDir = Join-Path $ProjectDir "modules"

Import-Module (Join-Path $ModuleDir "assert-exit-code.psm1") -Force

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Constants = Get-Content -LiteralPath $ConstantsPath -Raw | ConvertFrom-Json
$RemoteHost = $Config.ip
$SshPort = $Config.sshPort
$Username = $Constants.username
$RemoteLogDir = "~/3x-setup/log"
$LocalLogDir = Join-Path $ProjectDir "log"

$ArchiveName = "3x-setup-log-$([Guid]::NewGuid().ToString("N")).tar"
$RemoteArchivePath = "/tmp/$ArchiveName"
$LocalArchivePath = $ArchiveName
$SftpBatchPath = "$ArchiveName.sftp"
$SshTarget = "${Username}@${RemoteHost}"
$SshHostKeyOptions = @(
	"-o", "StrictHostKeyChecking=no",
	"-o", "UserKnownHostsFile=NUL",
	"-o", "LogLevel=ERROR"
)

# 轮转本地非空 log 目录，空 log 目录直接复用
if (Test-Path -LiteralPath $LocalLogDir -PathType Container)
{
	$ExistingLogItem = Get-ChildItem -LiteralPath $LocalLogDir -Force | Select-Object -First 1
	if ($null -ne $ExistingLogItem)
	{
		$LogIndex = 0
		do
		{
			$BackupLogDir = Join-Path $ProjectDir "log$LogIndex"
			$LogIndex++
		} while (Test-Path -LiteralPath $BackupLogDir)

		Write-Host "Renaming existing log directory to $(Split-Path -Leaf $BackupLogDir)/ ..."
		Move-Item -LiteralPath $LocalLogDir -Destination $BackupLogDir
	}
}

New-Item -ItemType Directory -Path $LocalLogDir -Force | Out-Null

try
{
	Write-Host "Creating remote tar archive from $RemoteLogDir/ ..."
	$RemoteTarCommand = "tar -C $RemoteLogDir -cf $RemoteArchivePath . || { rm -f $RemoteArchivePath; exit 1; }"
	ssh @SshHostKeyOptions -p $SshPort $SshTarget $RemoteTarCommand
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to create remote log archive"

	$LocalArchiveSftpPath = $LocalArchivePath -replace "\\", "/"
	$SftpCommands = @(
		"get `"$RemoteArchivePath`" `"$LocalArchiveSftpPath`"",
		"rm `"$RemoteArchivePath`"",
		"bye"
	)
	Set-Content -LiteralPath $SftpBatchPath -Encoding ascii -Value $SftpCommands

	Write-Host "Downloading archive to $LocalArchivePath ..."
	sftp @SshHostKeyOptions -P $SshPort -b $SftpBatchPath $SshTarget
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to download remote log archive"

	Write-Host "Extracting archive to $LocalLogDir/ ..."
	tar -xf $LocalArchivePath -C $LocalLogDir
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to extract log archive"

	Write-Host "Successfully fetched:"
	Get-ChildItem -LiteralPath $LocalLogDir -File | ForEach-Object {
		Write-Host $_.Name
	}
} finally
{
	Remove-Item -LiteralPath $SftpBatchPath -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath $LocalArchivePath -Force -ErrorAction SilentlyContinue
}

$global:LASTEXITCODE = 0

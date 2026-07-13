<#
.SYNOPSIS
	远程初始化VPS脚本
.DESCRIPTION
	将 remote/ 目录打包上传到VPS，并远程后台启动 root-init.sh 完成VPS环境初始化
#>

[CmdletBinding()]
param(
	[switch]$NoTLS,
	[switch]$PuTTY
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
$ClientsDir = Join-Path $ProjectDir "clients"
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

function Invoke-NativeCommand
{
	<#
	.SYNOPSIS
		运行外部命令，并按需捕获输出
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$FilePath,

		[Parameter(Mandatory = $true)]
		[string[]]$ArgumentList,

		[switch]$CaptureOutput
	)

	$StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
	$StartInfo.FileName = $FilePath
	$StartInfo.UseShellExecute = $false
	$StartInfo.RedirectStandardOutput = $CaptureOutput.IsPresent
	$StartInfo.RedirectStandardError = $CaptureOutput.IsPresent

	foreach ($Argument in $ArgumentList)
	{
		[void]$StartInfo.ArgumentList.Add($Argument)
	}

	$Process = [System.Diagnostics.Process]::new()
	$Process.StartInfo = $StartInfo
	[void]$Process.Start()

	$StdOut = ""
	$StdErr = ""
	if ($CaptureOutput.IsPresent)
	{
		$StdOut = $Process.StandardOutput.ReadToEnd()
		$StdErr = $Process.StandardError.ReadToEnd()
	}

	$Process.WaitForExit()
	return [pscustomobject]@{
		ExitCode = $Process.ExitCode
		StdOut = $StdOut
		StdErr = $StdErr
	}
}

function Invoke-PuttyAutoAcceptHostKey
{
	<#
	.SYNOPSIS
		以非交互方式运行PuTTY工具，并自动接受首次连接时看到的主机密钥
	.DESCRIPTION
		PuTTY没有稳定的非交互式跳过主机密钥校验开关。这里先用 -batch 探测一次，解析PuTTY输出中的新主机密钥指纹，再用 -hostkey 显式信任该指纹重试，从而避免交互提示卡住
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$FilePath,

		[Parameter(Mandatory = $true)]
		[string[]]$ArgumentList
	)

	$BatchArgs = @("-batch") + $ArgumentList
	$ProbeResult = Invoke-NativeCommand -FilePath $FilePath -ArgumentList $BatchArgs -CaptureOutput
	if ($ProbeResult.ExitCode -eq 0)
	{
		return 0
	}

	$ProbeText = "$($ProbeResult.StdOut)`n$($ProbeResult.StdErr)"
	# 从PuTTY输出中提取服务端主机密钥指纹
	$HostKeyFingerprint = ""
	$Match = [regex]::Match($ProbeText, "(?m)^\s*((?:ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-\S+)\s+\d+\s+SHA256:[A-Za-z0-9+/=]+)\s*$")
	if ($Match.Success)
	{
		$HostKeyFingerprint = $Match.Groups[1].Value
	}

	if ([string]::IsNullOrWhiteSpace($HostKeyFingerprint))
	{
		Write-Host $ProbeResult.StdOut
		Write-Host $ProbeResult.StdErr
		return $ProbeResult.ExitCode
	}

	$TrustedArgs = @("-batch", "-hostkey", $HostKeyFingerprint) + $ArgumentList
	$TrustedResult = Invoke-NativeCommand -FilePath $FilePath -ArgumentList $TrustedArgs
	return $TrustedResult.ExitCode
}

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

# 检查 config.json 中的客户端名和订阅路径不重复
Assert-SetupClientConfigValid -Config $Config -RequireSubscriptionPath
Assert-SetupConstantsValid -Constants $Constants

# 写回自动生成字段并导出本地客户端订阅文件
Save-SetupConfig -Config $Config -ConfigPath $ConfigPath
Export-ClientFiles -Config $Config -Constants $Constants -ClientsDir $ClientsDir

$RemoteHost = $Config.ip
$InitialSshPort = $Constants.initialSshPort
$SshPort = $Config.sshPort

# 打包 remote/ 为 3x-setup.tar
tar -cf $TarPath -C $RemoteDir .

$RemoteInitArgs = if ($NoTLS.IsPresent)
{
	" --noTLS"
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
	if ($PuTTY.IsPresent)
	{
		$InitialPassword = ""
		$InitialPasswordProperty = $Config.PSObject.Properties["initialPassword"]
		if ($null -ne $InitialPasswordProperty)
		{
			$InitialPassword = [string]$InitialPasswordProperty.Value
		}
		if ([string]::IsNullOrWhiteSpace($InitialPassword))
		{
			throw "remote/config.json initialPassword is required when using -PuTTY"
		}

		# 找到PuTTY组件
		$PscpCommand = Get-Command "pscp.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
		$PlinkCommand = Get-Command "plink.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $PscpCommand)
		{
			throw "PuTTY pscp.exe is required"
		}
		if ($null -eq $PlinkCommand)
		{
			throw "PuTTY plink.exe is required"
		}
		$PscpPath = $PscpCommand.Source
		$PlinkPath = $PlinkCommand.Source

		# 清除PuTTY已知主机记录
		$PuttySshHostKeysPath = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
		if (Test-Path -LiteralPath $PuttySshHostKeysPath)
		{
			foreach ($Port in @($InitialSshPort, $SshPort))
			{
				$Pattern = "*@$($Port):$RemoteHost"
				$PropertyNames = (Get-Item -LiteralPath $PuttySshHostKeysPath).Property | Where-Object { $_ -like $Pattern }
				foreach ($PropertyName in $PropertyNames)
				{
					Remove-ItemProperty -LiteralPath $PuttySshHostKeysPath -Name $PropertyName -ErrorAction SilentlyContinue
				}
			}
		}

		$PscpArgs = @(
			"-P", $InitialSshPort,
			"-pw", $InitialPassword,
			$TarPath,
			"root@${RemoteHost}:/root/3x-setup.tar"
		)
		$PlinkArgs = @(
			"-ssh",
			"-T",
			"-no-antispoof",
			"-P", $InitialSshPort,
			"-pw", $InitialPassword,
			"root@$RemoteHost",
			$RemoteCommand
		)

		# 使用PuTTY上传并启动远程初始化
		$UploadExitCode = Invoke-PuttyAutoAcceptHostKey -FilePath $PscpPath -ArgumentList $PscpArgs
		Assert-ExitCode -ExitCode $UploadExitCode -FailureMessage "Failed to upload 3x-setup.tar"

		Write-Host "Starting remote initialization"
		$InitExitCode = Invoke-PuttyAutoAcceptHostKey -FilePath $PlinkPath -ArgumentList $PlinkArgs
	} else
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
		& $SshPath @SshHostKeyOptions -p $InitialSshPort "root@$RemoteHost" $RemoteCommand
		$InitExitCode = $LASTEXITCODE
	}
} finally
{
	Remove-Item -LiteralPath $TarPath -Force -ErrorAction SilentlyContinue
}
Assert-ExitCode -ExitCode $InitExitCode -FailureMessage "Failed to start remote initialization"

# SSH正常退出后自动下载日志
& (Join-Path $ProjectDir "get-log.ps1")

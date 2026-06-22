<#
.SYNOPSIS
	远程初始化VPS脚本
.DESCRIPTION
	将 remote/ 目录打包上传到VPS，并远程后台启动 root-init.sh 完成VPS环境初始化
	PuTTY可用于coding agents非交互式使用，因此不会把远端log print出来，看着会像卡住
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"
$TarPath = Join-Path ([IO.Path]::GetTempPath()) "3x-setup.tar"

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

function Get-PuttyHostKeyFingerprint
{
	<#
	.SYNOPSIS
		从PuTTY输出中提取服务端主机密钥指纹
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Text
	)

	$Match = [regex]::Match($Text, "(?m)^\s*((?:ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-\S+)\s+\d+\s+SHA256:[A-Za-z0-9+/=]+)\s*$")
	if ($Match.Success)
	{
		return $Match.Groups[1].Value
	}

	return ""
}

function Invoke-PuttyAutoAcceptHostKey
{
	<#
	.SYNOPSIS
		以非交互方式运行PuTTY工具，并自动接受首次连接时看到的主机密钥
	.DESCRIPTION
		PuTTY没有等价于OpenSSH StrictHostKeyChecking=no 的稳定跳过开关。
		这里先用 -batch 探测一次，解析PuTTY输出中的新主机密钥指纹，
		再用 -hostkey 显式信任该指纹重试，从而避免交互提示卡住。
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
	$HostKeyFingerprint = Get-PuttyHostKeyFingerprint -Text $ProbeText
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

function Clear-PuttyHostKeyCache
{
	<#
	.SYNOPSIS
		清除PuTTY缓存的旧主机密钥
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$HostName,

		[Parameter(Mandatory = $true)]
		[object[]]$Ports
	)

	$PuttySshHostKeysPath = "HKCU:\Software\SimonTatham\PuTTY\SshHostKeys"
	if (-not (Test-Path -LiteralPath $PuttySshHostKeysPath))
	{
		return
	}

	foreach ($Port in $Ports)
	{
		$Pattern = "*@$($Port):$HostName"
		$PropertyNames = (Get-Item -LiteralPath $PuttySshHostKeysPath).Property | Where-Object { $_ -like $Pattern }
		foreach ($PropertyName in $PropertyNames)
		{
			Remove-ItemProperty -LiteralPath $PuttySshHostKeysPath -Name $PropertyName -ErrorAction SilentlyContinue
		}
	}
}

function Invoke-PuttyRoute
{
	<#
	.SYNOPSIS
		使用PuTTY上传并启动远程初始化
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$PscpPath,

		[Parameter(Mandatory = $true)]
		[string[]]$PscpArgumentList,

		[Parameter(Mandatory = $true)]
		[string]$PlinkPath,

		[Parameter(Mandatory = $true)]
		[string[]]$PlinkArgumentList,

		[Parameter(Mandatory = $true)]
		[string]$RemoteHost
	)

	Write-Host "上传 3x-setup.tar 到 $RemoteHost"
	$UploadExitCode = Invoke-PuttyAutoAcceptHostKey -FilePath $PscpPath -ArgumentList $PscpArgumentList
	Assert-ExitCode -ExitCode $UploadExitCode -FailureMessage "上传3x-setup.tar失败"

	Write-Host "启动远程初始化"
	$InitExitCode = Invoke-PuttyAutoAcceptHostKey -FilePath $PlinkPath -ArgumentList $PlinkArgumentList
	Assert-ExitCode -ExitCode $InitExitCode -FailureMessage "启动远程初始化失败"
}

function Invoke-OpenSshRoute
{
	<#
	.SYNOPSIS
		使用OpenSSH上传并启动远程初始化
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$ScpArgumentList,

		[Parameter(Mandatory = $true)]
		[string[]]$SshArgumentList,

		[Parameter(Mandatory = $true)]
		[string]$RemoteHost
	)

	Write-Host "上传 3x-setup.tar 到 $RemoteHost"
	& scp @ScpArgumentList
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "上传3x-setup.tar失败"

	Write-Host "启动远程初始化"
	& ssh @SshArgumentList
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "启动远程初始化失败"
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
	"direct-tls-init.sh",
	"direct-tls-check.sh"
)

foreach ($RelativePath in $RequiredFiles)
{
	$FullPath = Join-Path $RemoteDir $RelativePath
	if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf))
	{
		throw "remote/ 缺少文件： $RelativePath"
	}
}

# 读取并解析 config.json 和 constants.json
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Constants = Get-Content -LiteralPath $ConstantsPath -Raw | ConvertFrom-Json
$RemoteHost = $Config.ip
$InitialSshPort = $Constants.initialSshPort
$SshPort = $Config.sshPort
$InitialPassword = if ($Config.PSObject.Properties.Name -contains "initialPassword")
{
	[string]$Config.initialPassword
} else
{
	""
}
$PlinkCommand = Get-Command "plink.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
$PscpCommand = Get-Command "pscp.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
$PscpPath = if ($null -ne $PscpCommand)
{
	$PscpCommand.Source
} else
{
	""
}
$PlinkPath = if ($null -ne $PlinkCommand)
{
	$PlinkCommand.Source
} else
{
	""
}
$UsePuttySsh = -not [string]::IsNullOrWhiteSpace($PscpPath) -and -not [string]::IsNullOrWhiteSpace($PlinkPath) -and -not [string]::IsNullOrWhiteSpace($InitialPassword)

# 清除OpenSSH已知主机记录
ssh-keygen -R $RemoteHost | Out-Null
ssh-keygen -R "[$RemoteHost]:$InitialSshPort" | Out-Null
ssh-keygen -R "[$RemoteHost]:$SshPort" | Out-Null
# 清除PuTTY已知主机记录
Clear-PuttyHostKeyCache -HostName $RemoteHost -Ports @($InitialSshPort, $SshPort)

# 打包 remote/ 为 3x-setup.tar
tar -cf $TarPath -C $RemoteDir .

# 命令远端解包 3x-setup.tar 并后台执行 root-init.sh
$RemoteCommand = @'
mkdir -p /root/3x-setup && tar -xf /root/3x-setup.tar -C /root/3x-setup && (setsid bash -c 'exec bash /root/3x-setup/root-init.sh </dev/null' >/dev/null 2>&1 < /dev/null & RemotePid=$!; echo '远程初始化已后台启动，等待初始化完成'; wait $RemotePid)
'@

# PuTTY args
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

# OpenSSH args
$ScpArgs = @(
	"-P", $InitialSshPort,
	$TarPath,
	"root@${RemoteHost}:/root/3x-setup.tar"
)
$SshArgs = @(
	"-n",
	"-T",
	"-p", $InitialSshPort,
	"root@$RemoteHost",
	$RemoteCommand
)

# 有PuTTY且配置了初始密码时走PuTTY，否则fallback到OpenSSH
if ($UsePuttySsh)
{
	Invoke-PuttyRoute `
		-PscpPath $PscpPath `
		-PscpArgumentList $PscpArgs `
		-PlinkPath $PlinkPath `
		-PlinkArgumentList $PlinkArgs `
		-RemoteHost $RemoteHost
} else
{
	Invoke-OpenSshRoute `
		-ScpArgumentList $ScpArgs `
		-SshArgumentList $SshArgs `
		-RemoteHost $RemoteHost
}

# SSH正常退出后自动下载日志
& (Join-Path $ProjectDir "get-log.ps1")

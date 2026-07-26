Set-StrictMode -Version Latest

function Invoke-HostKeyRecovery
{
	<#
	.SYNOPSIS
		主机真实性验证失败后尝试获取日志
	.DESCRIPTION
		每次脚本执行最多调用一次 get-log.ps1，只有日志成功获取后才允许重试原命令
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$LogScriptPath,

		[Parameter(Mandatory = $true)]
		[ref]$Attempted,

		[Parameter(Mandatory = $true)]
		[ref]$Succeeded
	)

	$Succeeded.Value = $false
	if ($Attempted.Value)
	{
		return
	}

	$Attempted.Value = $true
	Write-Host "SSH returned exit code 255; attempting to fetch logs once before retrying"
	try
	{
		& $LogScriptPath
		if ($LASTEXITCODE -ne 0)
		{
			throw "get-log.ps1 exited with code $LASTEXITCODE"
		}
		$Succeeded.Value = $true
	} catch
	{
		Write-Warning ("Automatic log fetch failed: {0}" -f $_.Exception.Message)
	}
}

function Invoke-CommandWithHostKeyRecovery
{
	<#
	.SYNOPSIS
		执行SSH命令并在主机真实性验证失败后恢复一次
	.DESCRIPTION
		当命令返回255时先获取远程日志，日志成功获取后仅重试原命令一次
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[scriptblock]$Command,

		[Parameter(Mandatory = $true)]
		[string]$LogScriptPath,

		[Parameter(Mandatory = $true)]
		[ref]$Attempted
	)

	& $Command
	$CommandExitCode = [int]$LASTEXITCODE
	if ($CommandExitCode -ne 255 -or $Attempted.Value)
	{
		return
	}

	$RecoverySucceeded = $false
	Invoke-HostKeyRecovery `
		-LogScriptPath $LogScriptPath `
		-Attempted $Attempted `
		-Succeeded ([ref]$RecoverySucceeded)
	if ($RecoverySucceeded)
	{
		& $Command
	} else
	{
		$global:LASTEXITCODE = $CommandExitCode
	}
}

Export-ModuleMember -Function Invoke-HostKeyRecovery, Invoke-CommandWithHostKeyRecovery

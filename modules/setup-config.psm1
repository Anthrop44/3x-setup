Set-StrictMode -Version Latest

function Assert-JsonSchemaValid
{
	<#
	.SYNOPSIS
		检查json文件符合对应schema
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$JsonPath,

		[Parameter(Mandatory = $true)]
		[string]$SchemaPath
	)

	$ValidationErrors = @()
	$IsValid = Test-Json `
		-Json (Get-Content -LiteralPath $JsonPath -Raw) `
		-SchemaFile $SchemaPath `
		-ErrorVariable ValidationErrors `
		-ErrorAction SilentlyContinue

	if (-not $IsValid)
	{
		$JsonRelativePath = Resolve-Path -LiteralPath $JsonPath -Relative
		$SchemaRelativePath = Resolve-Path -LiteralPath $SchemaPath -Relative
		$ErrorMessage = if ($ValidationErrors.Count -gt 0)
		{
			($ValidationErrors | ForEach-Object { $_.Exception.Message }) -join "`n"
		} else
		{
			"Unknown schema validation error"
		}

		throw "$JsonRelativePath does not match $SchemaRelativePath`n$ErrorMessage"
	}
}

function New-HexToken
{
	<#
	.SYNOPSIS
		生成随机十六进制token
	#>
	$Bytes = [byte[]]::new(8)
	$Rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
	$Rng.GetBytes($Bytes)
	$Rng.Dispose()
	return ([BitConverter]::ToString($Bytes) -replace "-", "").ToLowerInvariant()
}

function Test-BlankProperty
{
	<#
	.SYNOPSIS
		判断对象属性缺失或为空白
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[psobject]$InputObject,

		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	$Property = $InputObject.PSObject.Properties[$Name]
	return (($null -eq $Property) -or [string]::IsNullOrWhiteSpace([string]$Property.Value))
}



function Read-SetupConfigFiles
{
	<#
	.SYNOPSIS
		读取并校验配置文件
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ConfigPath,

		[Parameter(Mandatory = $true)]
		[string]$ConfigSchemaPath,

		[Parameter(Mandatory = $true)]
		[string]$ConstantsPath,

		[Parameter(Mandatory = $true)]
		[string]$ConstantsSchemaPath
	)

	Assert-JsonSchemaValid -JsonPath $ConfigPath -SchemaPath $ConfigSchemaPath
	Assert-JsonSchemaValid -JsonPath $ConstantsPath -SchemaPath $ConstantsSchemaPath

	return [pscustomobject]@{
		Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
		Constants = Get-Content -LiteralPath $ConstantsPath -Raw | ConvertFrom-Json
	}
}

function Complete-SetupConfig
{
	<#
	.SYNOPSIS
		补齐配置中的自动生成字段
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[switch]$IncludeSubscriptionPath,

		[switch]$IncludeClashSubscriptionPath
	)

	if ($IncludeSubscriptionPath.IsPresent -and (Test-BlankProperty -InputObject $Config -Name "subscriptionPath"))
	{
		$Config | Add-Member -MemberType NoteProperty -Name "subscriptionPath" -Value (New-HexToken) -Force
	}

	if ($IncludeClashSubscriptionPath.IsPresent -and (Test-BlankProperty -InputObject $Config -Name "clashSubscriptionPath"))
	{
		$Config | Add-Member -MemberType NoteProperty -Name "clashSubscriptionPath" -Value (New-HexToken) -Force
	}

	foreach ($Client in @($Config.clients))
	{
		if (Test-BlankProperty -InputObject $Client -Name "path")
		{
			$Client | Add-Member -MemberType NoteProperty -Name "path" -Value (New-HexToken) -Force
		}
	}
}

function Assert-SetupClientConfigValid
{
	<#
	.SYNOPSIS
		检查客户端配置可用于部署
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[switch]$RequireSubscriptionPath,

		[switch]$RequireClashSubscriptionPath
	)

	if ($RequireSubscriptionPath.IsPresent -and (Test-BlankProperty -InputObject $Config -Name "subscriptionPath"))
	{
		throw "remote/config.json must contain subscriptionPath"
	}
	if ($RequireClashSubscriptionPath.IsPresent -and (Test-BlankProperty -InputObject $Config -Name "clashSubscriptionPath"))
	{
		throw "remote/config.json must contain clashSubscriptionPath"
	}
	if (
		$RequireSubscriptionPath.IsPresent -and
		$RequireClashSubscriptionPath.IsPresent -and
		(-not (Test-BlankProperty -InputObject $Config -Name "subscriptionPath")) -and
		(-not (Test-BlankProperty -InputObject $Config -Name "clashSubscriptionPath")) -and
		([string]$Config.subscriptionPath -eq [string]$Config.clashSubscriptionPath)
	)
	{
		throw "remote/config.json has duplicate subscription paths: subscriptionPath and clashSubscriptionPath"
	}

	$Clients = @($Config.clients)
	if ($Clients.Count -le 0)
	{
		throw "remote/config.json must contain at least one client"
	}

	$MissingClientNames = @($Clients | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.client) })
	if ($MissingClientNames.Count -gt 0)
	{
		throw "remote/config.json has client without name"
	}

	$MissingPaths = @($Clients | Where-Object { Test-BlankProperty -InputObject $_ -Name "path" })
	if ($MissingPaths.Count -gt 0)
	{
		throw "remote/config.json has client without path"
	}

	$DuplicateClients = @($Clients | Group-Object -Property client | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
	if ($DuplicateClients.Count -gt 0)
	{
		throw "remote/config.json has duplicate clients: $($DuplicateClients -join ", ")"
	}

	$DuplicatePaths = @($Clients | Group-Object -Property path | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
	if ($DuplicatePaths.Count -gt 0)
	{
		throw "remote/config.json has duplicate client paths: $($DuplicatePaths -join ", ")"
	}
}

function Save-SetupConfig
{
	<#
	.SYNOPSIS
		写回 config.json
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[Parameter(Mandatory = $true)]
		[string]$ConfigPath
	)

	$Json = $Config | ConvertTo-Json -Depth 32
	Set-Content -LiteralPath $ConfigPath -Value $Json -NoNewline -Encoding utf8NoBOM
}

Export-ModuleMember -Function Read-SetupConfigFiles, Complete-SetupConfig, Assert-SetupClientConfigValid, Save-SetupConfig

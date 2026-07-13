Set-StrictMode -Version Latest

function Export-ClientFiles
{
	<#
	.SYNOPSIS
		导出客户端订阅文件
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[Parameter(Mandatory = $true)]
		[pscustomobject]$Constants,

		[Parameter(Mandatory = $true)]
		[string]$ClientsDir
	)

	$TemplatePath = Join-Path $PSScriptRoot "template.md"
	$TemplateContent = Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8
	$SubscriptionPath = "$($Config.cdnDomain)/$($Config.subscriptionPath)"
	$ProxyClientsUrl = "https://$($Config.cdnDomain)/$($Config.subscriptionPath)$($Constants.proxyClientsSuffix)"

	if (-not (Test-Path -LiteralPath $ClientsDir -PathType Container))
	{
		New-Item -Path $ClientsDir -ItemType Directory -Force | Out-Null
	}

	Get-ChildItem -LiteralPath $ClientsDir -Filter "*.md" -File | Remove-Item -Force

	foreach ($Client in @($Config.clients))
	{
		$ClientName = [string]$Client.client
		$ClientPath = [string]$Client.path
		if ([string]::IsNullOrWhiteSpace($ClientPath))
		{
			throw "client path is empty: $ClientName"
		}

		$ClientFilePath = Join-Path $ClientsDir "$ClientName.md"
		$Content = $TemplateContent.Replace("{subscriptionPath}", $SubscriptionPath)
		$Content = $Content.Replace("{clashSuffix}", [string]$Constants.clashSuffix)
		$Content = $Content.Replace("{proxyClientsSuffix}", [string]$Constants.proxyClientsSuffix)
		$Content = $Content.Replace("{proxyClientsURL}", $ProxyClientsUrl)
		$Content = $Content.Replace("{clientPath}", $ClientPath)
		foreach ($FilenameProperty in $Constants.proxyClientsFilenames.PSObject.Properties)
		{
			$Placeholder = "{proxyClientsFilenames.$($FilenameProperty.Name)}"
			$Content = $Content.Replace($Placeholder, [string]$FilenameProperty.Value)
		}
		if ($Content -match "\{(?:subscriptionPath|clashSuffix|proxyClientsSuffix|proxyClientsURL|clientPath|proxyClientsFilenames\.)")
		{
			throw "client template contains unresolved placeholder: $ClientName"
		}
		Set-Content -LiteralPath $ClientFilePath -Value $Content -Encoding utf8NoBOM
	}
}

Export-ModuleMember -Function Export-ClientFiles

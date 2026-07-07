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
		[string]$ClientsDir
	)

	$TemplatePath = Join-Path $PSScriptRoot "template.md"
	$TemplateContent = Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8

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
		$Url = "https://$($Config.cdnDomain)/$($Config.subscriptionPath)/$ClientPath"
		$ClashUrl = "https://$($Config.cdnDomain)/$($Config.clashSubscriptionPath)/$ClientPath"
		$Content = $TemplateContent -replace [regex]::Escape("{v2raySubscriptionURL}"), $Url
		$Content = $Content -replace [regex]::Escape("{clashSubscriptionURL}"), $ClashUrl
		Set-Content -LiteralPath $ClientFilePath -Value $Content -Encoding utf8NoBOM
	}
}

Export-ModuleMember -Function Export-ClientFiles

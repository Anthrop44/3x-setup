Set-StrictMode -Version Latest

function Export-ClientFiles
{
	<#
	.SYNOPSIS
		导出加密客户端分发文件
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

	$TemplatePath = Join-Path $PSScriptRoot "template.xhtml"
	$TemplateContent = Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8
	$SubscriptionPath = "$($Config.cdnDomain)/$($Config.subscriptionPath)"
	$ProxyClientsUrl = "https://$($Config.cdnDomain)/$($Config.subscriptionPath)$($Constants.proxyClientsSuffix)"

	if (-not (Test-Path -LiteralPath $ClientsDir -PathType Container))
	{
		New-Item -Path $ClientsDir -ItemType Directory -Force | Out-Null
	}

	Get-ChildItem -LiteralPath $ClientsDir -File | Where-Object { $_.Extension -in @(".md", ".xhtml") } | Remove-Item -Force

	foreach ($Client in @($Config.clients))
	{
		$ClientName = [string]$Client.client
		$ClientPath = [string]$Client.path
		if ([string]::IsNullOrWhiteSpace($ClientPath))
		{
			throw "client path is empty: $ClientName"
		}

		$ClientFilePath = Join-Path $ClientsDir "$ClientName.xhtml"
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

		$ReaderSettings = [System.Xml.XmlReaderSettings]::new()
		$ReaderSettings.DtdProcessing = [System.Xml.DtdProcessing]::Parse
		$ReaderSettings.XmlResolver = $null
		$StringReader = [System.IO.StringReader]::new($Content)
		$Reader = [System.Xml.XmlReader]::Create($StringReader, $ReaderSettings)
		$Document = [System.Xml.XmlDocument]::new()
		$Document.PreserveWhitespace = $true
		try
		{
			$Document.Load($Reader)
		} finally
		{
			$Reader.Dispose()
			$StringReader.Dispose()
		}

		$EncryptedElement = [System.Xml.XmlElement]$Document.SelectSingleNode('//*[@id="encrypted"]')
		if ($null -eq $EncryptedElement)
		{
			throw "client template element #encrypted was not found: $ClientName"
		}
		$FourDigitsElement = [System.Xml.XmlElement]$Document.SelectSingleNode('//*[@id="four_digits"]')
		if ($null -eq $FourDigitsElement)
		{
			throw "client template element #four_digits was not found: $ClientName"
		}

		$FourDigits = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(1000, 10000)
		[byte[]]$Salt = [byte[]]::new(16)
		[byte[]]$Iv = [byte[]]::new(12)
		[System.Security.Cryptography.RandomNumberGenerator]::Fill($Salt)
		[System.Security.Cryptography.RandomNumberGenerator]::Fill($Iv)
		$Plaintext = [System.Text.Encoding]::UTF8.GetBytes($EncryptedElement.InnerXml)
		$Kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new([string]$FourDigits, $Salt, 100000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
		try
		{
			$Key = $Kdf.GetBytes(32)
		} finally
		{
			$Kdf.Dispose()
		}

		[byte[]]$Ciphertext = [byte[]]::new($Plaintext.Length)
		[byte[]]$Tag = [byte[]]::new(16)
		$Aes = [System.Security.Cryptography.AesGcm]::new($Key)
		try
		{
			$Aes.Encrypt($Iv, $Plaintext, $Ciphertext, $Tag)
		} finally
		{
			$Aes.Dispose()
		}

		[byte[]]$Payload = $Ciphertext + $Tag
		while ($EncryptedElement.HasChildNodes)
		{
			[void]$EncryptedElement.RemoveChild($EncryptedElement.FirstChild)
		}
		$EncryptedElement.IsEmpty = $false
		$EncryptedElement.SetAttribute("data-salt", [Convert]::ToBase64String($Salt))
		$EncryptedElement.SetAttribute("data-iv", [Convert]::ToBase64String($Iv))
		$EncryptedElement.SetAttribute("data-ciphertext", [Convert]::ToBase64String($Payload))
		$FourDigitsElement.InnerText = [string]$FourDigits

		$WriterSettings = [System.Xml.XmlWriterSettings]::new()
		$WriterSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
		$WriterSettings.Indent = $false
		$WriterSettings.NewLineHandling = [System.Xml.NewLineHandling]::None
		$Writer = [System.Xml.XmlWriter]::Create($ClientFilePath, $WriterSettings)
		try
		{
			$Document.Save($Writer)
		} finally
		{
			$Writer.Dispose()
		}
	}
}

Export-ModuleMember -Function Export-ClientFiles

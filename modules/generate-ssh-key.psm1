Set-StrictMode -Version Latest

function Assert-LastExitCode
{
	<#
	.SYNOPSIS
		检查上一条外部命令退出码
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$FailureMessage
	)

	if ($LASTEXITCODE -ne 0)
	{
		throw $FailureMessage
	}
}

function Get-SshKeyFingerprint
{
	<#
	.SYNOPSIS
		使用OpenSSH计算SSH密钥fingerprint
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,

		[Parameter(Mandatory = $true)]
		[string]$FailureMessage
	)

	$FingerprintLine = ssh-keygen -l -f $Path -E sha256
	Assert-LastExitCode -FailureMessage $FailureMessage

	$FingerprintLine = ($FingerprintLine -join "`n").Trim()
	$Match = [regex]::Match($FingerprintLine, '^\d+\s+(SHA256:\S+)\s+.+\s+\((ED25519)\)$')
	if (-not $Match.Success)
	{
		throw $FailureMessage
	}

	return $Match.Groups[1].Value
}

function Export-Ed25519PublicKey
{
	<#
	.SYNOPSIS
		从Ed25519私钥导出固定comment的公钥文本
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,

		[Parameter(Mandatory = $true)]
		[string]$Comment
	)

	$PublicKeyBody = ssh-keygen -y -f $Path
	Assert-LastExitCode -FailureMessage "failed to export public key from $Path"

	$PublicKeyBody = ($PublicKeyBody -join "`n").Trim()
	$Match = [regex]::Match($PublicKeyBody, '^(ssh-ed25519)\s+(\S+)(?:\s+.*)?$')
	if (-not $Match.Success)
	{
		throw "private key is not a valid Ed25519 key: $Path"
	}

	return "$($Match.Groups[1].Value) $($Match.Groups[2].Value) $Comment"
}

function Test-Ed25519PublicKeyMatchesPrivateKey
{
	<#
	.SYNOPSIS
		检查已有公钥是否对应指定Ed25519私钥
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$PublicKeyPath,

		[Parameter(Mandatory = $true)]
		[string]$PrivateKeyPath
	)

	$PublicKeyFingerprint = Get-SshKeyFingerprint -Path $PublicKeyPath -FailureMessage "existing public key is not a valid Ed25519 public key: $PublicKeyPath"
	$PrivateKeyFingerprint = Get-SshKeyFingerprint -Path $PrivateKeyPath -FailureMessage "private key is not a valid Ed25519 key: $PrivateKeyPath"

	return $PublicKeyFingerprint -eq $PrivateKeyFingerprint
}

function Initialize-DeploymentSshKey
{
	<#
	.SYNOPSIS
		生成或导出部署所需的SSH公钥
	.DESCRIPTION
		如果 remote/id_ed25519.pub 已存在且对应 $env:USERPROFILE/.ssh/id_ed25519 ，则打印成功信息后跳过；如果不对应则报错，避免覆盖已有部署公钥。如果本地私钥不存在，则生成一对新的Ed25519密钥；如果该私钥已存在，则从它导出公钥。最终公钥写入 remote/id_ed25519.pub
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[string]$ProjectDir
	)

	$RemoteDir = Join-Path $ProjectDir "remote"
	$RemotePublicKeyPath = Join-Path $RemoteDir "id_ed25519.pub"
	$PublicKeyComment = "https://github.com/Anthrop44/3x-setup"

	if ([string]::IsNullOrWhiteSpace($env:USERPROFILE))
	{
		throw "USERPROFILE environment variable is empty; cannot locate the local SSH key directory"
	}

	$SshDir = Join-Path $env:USERPROFILE ".ssh"
	$PrivateKeyPath = Join-Path $SshDir "id_ed25519"
	$AdjacentPublicKeyPath = "$PrivateKeyPath.pub"

	if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue))
	{
		throw "ssh-keygen not found; install or enable Windows OpenSSH first"
	}

	if (-not (Test-Path -LiteralPath $RemoteDir -PathType Container))
	{
		throw "missing remote directory: $RemoteDir"
	}

	if (Test-Path -LiteralPath $PrivateKeyPath -PathType Container)
	{
		throw "private key path is a directory: $PrivateKeyPath"
	}

	$PrivateKeyExists = Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf
	if (Test-Path -LiteralPath $RemotePublicKeyPath)
	{
		if (-not $PrivateKeyExists)
		{
			throw "remote public key already exists but local private key is missing, refusing to overwrite: $PrivateKeyPath"
		}

		if (Test-Ed25519PublicKeyMatchesPrivateKey -PublicKeyPath $RemotePublicKeyPath -PrivateKeyPath $PrivateKeyPath)
		{
			Write-Host "Existing public key matches local private key: $RemotePublicKeyPath"
			$global:LASTEXITCODE = 0
			return
		}

		throw "remote public key already exists and does not match local private key, refusing to overwrite: $RemotePublicKeyPath"
	}

	if (-not $PrivateKeyExists)
	{
		if (Test-Path -LiteralPath $AdjacentPublicKeyPath)
		{
			throw "found $AdjacentPublicKeyPath without $PrivateKeyPath; move or delete it before generating a new key"
		}

		New-Item -ItemType Directory -Path $SshDir -Force | Out-Null

		Write-Host "Generating Ed25519 private key: $PrivateKeyPath"
		ssh-keygen -q -t ed25519 -f $PrivateKeyPath -C $PublicKeyComment -N ""
		Assert-LastExitCode -FailureMessage "failed to generate Ed25519 SSH key pair"
	} else
	{
		Write-Host "Using existing Ed25519 private key: $PrivateKeyPath"
	}

	try
	{
		$PublicKey = Export-Ed25519PublicKey -Path $PrivateKeyPath -Comment $PublicKeyComment
		Set-Content -LiteralPath $RemotePublicKeyPath -Value "$PublicKey`n" -NoNewline -Encoding ascii
		Write-Host "Wrote public key: $RemotePublicKeyPath"
	} finally
	{
		if (-not $PrivateKeyExists)
		{
			Remove-Item -LiteralPath $AdjacentPublicKeyPath -Force -ErrorAction SilentlyContinue
		}
	}

	$global:LASTEXITCODE = 0
}

Export-ModuleMember -Function Initialize-DeploymentSshKey

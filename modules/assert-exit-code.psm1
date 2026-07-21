Set-StrictMode -Version Latest

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

Export-ModuleMember -Function Assert-ExitCode

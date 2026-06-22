<#
.SYNOPSIS
	生成SSH密钥到脚本同目录
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$KeyPath = Join-Path $PSScriptRoot "id_ed25519"
$PubKeyPath = "$KeyPath.pub"

if ((Test-Path -LiteralPath $KeyPath) -or (Test-Path -LiteralPath $PubKeyPath))
{
	throw "已存在 $KeyPath 或 $PubKeyPath ，请先手动删除后再运行"
}

ssh-keygen -t ed25519 -f $KeyPath -N "" -C ""

# 去掉公钥末尾多余空格和换行，只保留一个换行
$PubContent = (Get-Content -LiteralPath $PubKeyPath -Raw).Trim() + "`n"
Set-Content -LiteralPath $PubKeyPath -Value $PubContent -NoNewline -Encoding utf8NoBOM

Write-Host "已生成：$KeyPath 和 $PubKeyPath"

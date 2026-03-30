param(
	[Parameter(Mandatory = $true)]
	[string]$Version,
	[Parameter(Mandatory = $true)]
	[string]$LuauArchive,
	[Parameter(Mandatory = $true)]
	[string]$RobloxArchive,
	[string]$OutputDirectory = "",
	[string]$GitRef = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-GitRefValue() {
	if (-not [string]::IsNullOrWhiteSpace($GitRef)) {
		return $GitRef
	}

	if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
		return $env:GITHUB_SHA
	}

	return "unknown"
}

function Normalize-Path([string]$path) {
	return ($path -replace "\\", "/")
}

function New-AssetRecord([string]$packageName, [string]$assetPath) {
	$file = Get-Item -Path $assetPath
	return [ordered]@{
		package = $packageName
		file = $file.Name
		sizeBytes = $file.Length
		sha256 = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
	}
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
	$OutputDirectory = Split-Path -Parent $LuauArchive
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$gitRefValue = Get-GitRefValue
$generatedAt = [DateTime]::UtcNow.ToString("o")
$luauRecord = New-AssetRecord -packageName "machina-luau" -assetPath $LuauArchive
$robloxRecord = New-AssetRecord -packageName "machina-roblox" -assetPath $RobloxArchive

$metadata = [ordered]@{
	format = "machina-release-metadata/v1"
	package = "machina"
	version = $Version
	gitRef = $gitRefValue
	generatedAtUtc = $generatedAt
	artifacts = [ordered]@{
		"machina-luau" = $luauRecord
		"machina-roblox" = $robloxRecord
	}
}

$metadataPath = Join-Path $OutputDirectory "machina-release-metadata-$Version.json"
$checksumsPath = Join-Path $OutputDirectory "machina-release-checksums-$Version.txt"

$metadata | ConvertTo-Json -Depth 8 | Set-Content -Path $metadataPath
@(
	"$($luauRecord.sha256)  $($luauRecord.file)"
	"$($robloxRecord.sha256)  $($robloxRecord.file)"
) | Set-Content -Path $checksumsPath

param(
	[ValidateSet("all", "machina-luau", "machina-roblox")]
	[string]$Target = "all",
	[string]$OutputRoot = "",
	[string]$Version = "",
	[string]$GitRef = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repoRoot "src"

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
	$OutputRoot = Join-Path $repoRoot "dist"
}

$luauRoot = Join-Path $OutputRoot "machina-luau"
$robloxRoot = Join-Path $OutputRoot "machina-roblox"

function Normalize-Path([string]$path) {
	return ($path -replace "\\", "/")
}

function Ensure-ParentDirectory([string]$filePath) {
	$parent = Split-Path -Parent $filePath
	if (-not [string]::IsNullOrWhiteSpace($parent)) {
		New-Item -ItemType Directory -Force -Path $parent | Out-Null
	}
}

function Get-GeneratedTimestamp() {
	return [DateTime]::UtcNow.ToString("o")
}

function Get-PackageVersion() {
	if (-not [string]::IsNullOrWhiteSpace($Version)) {
		return $Version
	}

	if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) {
		return $env:GITHUB_REF_NAME
	}

	return "dev-local"
}

function Get-PackageGitRef() {
	if (-not [string]::IsNullOrWhiteSpace($GitRef)) {
		return $GitRef
	}

	if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
		return $env:GITHUB_SHA
	}

	try {
		$resolved = (& git rev-parse HEAD 2>$null)
		if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolved)) {
			return $resolved.Trim()
		}
	} catch {
	}

	return "unknown"
}

function Get-RelativeSourcePath([string]$fullPath) {
	$relativeUri = [System.Uri]::new($sourceRoot + [System.IO.Path]::DirectorySeparatorChar).MakeRelativeUri([System.Uri]::new($fullPath))
	return Normalize-Path([System.Uri]::UnescapeDataString($relativeUri.ToString()))
}

function Assert-PublicModuleId([string]$moduleId) {
	if ($moduleId -notmatch '^@src/[A-Za-z0-9_/]+$') {
		throw "Unsupported public module id: $moduleId"
	}
}

function Get-CanonicalModuleId([string]$fullPath) {
	$relativePath = Get-RelativeSourcePath $fullPath
	$modulePath = Normalize-Path ($relativePath -replace '\.luau$', '')
	$moduleId = "@src/$modulePath"
	Assert-PublicModuleId $moduleId
	return $moduleId
}

function Get-PackageRelativePath([string]$moduleId) {
	Assert-PublicModuleId $moduleId
	return "$($moduleId.Substring(1)).luau"
}

function Get-SharedSourceFiles() {
	return Get-ChildItem -Path $sourceRoot -Recurse -File -Filter *.luau |
		Where-Object {
			$relative = Get-RelativeSourcePath $_.FullName
			$relative -eq "DefaultConfiguration.luau" -or $relative -eq "Contracts.luau" -or $relative.StartsWith("platforms/")
		}
}

function Get-ModuleEntries() {
	$entries = foreach ($file in Get-SharedSourceFiles) {
		[pscustomobject]@{
			FullPath = $file.FullName
			ModuleId = Get-CanonicalModuleId $file.FullName
			RelativePath = Get-RelativeSourcePath $file.FullName
		}
	}

	return $entries | Sort-Object ModuleId
}

function Validate-SharedSource() {
	$pattern = 'script\.Parent|game:GetService|Instance\.new|ReplicatedStorage|RemoteFunction|DataStoreService|@host/|@config/'
	$violations = Get-SharedSourceFiles | Select-String -Pattern $pattern
	if ($violations) {
		$lines = $violations | ForEach-Object { "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() }
		throw "Shared source still contains forbidden references:`n$($lines -join [Environment]::NewLine)"
	}
}

function New-EntryPoints() {
	return [ordered]@{
		config = "@src/DefaultConfiguration"
		machine = "@src/platforms/x86/PcSystem"
		platformContracts = "@src/Contracts"
	}
}

function New-PackageManifest([string]$format, [string]$packageName, [string]$consumer, [string]$versionValue, [string]$gitRefValue, [string]$generatedAt, [System.Collections.Specialized.OrderedDictionary]$moduleMap) {
	return [ordered]@{
		format = $format
		package = $packageName
		sourcePackage = "machina"
		version = $versionValue
		gitRef = $gitRefValue
		generatedAtUtc = $generatedAt
		consumer = $consumer
		entrypoints = New-EntryPoints
		modules = $moduleMap
	}
}

function Get-RobloxModuleExpression([string]$currentModuleId, [string]$targetModuleId) {
	Assert-PublicModuleId $currentModuleId
	Assert-PublicModuleId $targetModuleId

	$currentSegments = $currentModuleId.Split("/")
	$targetSegments = $targetModuleId.Split("/")
	$maxCommon = [Math]::Min($currentSegments.Length, $targetSegments.Length)
	$commonCount = 0

	while ($commonCount -lt $maxCommon -and $currentSegments[$commonCount] -ceq $targetSegments[$commonCount]) {
		$commonCount += 1
	}

	$builder = [System.Text.StringBuilder]::new("script")
	for ($index = 0; $index -lt ($currentSegments.Length - $commonCount); $index += 1) {
		[void]$builder.Append(".Parent")
	}

	for ($index = $commonCount; $index -lt $targetSegments.Length; $index += 1) {
		[void]$builder.Append(".")
		[void]$builder.Append($targetSegments[$index])
	}

	return $builder.ToString()
}

function Convert-ToRobloxSource([string]$content, [string]$currentModuleId, [hashtable]$knownModuleIds) {
	$pattern = 'require\("([^"]+)"\)'
	return [regex]::Replace($content, $pattern, {
		param($match)

		$targetModuleId = $match.Groups[1].Value
		Assert-PublicModuleId $targetModuleId

		if (-not $knownModuleIds.ContainsKey($targetModuleId)) {
			throw "Unknown module dependency '$targetModuleId' referenced from $currentModuleId"
		}

		$robloxExpression = Get-RobloxModuleExpression -currentModuleId $currentModuleId -targetModuleId $targetModuleId
		return "require($robloxExpression)"
	})
}

function Get-RobloxRootExpression([string]$targetModuleId) {
	Assert-PublicModuleId $targetModuleId
	$segments = $targetModuleId.Split("/")
	$segments[0] = $segments[0].TrimStart("@")
	return "root." + ($segments -join ".")
}

function New-RobloxInitSource([string]$versionValue, [string[]]$moduleIds) {
	$lines = @(
		"-- Auto-generated Machina package",
		"-- Root is script (works for both games and most tools)",
		"",
		"local root = script",
		"",
		"-- Auto-generated module registry",
		"local modules = {"
	)

	foreach ($moduleId in ($moduleIds | Sort-Object)) {
		$instanceExpression = Get-RobloxRootExpression $moduleId
		$lines += "	[`"$moduleId`"] = $instanceExpression,"
	}

	$lines += @(
		"}",
		"",
		"local Package = {",
		"	Name = `"machina-roblox`",",
		"	Version = `"$versionValue`",",
		"}",
		"",
		"-- Deep copy a table recursively",
		"local function deepCopy(original)",
		"	local copy = {}",
		"	for key, value in pairs(original) do",
		"		if type(value) == `"table`" then",
		"			copy[key] = deepCopy(value)",
		"		else",
		"			copy[key] = value",
		"		end",
		"	end",
		"	return copy",
		"end",
		"",
		"-- Merge overrides into base config",
		"local function mergeConfig(base, overrides)",
		"	if not overrides then",
		"		return deepCopy(base)",
		"	end",
		"	local config = deepCopy(base)",
		"	for key, value in pairs(overrides) do",
		"		if type(value) == `"table`" then",
		"			if config[key] == nil then",
		"				config[key] = {}",
		"			end",
		"			for k, v in pairs(value) do",
		"				config[key][k] = v",
		"			end",
		"		else",
		"			config[key] = value",
		"		end",
		"	end",
		"	return config",
		"end",
		"",
		"-- Get the default configuration (as function)",
		"function Package.default()",
		"	local DefaultConfiguration = Package.require(`"@src/DefaultConfiguration`")",
		"	return deepCopy(DefaultConfiguration)",
		"end",
		"",
		"-- Build config with overrides",
		"function Package.build(overrides)",
		"	local DefaultConfiguration = Package.require(`"@src/DefaultConfiguration`")",
		"	return mergeConfig(DefaultConfiguration, overrides)",
		"end",
		"",
		"-- Entry points for common dependencies",
		"Package.machine = modules[`"@src/platforms/x86/PcSystem`"]",
		"Package.Contracts = modules[`"@src/Contracts`"]",
		"",
		"-- Resolve a module ID to a Roblox script instance",
		"function Package.resolve(moduleId)",
		"	local moduleScript = modules[moduleId]",
		"	assert(moduleScript, `"machina: unknown module `" .. tostring(moduleId))",
		"	return moduleScript",
		"end",
		"",
		"-- Require a module by its ID",
		"function Package.require(moduleId)",
		"	return require(Package.resolve(moduleId))",
		"end",
		"",
		"-- Get the PcSystem machine",
		"function Package.getMachine()",
		"	return Package.require(`"@src/platforms/x86/PcSystem`")",
		"end",
		"",
		"-- Get platform contracts",
		"function Package.getContracts()",
		"	return Package.require(`"@src/Contracts`")",
		"end",
		"",
		"return Package"
	)

	return ($lines -join "`n") + "`n"
}

function Validate-PackageManifest([System.Collections.IDictionary]$manifest, [string]$targetRoot, [string[]]$expectedModuleIds) {
	$actualModuleIds = @($manifest.modules.Keys | Sort-Object)
	$expectedSorted = @($expectedModuleIds | Sort-Object)

	if ($actualModuleIds.Count -ne $expectedSorted.Count) {
		throw "Manifest module count mismatch for $($manifest.package): expected $($expectedSorted.Count), got $($actualModuleIds.Count)"
	}

	for ($index = 0; $index -lt $expectedSorted.Count; $index += 1) {
		if ($expectedSorted[$index] -ne $actualModuleIds[$index]) {
			throw "Manifest module id mismatch for $($manifest.package): expected $($expectedSorted[$index]), got $($actualModuleIds[$index])"
		}
	}

	$duplicateDestinations = $manifest.modules.Values | Group-Object | Where-Object { $_.Count -gt 1 }
	if ($duplicateDestinations) {
		$paths = $duplicateDestinations | ForEach-Object { $_.Name }
		throw "Manifest for $($manifest.package) contains duplicate output paths: $($paths -join ', ')"
	}

	foreach ($moduleId in $manifest.modules.Keys) {
		Assert-PublicModuleId $moduleId
		$destinationPath = Join-Path $targetRoot $manifest.modules[$moduleId]
		if (-not (Test-Path $destinationPath)) {
			throw "Manifest for $($manifest.package) points at a missing file: $destinationPath"
		}
	}
}

function Validate-RobloxOutput([string]$targetRoot) {
	# Exclude init.luau - it uses Package.require which is designed for runtime resolution
	$violations = Get-ChildItem -Path $targetRoot -Recurse -File -Filter *.luau |
		Where-Object { $_.Name -ne "init.luau" } |
		Select-String -Pattern 'require\("src/|require\("@src/|@config/'
	if ($violations) {
		$lines = $violations | ForEach-Object { "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() }
		throw "Generated machina-roblox package still contains unresolved string-based imports:`n$($lines -join [Environment]::NewLine)"
	}
}

function Export-LuauPackage([string]$targetRoot, $entries, [string]$versionValue, [string]$gitRefValue, [string]$generatedAt) {
	if (Test-Path $targetRoot) {
		Remove-Item -Recurse -Force $targetRoot
	}

	$moduleMap = [ordered]@{}
	foreach ($entry in $entries) {
		$destinationRelativePath = Get-PackageRelativePath $entry.ModuleId
		$destinationPath = Join-Path $targetRoot $destinationRelativePath
		Ensure-ParentDirectory $destinationPath
		Copy-Item -Path $entry.FullPath -Destination $destinationPath
		$moduleMap[$entry.ModuleId] = $destinationRelativePath
	}

	$manifest = New-PackageManifest -format "machina-luau-package/v1" -packageName "machina-luau" -consumer "generic-luau-runtime" -versionValue $versionValue -gitRefValue $gitRefValue -generatedAt $generatedAt -moduleMap $moduleMap
	$manifestPath = Join-Path $targetRoot "package-manifest.json"
	$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath
	Validate-PackageManifest -manifest $manifest -targetRoot $targetRoot -expectedModuleIds ($entries.ModuleId)
}

function Export-RobloxPackage([string]$targetRoot, $entries, [string]$versionValue, [string]$gitRefValue, [string]$generatedAt) {
	if (Test-Path $targetRoot) {
		Remove-Item -Recurse -Force $targetRoot
	}

	$knownModuleIds = @{}
	foreach ($entry in $entries) {
		$knownModuleIds[$entry.ModuleId] = $true
	}

	$moduleMap = [ordered]@{}
	foreach ($entry in $entries) {
		$destinationRelativePath = Get-PackageRelativePath $entry.ModuleId
		$destinationPath = Join-Path $targetRoot $destinationRelativePath
		Ensure-ParentDirectory $destinationPath

		$content = Get-Content -Raw -Path $entry.FullPath
		$rewrittenContent = Convert-ToRobloxSource -content $content -currentModuleId $entry.ModuleId -knownModuleIds $knownModuleIds
		Set-Content -Path $destinationPath -Value $rewrittenContent
		$moduleMap[$entry.ModuleId] = $destinationRelativePath
	}

	$initPath = Join-Path $targetRoot "init.luau"
	Set-Content -Path $initPath -Value (New-RobloxInitSource -versionValue $versionValue -moduleIds ($entries.ModuleId))

	$manifest = New-PackageManifest -format "machina-roblox-package/v1" -packageName "machina-roblox" -consumer "roblox-host" -versionValue $versionValue -gitRefValue $gitRefValue -generatedAt $generatedAt -moduleMap $moduleMap
	$manifest.mountLayout = [ordered]@{
		rootName = "machina"
		rootType = "Folder"
		vendorPath = "vendor/machina"
		initModule = "init.luau"
		sourceRoot = "src"
	}

	$manifestPath = Join-Path $targetRoot "package-manifest.json"
	$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $manifestPath
	Validate-PackageManifest -manifest $manifest -targetRoot $targetRoot -expectedModuleIds ($entries.ModuleId)
	Validate-RobloxOutput -targetRoot $targetRoot
}

Validate-SharedSource

$legacyRoots = @(
	(Join-Path $OutputRoot "core"),
	(Join-Path $OutputRoot "web"),
	(Join-Path $OutputRoot "roblox")
)

foreach ($legacyRoot in $legacyRoots) {
	if (Test-Path $legacyRoot) {
		Remove-Item -Recurse -Force $legacyRoot
	}
}

$entries = Get-ModuleEntries
$packageVersion = Get-PackageVersion
$packageGitRef = Get-PackageGitRef
$generatedAt = Get-GeneratedTimestamp

if ($Target -in @("all", "machina-luau")) {
	Export-LuauPackage -targetRoot $luauRoot -entries $entries -versionValue $packageVersion -gitRefValue $packageGitRef -generatedAt $generatedAt
}

if ($Target -in @("all", "machina-roblox")) {
	Export-RobloxPackage -targetRoot $robloxRoot -entries $entries -versionValue $packageVersion -gitRefValue $packageGitRef -generatedAt $generatedAt
}

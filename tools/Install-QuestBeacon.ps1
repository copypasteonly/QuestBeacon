[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$GamePath = 'C:\Octowow'
)

$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$resolvedGamePath = (Resolve-Path -LiteralPath $GamePath).Path
$wowExecutable = Join-Path $resolvedGamePath 'WoW.exe'
$addonsRoot = Join-Path $resolvedGamePath 'Interface\AddOns'
$tocPath = Join-Path $sourceRoot 'QuestBeacon.toc'
$databasePath = Join-Path $sourceRoot 'db\questbeacon.db'
$destinationRoot = Join-Path $addonsRoot 'QuestBeacon'

foreach ($requiredPath in @($wowExecutable, $addonsRoot, $tocPath, $databasePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required path does not exist: $requiredPath"
    }
}

$modulePaths = @(
    Get-Content -LiteralPath $tocPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('##') -and $_.EndsWith('.lua') }
)
if ($modulePaths.Count -eq 0) {
    throw 'QuestBeacon.toc does not list any Lua modules.'
}

$runtimeAssets = @(
    'img\arrow.tga',
    'img\cluster_mob.tga',
    'img\cluster_item.tga',
    'img\cluster_misc.tga',
    'img\available.tga',
    'img\complete.tga'
)
$manifest = @('QuestBeacon.toc') + $modulePaths + $runtimeAssets + @('db\questbeacon.db')
foreach ($relativePath in $manifest) {
    if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Unsafe manifest path: $relativePath"
    }
    $sourcePath = Join-Path $sourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Manifest source file does not exist: $sourcePath"
    }
}

if ($PSCmdlet.ShouldProcess($destinationRoot, 'Create addon directory')) {
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
}

foreach ($relativePath in $manifest) {
    $sourcePath = Join-Path $sourceRoot $relativePath
    $destinationPath = Join-Path $destinationRoot $relativePath
    $destinationDirectory = Split-Path -Parent $destinationPath
    if ($PSCmdlet.ShouldProcess($destinationPath, 'Copy QuestBeacon file')) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
        if ($sourceHash -ne $destinationHash) {
            throw "Hash verification failed: $relativePath"
        }
        Write-Host "Verified $relativePath"
    }
}

Write-Host "QuestBeacon deployment complete: $destinationRoot"

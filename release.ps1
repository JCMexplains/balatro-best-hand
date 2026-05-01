# release.ps1 — package the mod for end-user distribution.
#
# Reads version from BestHand.json, stages the runtime files in dist/,
# and zips them as dist/balatro-best-hand-vX.Y.Z.zip. The zip's top-level
# folder is `balatro-best-hand/`, so users extract straight into
# %APPDATA%/Balatro/Mods/.
#
# Excludes everything dev-only: offline tools (batch_verify, trace_one,
# synth_fuzz, harness, bench_*), dev docs (CLAUDE.md, STYLE.md), the
# captures dir, balatro_src/, .git/, and this script itself.

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$modDir  = 'balatro-best-hand'
$json    = Get-Content -Raw -Path (Join-Path $root 'BestHand.json') | ConvertFrom-Json
$version = $json.version
$dist    = Join-Path $root 'dist'
$staging = Join-Path $dist $modDir
$zipPath = Join-Path $dist "$modDir-v$version.zip"

# Files end users need. Anything not on this list does not ship.
$include = @(
    'BestHand.lua',
    'BestHand.json',
    'README.md',
    'LICENSE'
)

if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Path $staging -Force | Out-Null

foreach ($file in $include) {
    $src = Join-Path $root $file
    if (-not (Test-Path $src)) {
        throw "Missing required file: $file"
    }
    Copy-Item -Path $src -Destination $staging
}

if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path $staging -DestinationPath $zipPath
Remove-Item -Recurse -Force $staging

Write-Output "Built $zipPath"

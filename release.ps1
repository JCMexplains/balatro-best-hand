# release.ps1 — package the mod for end-user distribution.
#
# Reads version from BestHand.json and produces two zips in dist/:
#
#   1. balatro-best-hand-v<version>.zip
#      Steamodded drop-in. Top-level folder is `balatro-best-hand/`,
#      so users extract straight into %APPDATA%/Balatro/Mods/.
#      Suitable for GitHub Releases / manual install.
#
#   2. balatro-best-hand-thunderstore-v<version>.zip
#      Thunderstore package format. All files at the zip root,
#      including manifest.json, icon.png (256x256), and CHANGELOG.md,
#      per https://wiki.thunderstore.io/mods/creating-a-package.
#
# Both exclude dev-only files (offline tools, CLAUDE.md, STYLE.md,
# captures dir, balatro_src/, .git/, this script).

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$json    = Get-Content -Raw -Path (Join-Path $root 'BestHand.json') | ConvertFrom-Json
$version = $json.version
$dist    = Join-Path $root 'dist'

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist -Force | Out-Null }

# ---------- Steamodded drop-in zip ----------
$dropInDir   = 'balatro-best-hand'
$dropInStage = Join-Path $dist $dropInDir
$dropInZip   = Join-Path $dist "$dropInDir-v$version.zip"

$dropInInclude = @(
    'BestHand.lua',
    'BestHand.json',
    'README.md',
    'LICENSE'
)

if (Test-Path $dropInStage) { Remove-Item -Recurse -Force $dropInStage }
New-Item -ItemType Directory -Path $dropInStage -Force | Out-Null
foreach ($file in $dropInInclude) {
    $src = Join-Path $root $file
    if (-not (Test-Path $src)) { throw "Missing required file: $file" }
    Copy-Item -Path $src -Destination $dropInStage
}
if (Test-Path $dropInZip) { Remove-Item -Force $dropInZip }
Compress-Archive -Path $dropInStage -DestinationPath $dropInZip
Remove-Item -Recurse -Force $dropInStage
Write-Output "Built $dropInZip"

# ---------- Thunderstore zip ----------
# Thunderstore validates the manifest's version_number against the package
# version on upload, and rejects icons that aren't exactly 256x256.
# Catch both locally before we waste an upload.
$manifestPath = Join-Path $root 'manifest.json'
if (-not (Test-Path $manifestPath)) { throw "Missing manifest.json at repo root" }
$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
if ($manifest.version_number -ne $version) {
    throw "Version mismatch: BestHand.json=$version but manifest.json=$($manifest.version_number). Bump both together."
}

Add-Type -AssemblyName System.Drawing
$iconPath = Join-Path $root 'icon.png'
if (-not (Test-Path $iconPath)) { throw "Missing icon.png at repo root (Thunderstore requires 256x256 PNG)" }
$img = [System.Drawing.Image]::FromFile($iconPath)
try {
    if ($img.Width -ne 256 -or $img.Height -ne 256) {
        throw "icon.png must be exactly 256x256, got $($img.Width)x$($img.Height)"
    }
} finally { $img.Dispose() }

$tsStage = Join-Path $dist 'thunderstore-staging'
$tsZip   = Join-Path $dist "balatro-best-hand-thunderstore-v$version.zip"

$tsInclude = @(
    'BestHand.lua',
    'BestHand.json',
    'README.md',
    'LICENSE',
    'CHANGELOG.md',
    'manifest.json',
    'icon.png'
)

if (Test-Path $tsStage) { Remove-Item -Recurse -Force $tsStage }
New-Item -ItemType Directory -Path $tsStage -Force | Out-Null
foreach ($file in $tsInclude) {
    $src = Join-Path $root $file
    if (-not (Test-Path $src)) { throw "Missing required file: $file" }
    Copy-Item -Path $src -Destination $tsStage
}
if (Test-Path $tsZip) { Remove-Item -Force $tsZip }
# Files at zip root (not nested under the staging folder).
Compress-Archive -Path (Join-Path $tsStage '*') -DestinationPath $tsZip
Remove-Item -Recurse -Force $tsStage
Write-Output "Built $tsZip"

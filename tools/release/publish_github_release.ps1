[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$BuildNumber,
    [string]$Notes = 'AvtarPOS maintenance update.',
    [switch]$SkipApk,
    [string]$FlutterPath
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$repo = 'ISanjuAi2/avtar-cooks-releases'
$buildScript = Join-Path $PSScriptRoot 'build_local.ps1'

# gh must already be logged in with permission to create releases. GH_TOKEN may
# be set in the publishing computer, but it is never stored in source or app.
& gh auth status
if ($LASTEXITCODE -ne 0) { throw 'Run gh auth login first, then run this script again.' }

& $buildScript -Version $Version -BuildNumber $BuildNumber -SkipApk:$SkipApk -FlutterPath $FlutterPath
if ($LASTEXITCODE -ne 0) { throw 'Release builds failed.' }

$output = Join-Path $root "dist\releases\$Version"
$windows = Join-Path $output "AvtarPOS-Client-Setup-$Version.exe"
$android = Join-Path $output "AvtarCook-$Version.apk"
foreach ($asset in @($windows)) {
    if (!(Test-Path -LiteralPath $asset)) { throw "Required release asset missing: $asset" }
}
$platforms = [ordered]@{
    windows = [ordered]@{
        url = "https://github.com/$repo/releases/download/v$Version/AvtarPOS-Client-Setup-$Version.exe"
        sha256 = (Get-FileHash -LiteralPath $windows -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
if (!$SkipApk -and !(Test-Path -LiteralPath $android)) { throw "Required release asset missing: $android" }
if (!$SkipApk) {
    $platforms.android = [ordered]@{
        url = "https://github.com/$repo/releases/download/v$Version/AvtarCook-$Version.apk"
        sha256 = (Get-FileHash -LiteralPath $android -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$manifest = [ordered]@{
    schema = 1
    version = $Version
    notes = $Notes
    published_at = (Get-Date).ToUniversalTime().ToString('o')
    platforms = $platforms
}
$manifestPath = Join-Path $output 'latest.json'
$manifestJson = $manifest | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText(
    $manifestPath,
    $manifestJson,
    [System.Text.UTF8Encoding]::new($false)
)

& gh release create "v$Version" $windows $manifestPath $(if (!$SkipApk) { $android }) --repo $repo --title "AvtarPOS $Version" --notes $Notes --latest
if ($LASTEXITCODE -ne 0) { throw 'GitHub Release publishing failed.' }

Write-Host "Published: https://github.com/$repo/releases/tag/v$Version"

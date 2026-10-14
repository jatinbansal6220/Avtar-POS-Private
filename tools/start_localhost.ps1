param([switch]$NoBrowser, [ValidateRange(1024,65535)][int]$Port = 8080)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = Split-Path -Parent $PSScriptRoot
$url = "http://127.0.0.1:$Port/"

function Get-PackageHash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Test-AppServer {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        return $response.StatusCode -eq 200 -and $response.Content -match 'ZELOVIX / Avtar POS' -and $response.Content -match 'flutter_bootstrap'
    } catch { return $false }
}

try {
    if (-not (Test-AppServer)) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
        if ($listener) { throw 'Port 8080 is used by another application. Close that application or ask your developer; its process will not be stopped.' }

        $buildName = 'local-preview'
        if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'frontend\build\local-preview\index.html'))) {
            $buildName = 'professional-web'
        }
        $buildIndex = Join-Path $projectRoot "frontend\build\$buildName\index.html"
        if (-not (Test-Path -LiteralPath $buildIndex)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $packageDir = Join-Path $projectRoot 'frontend\build\launcher-package'
            $bundleRoot = Join-Path $packageDir 'bundle'
            $bundledLauncher = Join-Path $bundleRoot 'tools\start_localhost.ps1'
            if (-not ((Test-Path -LiteralPath (Join-Path $bundleRoot 'frontend\build\local-preview\index.html')) -and (Test-Path -LiteralPath (Join-Path $bundleRoot 'tools\runtime\python\python.exe')) -and (Test-Path -LiteralPath $bundledLauncher))) {
            Write-Host 'First run: downloading the ready localhost package. Internet is required once.' -ForegroundColor Cyan
            New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
            $releaseBase = 'https://github.com/jatinbansal6220/Avtar-POS-Private/releases/download/localhost-v20261014'
            $archive = Join-Path $packageDir 'AvtarPOS-Localhost-Windows.zip'
            $hashFile = Join-Path $packageDir 'SHA256.txt'
            Invoke-WebRequest "$releaseBase/SHA256.txt" -OutFile $hashFile -UseBasicParsing
            $expected = ((Get-Content -LiteralPath $hashFile -Raw).Trim() -split '\s+')[0]
            if ($expected -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid release checksum file.' }
            if (-not (Test-Path -LiteralPath $archive) -or (Get-PackageHash $archive) -ne $expected) {
                Invoke-WebRequest "$releaseBase/AvtarPOS-Localhost-Windows.zip" -OutFile $archive -UseBasicParsing
            }
            if ((Get-PackageHash $archive) -ne $expected) {
                throw 'Downloaded package checksum did not match. Please double-click again to retry.'
            }
            Expand-Archive -LiteralPath $archive -DestinationPath $bundleRoot -Force
            }
            if (-not (Test-Path -LiteralPath $bundledLauncher)) { throw 'Localhost package is incomplete.' }
            $launcherArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bundledLauncher, '-Port', $Port)
            if ($NoBrowser) { $launcherArguments += '-NoBrowser' }
            & powershell.exe @launcherArguments
            exit $LASTEXITCODE
        }
        $pythonPath = $null
        $candidates = @(
            (Join-Path $projectRoot 'tools\runtime\python\python.exe'),
            (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'),
            (Get-Command python -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
            (Get-Command py -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
        )
        foreach ($candidate in $candidates) {
            if (-not $candidate -or -not (Test-Path -LiteralPath $candidate)) { continue }
            if ($candidate -match '\\WindowsApps\\') { continue }
            & $candidate -c 'import sys; assert sys.version_info >= (3, 8)' 2>$null
            if ($LASTEXITCODE -eq 0) { $pythonPath = $candidate; break }
        }
        if (-not $pythonPath) { throw 'Python 3.8+ not found. Install Python and add it to PATH, then double-click again.' }
        $logDir = Join-Path $projectRoot 'frontend\build\launcher'
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $serverScript = Join-Path $PSScriptRoot 'serve_local_preview.py'
        $server = Start-Process -FilePath $pythonPath -ArgumentList @('-B', ('"' + $serverScript + '"'), '--build-dir', $buildName, '--port', $Port) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logDir 'server-output.log') -RedirectStandardError (Join-Path $logDir 'server-error.log')
        $ready = $false
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if (Test-AppServer) { $ready = $true; break }
            if ($server.HasExited) { break }
            Start-Sleep -Milliseconds 300
        }
        if (-not $ready) { throw "Localhost server did not start. See $logDir\server-error.log" }
    }
    if (-not $NoBrowser) { Start-Process $url }
    Write-Host "Avtar POS is ready: $url" -ForegroundColor Green
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

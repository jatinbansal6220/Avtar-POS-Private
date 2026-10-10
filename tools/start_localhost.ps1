param([switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$url = 'http://127.0.0.1:8080/'

function Test-AppServer {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        return $response.StatusCode -eq 200 -and $response.Content -match 'ZELOVIX / Avtar POS' -and $response.Content -match 'flutter_bootstrap'
    } catch { return $false }
}

try {
    if (-not (Test-AppServer)) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue
        if ($listener) { throw 'Port 8080 is used by another application. Close that application or ask your developer; its process will not be stopped.' }

        $buildName = 'local-preview'
        if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'frontend\build\local-preview\index.html'))) {
            $buildName = 'professional-web'
        }
        $buildIndex = Join-Path $projectRoot "frontend\build\$buildName\index.html"
        if (-not (Test-Path -LiteralPath $buildIndex)) {
            $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
            $flutterPath = if ($flutterCommand) { $flutterCommand.Source } else { 'D:\CodexTemp\AvtarPOS\flutter\bin\flutter.bat' }
            if (-not (Test-Path -LiteralPath $flutterPath)) { throw 'Flutter SDK not found. Install the compatible Flutter SDK and add it to PATH.' }
            $temporaryDir = Join-Path $projectRoot 'frontend\build\launcher-temp'
            New-Item -ItemType Directory -Force -Path $temporaryDir | Out-Null
            $env:TEMP = $temporaryDir
            $env:TMP = $temporaryDir
            Push-Location (Join-Path $projectRoot 'frontend')
            try {
                & $flutterPath pub get
                if ($LASTEXITCODE -ne 0) { throw 'Flutter dependencies could not be prepared.' }
                & $flutterPath build web --release --no-wasm-dry-run --dart-define=DEMO_MODE=true --output=build/local-preview
                if ($LASTEXITCODE -ne 0) { throw 'Local demo build failed. Review the build error above.' }
            } finally { Pop-Location }
            $buildName = 'local-preview'
        }

        $pythonPath = $null
        $candidates = @(
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
        $server = Start-Process -FilePath $pythonPath -ArgumentList @('-B', ('"' + $serverScript + '"'), '--build-dir', $buildName) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $logDir 'server-output.log') -RedirectStandardError (Join-Path $logDir 'server-error.log')
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

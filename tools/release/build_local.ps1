[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$BuildNumber,
    [switch]$SkipApk,
    [string]$FlutterPath
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$app = Join-Path $root 'frontend'
$flutter = $FlutterPath
if (!$flutter) {
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCommand) { $flutter = $flutterCommand.Source }
    elseif (Test-Path -LiteralPath (Join-Path $root 'tools\flutter\bin\flutter.bat')) {
        $flutter = Join-Path $root 'tools\flutter\bin\flutter.bat'
    }
}
$output = Join-Path $root "dist\releases\$Version"
$work = Join-Path $root "build\release-$Version"
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$vcRedist = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Redist\MSVC\v145\vc_redist.x64.exe'

if (!$flutter -or !(Test-Path -LiteralPath $flutter)) { throw 'Flutter was not found. Pass -FlutterPath with the full path to flutter.bat.' }
if (!$SkipApk -and !(Test-Path -LiteralPath (Join-Path $app 'android\key.properties'))) {
    throw 'Android release signing is required. Configure the existing private signing key in frontend/android/key.properties before publishing; never commit this file.'
}
if (!(Test-Path -LiteralPath $sevenZip)) { throw "7-Zip was not found: $sevenZip" }
if (!(Test-Path -LiteralPath $csc)) { throw "C# compiler was not found: $csc" }
if (!(Test-Path -LiteralPath $vcRedist)) { throw "Microsoft Visual C++ x64 redistributable was not found: $vcRedist" }

New-Item -ItemType Directory -Force -Path $output, $work | Out-Null
Push-Location $app
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
    & $flutter build windows --release --build-name $Version --build-number $BuildNumber "--dart-define=APP_VERSION=$Version"
    if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
    if (!$SkipApk) {
        & $flutter build apk --release --build-name $Version --build-number $BuildNumber "--dart-define=APP_VERSION=$Version"
        if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
    }
}
finally { Pop-Location }

$runtime = Join-Path $app 'build\windows\x64\runner\Release'
if (!(Test-Path -LiteralPath (Join-Path $runtime 'AvtarPOS.exe'))) {
    throw "Windows runtime was not produced: $runtime"
}
$payload = Join-Path $work 'AvtarPOS-runtime.zip'
if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Force }
& $sevenZip a -tzip $payload (Join-Path $runtime '*') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Could not create installer payload.' }

$installerSource = Join-Path $work 'AvtarPosSelfInstaller.cs'
$source = Get-Content -LiteralPath (Join-Path $root 'tools\packaging\AvtarPosSelfInstaller.cs') -Raw
$source = $source.Replace('private const string ProductVersion = "0.0.0";', "private const string ProductVersion = `"$Version`";")
$versionQuad = "$Version.0"
$source = $source.Replace('[assembly: AssemblyVersion("0.0.0.0")]', "[assembly: AssemblyVersion(`"$versionQuad`")]")
$source = $source.Replace('[assembly: AssemblyFileVersion("0.0.0.0")]', "[assembly: AssemblyFileVersion(`"$versionQuad`")]")
[System.IO.File]::WriteAllText($installerSource, $source, [System.Text.UTF8Encoding]::new($false))
$installer = Join-Path $output "AvtarPOS-Client-Setup-$Version.exe"
& $csc /nologo /target:winexe "/out:$installer" "/win32icon:$app\windows\runner\resources\app_icon.ico" /r:System.Windows.Forms.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll "/resource:$payload,AvtarPOS.Payload" "/resource:$vcRedist,AvtarPOS.VCRedist" $installerSource
if ($LASTEXITCODE -ne 0) { throw 'Could not compile the self-installing Windows setup.' }

if (!$SkipApk) {
    $apk = Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk'
    if (!(Test-Path -LiteralPath $apk)) { throw "APK was not produced: $apk" }
    Copy-Item -LiteralPath $apk -Destination (Join-Path $output "AvtarCook-$Version.apk") -Force
}

Get-ChildItem -LiteralPath $output -File | Select-Object Name, Length, LastWriteTime

$ErrorActionPreference = "Stop"

$Root = [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$Build = Join-Path $Root ".build"
$Stage = Join-Path ([System.IO.Path]::GetTempPath()) "zhibanshi-apk-stage"
$ToolStage = Join-Path ([System.IO.Path]::GetTempPath()) "zhibanshi-apk-tools"
$SignStage = Join-Path ([System.IO.Path]::GetTempPath()) "zhibanshi-apk-sign"
$Jdk = Join-Path $Root ".tools\jdk\jdk-17.0.20.1+1"
$Sdk = Join-Path $Root ".tools\android-sdk"
$JavaHome = $Jdk
$env:JAVA_HOME = $Jdk
$env:PATH = "$(Join-Path $Jdk 'bin');$env:PATH"
$AndroidJar = Join-Path $Sdk "platforms\android-35\android.jar"
$ToolAndroidJar = Join-Path $ToolStage "android-35.jar"
$BuildTools = Join-Path $Sdk "build-tools\35.0.0"
$Aapt2 = Join-Path $BuildTools "aapt2.exe"
$D8 = Join-Path $BuildTools "d8.bat"
$ZipAlign = Join-Path $BuildTools "zipalign.exe"
$ApkSigner = Join-Path $BuildTools "apksigner.bat"
$Javac = Join-Path $Jdk "bin\javac.exe"
$KeyTool = Join-Path $Jdk "bin\keytool.exe"
$OutputName = (-join ([char[]](0x624B, 0x673A, 0x7AEF, 0x503C, 0x73ED, 0x5BA4))) + ".apk"
$Output = Join-Path $Root $OutputName
$KeystoreDir = Join-Path $Root "signing"
$Keystore = Join-Path $KeystoreDir "zhibanshi.keystore"
$Bash = "C:\Program Files\Git\bin\bash.exe"
$Python = (Get-Command "python.exe" -ErrorAction Stop).Source

if (Test-Path -LiteralPath $Bash) {
    Get-ChildItem -LiteralPath (Join-Path $Root "assets\bin") -Filter "*.sh" | ForEach-Object {
        & $Bash -n $_.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "Shell syntax validation failed: $($_.Name)"
        }
    }
}

Get-ChildItem -LiteralPath (Join-Path $Root "assets\bin") -Filter "*.py" | ForEach-Object {
    & $Python -c "import pathlib, sys; p=pathlib.Path(sys.argv[1]); compile(p.read_text(encoding='utf-8'), str(p), 'exec')" $_.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "Python syntax validation failed: $($_.Name)"
    }
}

Get-ChildItem -LiteralPath (Join-Path $Root "tools") -Filter "*.py" | ForEach-Object {
    & $Python -c "import pathlib, sys; p=pathlib.Path(sys.argv[1]); compile(p.read_text(encoding='utf-8'), str(p), 'exec')" $_.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "Python syntax validation failed: tools\$($_.Name)"
    }
}

New-Item -ItemType Directory -Force -Path $KeystoreDir | Out-Null

if (Test-Path $Build) {
    $resolved = [System.IO.Path]::GetFullPath($Build)
    if (-not $resolved.StartsWith($Root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean outside workspace: $resolved"
    }
    Remove-Item -LiteralPath $Build -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $Build | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Build "classes") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Build "dex") | Out-Null

$StageRoot = [System.IO.Path]::GetFullPath($Stage)
$TempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
if (-not $StageRoot.StartsWith($TempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean stage outside temp: $StageRoot"
}
if (Test-Path $StageRoot) {
    Remove-Item -LiteralPath $StageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null

$ToolStageRoot = [System.IO.Path]::GetFullPath($ToolStage)
if (-not $ToolStageRoot.StartsWith($TempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean tool stage outside temp: $ToolStageRoot"
}
if (Test-Path $ToolStageRoot) {
    Remove-Item -LiteralPath $ToolStageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $ToolStageRoot | Out-Null
Copy-Item -LiteralPath $AndroidJar -Destination $ToolAndroidJar

Copy-Item -LiteralPath (Join-Path $Root "res") -Destination $StageRoot -Recurse
Copy-Item -LiteralPath (Join-Path $Root "assets") -Destination $StageRoot -Recurse
Copy-Item -LiteralPath (Join-Path $Root "java") -Destination $StageRoot -Recurse
Copy-Item -LiteralPath (Join-Path $Root "AndroidManifest.xml") -Destination $StageRoot

Get-ChildItem -LiteralPath (Join-Path $StageRoot "assets") -Recurse -Directory -Filter "__pycache__" |
    Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath (Join-Path $StageRoot "assets") -Recurse -File -Filter "*.pyc" |
    Remove-Item -Force

& $Aapt2 compile --dir (Join-Path $StageRoot "res") -o (Join-Path $Build "resources.zip")
if ($LASTEXITCODE -ne 0) { throw "aapt2 compile failed" }

& $Aapt2 link `
    -o (Join-Path $Build "unsigned.apk") `
    -I $ToolAndroidJar `
    --manifest (Join-Path $StageRoot "AndroidManifest.xml") `
    -A (Join-Path $StageRoot "assets") `
    --min-sdk-version 23 `
    --target-sdk-version 34 `
    --version-code 28 `
    --version-name 1.3.10 `
    (Join-Path $Build "resources.zip")
if ($LASTEXITCODE -ne 0) { throw "aapt2 link failed" }

$JavaFiles = Get-ChildItem -LiteralPath (Join-Path $StageRoot "java") -Recurse -Filter "*.java" |
    ForEach-Object { $_.FullName }
& $Javac -encoding UTF-8 -source 8 -target 8 -classpath $ToolAndroidJar `
    -d (Join-Path $Build "classes") $JavaFiles
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

$MainClass = Join-Path $Build "classes\com\zhibanshi\mobile\dutyroom\MainActivity.class"
if (-not (Test-Path -LiteralPath $MainClass)) {
    throw "javac did not produce MainActivity.class"
}

$ClassFiles = Get-ChildItem -LiteralPath (Join-Path $Build "classes") -Recurse -Filter "*.class" |
    ForEach-Object { $_.FullName }
& $D8 --min-api 23 --lib $ToolAndroidJar --output (Join-Path $Build "dex") $ClassFiles
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

$Unsigned = Join-Path $Build "unsigned.apk"
$Normalized = Join-Path $Build "normalized.apk"
& $Python (Join-Path $Root "tools\package_apk.py") $Unsigned (Join-Path $Build "dex\classes.dex") $Normalized
if ($LASTEXITCODE -ne 0) { throw "APK normalization failed" }

& $Python -c "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1]); e=z.getinfo('resources.arsc'); raise SystemExit(0 if e.compress_type == zipfile.ZIP_STORED else 1)" $Normalized
if ($LASTEXITCODE -ne 0) { throw "resources.arsc must remain uncompressed for Android 11+" }

& $ZipAlign -f -p 4 $Normalized (Join-Path $Build "aligned.apk")
if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }

& $Python -c "import sys, zipfile; z=zipfile.ZipFile(sys.argv[1]); e=z.getinfo('resources.arsc'); raise SystemExit(0 if e.compress_type == zipfile.ZIP_STORED else 1)" (Join-Path $Build "aligned.apk")
if ($LASTEXITCODE -ne 0) { throw "resources.arsc must remain uncompressed for Android 11+" }

if (-not (Test-Path $Keystore)) {
    & $KeyTool -genkeypair `
        -keystore $Keystore `
        -storepass zhibanshi `
        -keypass zhibanshi `
        -alias zhibanshi `
        -keyalg RSA `
        -keysize 2048 `
        -validity 10000 `
        -dname "CN=Mobile Duty Room, OU=Local, O=Zhibanshi, L=Shanghai, ST=Shanghai, C=CN"
    if ($LASTEXITCODE -ne 0) { throw "keystore generation failed" }
}

$SignStageRoot = [System.IO.Path]::GetFullPath($SignStage)
if (-not $SignStageRoot.StartsWith($TempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean sign stage outside temp: $SignStageRoot"
}
if (Test-Path $SignStageRoot) {
    Remove-Item -LiteralPath $SignStageRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $SignStageRoot | Out-Null

$SignInput = Join-Path $SignStageRoot "aligned.apk"
$SignKeystore = Join-Path $SignStageRoot "zhibanshi.keystore"
$SignedApk = Join-Path $SignStageRoot "signed.apk"
Copy-Item -LiteralPath (Join-Path $Build "aligned.apk") -Destination $SignInput
Copy-Item -LiteralPath $Keystore -Destination $SignKeystore

& $ApkSigner sign `
    --v1-signing-enabled true `
    --v2-signing-enabled true `
    --v3-signing-enabled true `
    --v4-signing-enabled false `
    --ks $SignKeystore `
    --ks-key-alias zhibanshi `
    --ks-pass pass:zhibanshi `
    --key-pass pass:zhibanshi `
    --out $SignedApk `
    $SignInput
if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }

& $ApkSigner verify --verbose $SignedApk
if ($LASTEXITCODE -ne 0) { throw "APK verification failed" }

& $ApkSigner verify --verbose --min-sdk-version 23 $SignedApk
if ($LASTEXITCODE -ne 0) { throw "APK legacy verification failed" }

$Badging = & $Aapt2 dump badging $SignedApk
if ($LASTEXITCODE -ne 0) { throw "APK badging verification failed" }
if (-not ($Badging -match "package: name='com\.zhibanshi\.mobile\.dutyroom' versionCode='28' versionName='1\.3\.10'")) {
    throw "Unexpected APK package or version metadata"
}
if (-not ($Badging -match "targetSdkVersion:'34'")) {
    throw "Unexpected target SDK"
}

Copy-Item -LiteralPath $SignedApk -Destination $Output -Force

$File = Get-Item -LiteralPath $Output
Write-Output ("APK={0}" -f $File.FullName)
Write-Output ("SIZE={0}" -f $File.Length)

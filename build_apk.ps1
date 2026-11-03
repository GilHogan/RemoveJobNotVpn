$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "D:\softFiles\androidSdk" }
$aaptBuildTools = "$sdkRoot\build-tools\33.0.2"
$dexBuildTools = "$sdkRoot\build-tools\30.0.3"
$androidJar = "$sdkRoot\platforms\android-33\android.jar"
$javaHome = if ($env:JAVA_HOME) { $env:JAVA_HOME } else { "C:\Program Files\Java\jdk1.8.0_333" }
$javac = "$javaHome\bin\javac.exe"
$jar = "$javaHome\bin\jar.exe"
$keytool = "$javaHome\bin\keytool.exe"

$buildDir = "$projectRoot\build"
$genDir = "$buildDir\gen"
$stubClassesDir = "$buildDir\stub_classes"
$appClassesDir = "$buildDir\app_classes"
$dexDir = "$buildDir\dex"
$apkOutput = "$projectRoot\RemoveJobNotVpn.apk"

if (Test-Path $buildDir) {
    Remove-Item -Recurse -Force $buildDir
}
New-Item -ItemType Directory -Force -Path $genDir, $stubClassesDir, $appClassesDir, $dexDir | Out-Null

Write-Host "[1/6] Compiling resources with aapt2..."
$compiledResZip = "$buildDir\compiled_res.zip"
& "$aaptBuildTools\aapt2.exe" compile --dir "$projectRoot\app\src\main\res" -o $compiledResZip

$unalignedApk = "$buildDir\unaligned.apk"
& "$aaptBuildTools\aapt2.exe" link `
    -I $androidJar `
    --manifest "$projectRoot\app\src\main\AndroidManifest.xml" `
    -A "$projectRoot\app\src\main\assets" `
    --java $genDir `
    -o $unalignedApk `
    $compiledResZip

Write-Host "[2/6] Compiling Xposed compileOnly API stubs..."
$stubSources = Get-ChildItem -Recurse -Filter "*.java" "$projectRoot\app\src\compileOnly\java" | ForEach-Object { $_.FullName }
& $javac -J"-Dfile.encoding=UTF-8" -source 1.8 -target 1.8 -encoding UTF-8 -bootclasspath $androidJar -d $stubClassesDir $stubSources
$xposedStubJar = "$buildDir\xposed-api-stub.jar"
& $jar cf $xposedStubJar -C $stubClassesDir .

Write-Host "[3/6] Compiling plugin Java sources..."
$appSources = @()
$appSources += Get-ChildItem -Recurse -Filter "*.java" "$projectRoot\app\src\main\java" | ForEach-Object { $_.FullName }
$appSources += Get-ChildItem -Recurse -Filter "*.java" $genDir | ForEach-Object { $_.FullName }
& $javac -J"-Dfile.encoding=UTF-8" -source 1.8 -target 1.8 -encoding UTF-8 -bootclasspath $androidJar -classpath $xposedStubJar -d $appClassesDir $appSources

Write-Host "[4/6] Converting bytecode to classes.dex..."
$classFiles = Get-ChildItem -Recurse -Filter "*.class" $appClassesDir | ForEach-Object { $_.FullName }
& "$dexBuildTools\d8.bat" --lib $androidJar --min-api 26 --output $dexDir $classFiles

Write-Host "[5/6] Packaging classes.dex into APK and zipaligning..."
& $jar uf $unalignedApk -C $dexDir classes.dex
$alignedApk = "$buildDir\aligned.apk"
& "$aaptBuildTools\zipalign.exe" -f -p 4 $unalignedApk $alignedApk

Write-Host "[6/6] Signing APK with v2/v3 signature..."
$keystorePath = "$projectRoot\keystore.jks"
if (-not (Test-Path $keystorePath)) {
    & $keytool -J"-Dfile.encoding=UTF-8" -genkeypair `
        -v `
        -keystore $keystorePath `
        -alias hogan `
        -keyalg RSA `
        -keysize 2048 `
        -validity 10000 `
        -storepass 123456 `
        -keypass 123456 `
        -dname "CN=hogan, OU=hogan, O=hogan, L=China, ST=China, C=CN"
}

& "$dexBuildTools\apksigner.bat" sign `
    --ks $keystorePath `
    --ks-key-alias hogan `
    --ks-pass pass:123456 `
    --key-pass pass:123456 `
    --out $apkOutput `
    $alignedApk

& "$dexBuildTools\apksigner.bat" verify -v $apkOutput
Write-Host "Build succeeded: $apkOutput"

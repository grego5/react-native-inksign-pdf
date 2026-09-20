[CmdletBinding()]
param(
    [ValidateSet("arm64-v8a", "armeabi-v7a", "x86", "x86_64")]
    [string]$Abi = "arm64-v8a",
    [string]$NdkPath,
    [string]$ToolchainFile,
    [string]$BuildDirectory,
    [string]$OutputDirectory,
    [ValidateSet("ON", "OFF")]
    [string]$EnablePerfettoTrace = "OFF",
    [switch]$SmokeLink
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot ".." )).Path
$cmake = (Get-Command cmake -ErrorAction Stop).Source

if ([string]::IsNullOrWhiteSpace($ToolchainFile)) {
    if ([string]::IsNullOrWhiteSpace($NdkPath)) {
        $NdkPath = if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_NDK_HOME)) {
            $env:ANDROID_NDK_HOME
        } elseif (-not [string]::IsNullOrWhiteSpace($env:ANDROID_NDK_ROOT)) {
            $env:ANDROID_NDK_ROOT
        } else {
            $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($NdkPath)) {
        throw "Provide -ToolchainFile or set -NdkPath/ANDROID_NDK_HOME."
    }
    $ToolchainFile = Join-Path $NdkPath "build/cmake/android.toolchain.cmake"
}

$ToolchainFile = (Resolve-Path $ToolchainFile -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
    $BuildDirectory = Join-Path $repositoryRoot "build/stroke-engine-archive/$Abi"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $BuildDirectory "artifacts"
}
$BuildDirectory = [System.IO.Path]::GetFullPath($BuildDirectory)
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

$archiveName = if ($EnablePerfettoTrace -eq "ON") {
    "libinkengine_${Abi}_profile.a"
} else {
    "libinkengine_${Abi}.a"
}

$configureArguments = @(
    "-S", (Join-Path $repositoryRoot "cmake/stroke-engine-archive"),
    "-B", $BuildDirectory,
    "-G", "Ninja",
    "-DCMAKE_TOOLCHAIN_FILE=$ToolchainFile",
    "-DANDROID_ABI=$Abi",
    "-DANDROID_PLATFORM=android-24",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DENABLE_PERFETTO_TRACE=$EnablePerfettoTrace",
    "-DSTROKE_ENGINE_NDK_PATH=$NdkPath",
    "-DSTROKE_ENGINE_ARCHIVE_OUTPUT_DIRECTORY=$OutputDirectory",
    "-DSTROKE_ENGINE_ARCHIVE_NAME=$archiveName"
)

& $cmake @configureArguments
if ($LASTEXITCODE -ne 0) {
    throw "Stroke archive CMake configure failed with exit code $LASTEXITCODE."
}

$buildTarget = if ($SmokeLink) { "StrokeEngineArchiveSmoke" } else { "StrokeEngineArchive" }
& $cmake --build $BuildDirectory --target $buildTarget --parallel
if ($LASTEXITCODE -ne 0) {
    throw "Stroke archive build failed with exit code $LASTEXITCODE."
}

Write-Output "Built $archiveName in $OutputDirectory"

[CmdletBinding()]
param(
    [ValidateSet("jvm", "build", "connected")]
    [string]$Mode = "jvm",
    [Alias("Selector")]
    [string]$Test,
    [ValidateSet("arm64-v8a", "x86", "x86_64")]
    [string]$Abi = "arm64-v8a",
    [switch]$AllDevices,
    [switch]$RefreshDependencies
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$androidProject = Join-Path $repositoryRoot "example\android"
$moduleAndroidProject = Join-Path $repositoryRoot "android"
$gradleUserHome = if (-not [string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME)) {
    $env:GRADLE_USER_HOME
} elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    Join-Path $env:USERPROFILE ".gradle"
} else {
    $null
}
$moduleProject = ":grego5_react-native-inksign-pdf"
$progressIntervalSeconds = 15
$progressPollIntervalSeconds = 1

function Stop-Runner([string]$Message, [int]$Code = 2) {
    [Console]::Error.WriteLine("FAIL: $Message")
    exit $Code
}

function ConvertTo-ProcessArgument([string]$Argument) {
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + $Argument.Replace('"', '\"') + '"'
}

function Invoke-Captured([string]$Command, [string[]]$Arguments, [string]$Label) {
    $startTime = [DateTime]::UtcNow
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Command
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }
    } else {
        $startInfo.Arguments = ($Arguments | ForEach-Object {
            ConvertTo-ProcessArgument ([string]$_)
        }) -join ' '
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
    } catch {
        $process.Dispose()
        Stop-Runner "could not start $Label with '$Command': $($_.Exception.Message)"
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $lastProgressTime = $startTime

    while (-not $process.HasExited) {
        Start-Sleep -Seconds $progressPollIntervalSeconds
        $now = [DateTime]::UtcNow
        if (($now - $lastProgressTime).TotalSeconds -ge $progressIntervalSeconds -and
            -not $process.HasExited) {
            $elapsed = ($now - $startTime).TotalSeconds
            [Console]::Error.WriteLine(
                "RUN $Label still running elapsed=$('{0:N0}' -f $elapsed)s"
            )
            $lastProgressTime = $now
        }
    }
    $process.WaitForExit()

    $output = @()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if (-not [string]::IsNullOrEmpty($stdout)) {
        $output += @($stdout -split "`r?`n")
    }
    if (-not [string]::IsNullOrEmpty($stderr)) {
        $output += @($stderr -split "`r?`n")
    }
    $exitCode = $process.ExitCode
    $process.Dispose()
    [pscustomobject]@{
        Output = $output
        ExitCode = $exitCode
        StartedAt = $startTime
    }
}

function Get-GradlePath {
    if (-not (Test-Path -LiteralPath $androidProject -PathType Container)) {
        Stop-Runner "Android Gradle project was not found at $androidProject"
    }

    $wrapperScript = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        Join-Path $androidProject "gradlew.bat"
    } else {
        Join-Path $androidProject "gradlew"
    }
    $wrapperJar = Join-Path $androidProject "gradle\wrapper\gradle-wrapper.jar"
    $wrapperProperties = Join-Path $androidProject "gradle\wrapper\gradle-wrapper.properties"
    if ((Test-Path -LiteralPath $wrapperScript -PathType Leaf) -and
        (Test-Path -LiteralPath $wrapperJar -PathType Leaf) -and
        (Test-Path -LiteralPath $wrapperProperties -PathType Leaf)) {
        return [pscustomobject]@{
            Path = $wrapperScript
            UserHome = $gradleUserHome
            Source = "project wrapper"
        }
    }

    if ($null -eq $gradleUserHome) {
        Stop-Runner "project Gradle wrapper is incomplete and USERPROFILE is unavailable for the documented Gradle fallback"
    }

    $distributionRoot = Join-Path $gradleUserHome "wrapper\dists\gradle-9.3.1-bin"
    $gradleName = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        "gradle.bat"
    } else {
        "gradle"
    }
    if (Test-Path -LiteralPath $distributionRoot -PathType Container) {
        $installedGradle = Get-ChildItem -LiteralPath $distributionRoot -Recurse -File -Filter $gradleName |
            Sort-Object FullName |
            Select-Object -First 1
        if ($null -ne $installedGradle) {
            return [pscustomobject]@{
                Path = $installedGradle.FullName
                UserHome = $gradleUserHome
                Source = "installed Gradle 9.3.1"
            }
        }
    }

    Stop-Runner "no usable project Gradle wrapper or installed Gradle 9.3.1 distribution was found"
}

function Get-GradleInvocation([pscustomobject]$Gradle, [string[]]$GradleArguments) {
    # ProcessStartInfo launches the project .bat wrapper directly on Windows.
    # This also preserves argument boundaries in PowerShell 7 and uses the
    # quoting fallback in Invoke-Captured for Windows PowerShell 5.1.
    return [pscustomobject]@{
        Command = $Gradle.Path
        Arguments = $GradleArguments
    }
}

function Get-AdbPath {
    $sdkRoot = if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
        $env:ANDROID_HOME
    } elseif (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) {
        $env:ANDROID_SDK_ROOT
    } else {
        $null
    }
    if ($null -ne $sdkRoot) {
        $adbName = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            "adb.exe"
        } else {
            "adb"
        }
        $sdkAdb = Join-Path $sdkRoot "platform-tools\$adbName"
        if (Test-Path -LiteralPath $sdkAdb -PathType Leaf) {
            return $sdkAdb
        }
    }

    $pathCommand = Get-Command adb -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand) {
        return $pathCommand.Source
    }
    Stop-Runner "adb was not found; connect an Android device and ensure platform-tools is available"
}

function Get-FirstOnlineAndroidSerial {
    $adb = Get-AdbPath
    $result = Invoke-Captured $adb @("devices") "adb device discovery"
    if ($result.ExitCode -ne 0) {
        Write-BoundedFailure $result.Output
        Stop-Runner "adb device discovery failed"
    }
    foreach ($line in @($result.Output)) {
        if ([string]$line -match '^([^\s]+)\s+device\s*$') {
            return $Matches[1]
        }
    }
    Stop-Runner "no online Android device is available for connected instrumentation tests"
}

function Write-BoundedFailure([string[]]$Output) {
    $lines = @($Output | ForEach-Object { [string]$_ })
    $start = [Math]::Max(0, $lines.Count - 140)
    $count = [Math]::Min(140, $lines.Count - $start)
    if ($count -gt 0) {
        $lines[$start..($start + $count - 1)] | ForEach-Object {
            [Console]::Error.WriteLine($_)
        }
    }
}

function Get-Matches([string[]]$Output, [string]$Pattern) {
    $resultMatches = @()
    foreach ($line in $Output) {
        if ([string]$line -match $Pattern) {
            $resultMatches += $Matches[1]
        }
    }
    return $resultMatches
}

function Write-FailureDetails([pscustomobject]$Gradle, [string[]]$Output, [string]$Selector) {
    [Console]::Error.WriteLine("Gradle: $($Gradle.Path) [$($Gradle.Source)]")

    $failedTasks = @(Get-Matches $Output "Execution failed for task '([^']+)'")
    if ($failedTasks.Count -gt 0) {
        [Console]::Error.WriteLine("Failing task: $($failedTasks -join ', ')")
    }

    $reports = @(Get-Matches $Output "(?:See the report at:|report is available at:|reports? at:)\s*(\S+)")
    if ($reports.Count -gt 0) {
        [Console]::Error.WriteLine("Gradle report: $($reports -join ', ')")
    }

    if (-not [string]::IsNullOrWhiteSpace($Selector) -and
        (($Output -join "`n") -match "No tests found for given includes")) {
        [Console]::Error.WriteLine("JVM selector matched no tests: $Selector")
    }
}

function Get-ArtifactPaths([string]$ArtifactMode) {
    $artifactRoots = if ($ArtifactMode -eq "jvm") {
        @($moduleAndroidProject)
    } else {
        @($androidProject, $moduleAndroidProject)
    }
    $artifactRoots = @($artifactRoots |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($artifactRoots.Count -eq 0) {
        return @()
    }

    $files = @($artifactRoots | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Recurse -File -ErrorAction SilentlyContinue
    }) | Sort-Object FullName -Unique
    if ($ArtifactMode -eq "jvm") {
        return @($files |
            Where-Object {
                $_.FullName -match "[\\/]reports[\\/]tests[\\/]testDebugUnitTest[\\/]index\.html$" -or
                $_.FullName -match "[\\/]test-results[\\/]testDebugUnitTest[\\/]TEST-[^\\/]+\.xml$"
            } |
            Sort-Object FullName |
            ForEach-Object { $_.FullName })
    }
    $appDebugApk = Join-Path $androidProject "app\build\outputs\apk\debug\app-debug.apk"
    $moduleInstrumentationRoot = Join-Path $moduleAndroidProject "build\outputs\apk\androidTest\debug"
    return @($files |
        Where-Object {
            $_.FullName -ieq $appDebugApk -or
            ($_.Extension -ieq ".apk" -and
                $_.FullName.StartsWith($moduleInstrumentationRoot, [System.StringComparison]::OrdinalIgnoreCase))
        } |
        Sort-Object FullName |
        ForEach-Object { $_.FullName })
}

if ($AllDevices -and $Mode -ne "connected") {
    Stop-Runner "-AllDevices is only valid with -Mode connected"
}
if ($Mode -eq "jvm" -and $PSBoundParameters.ContainsKey("Abi")) {
    Stop-Runner "-Abi is only valid with -Mode build or connected"
}
if ($Mode -eq "build" -and -not [string]::IsNullOrWhiteSpace($Test)) {
    Stop-Runner "-Test is only valid with -Mode jvm or -Mode connected"
}

$gradle = Get-GradlePath
$gradleArguments = @()
if ($null -ne $gradle.UserHome) {
    $gradleArguments += @("-g", $gradle.UserHome)
}
$gradleArguments += @("-p", $androidProject)
if ($Mode -eq "build" -or $Mode -eq "connected") {
    $gradleArguments += "-PreactNativeArchitectures=$Abi"
}
if ($Mode -eq "jvm") {
    $gradleArguments += "${moduleProject}:testDebugUnitTest"
    if (-not [string]::IsNullOrWhiteSpace($Test)) {
        $gradleArguments += @("--tests", $Test)
    }
} elseif ($Mode -eq "connected") {
    $gradleArguments += "${moduleProject}:connectedDebugAndroidTest"
    if (-not [string]::IsNullOrWhiteSpace($Test)) {
        $gradleArguments += "-Pandroid.testInstrumentationRunnerArguments.class=$Test"
    }
} else {
    $gradleArguments += @(
        ":app:assembleDebug",
        "${moduleProject}:assembleDebugAndroidTest"
    )
}

if (-not $RefreshDependencies) {
    $gradleArguments += "--offline"
} else {
    $gradleArguments += "--refresh-dependencies"
}
$gradleArguments += @("--quiet", "--warning-mode", "none", "--no-daemon", "--console=plain")

$savedAndroidSerial = $env:ANDROID_SERIAL
$hadAndroidSerial = Test-Path Env:ANDROID_SERIAL
try {
    if ($Mode -eq "connected") {
        if ($AllDevices) {
            Remove-Item Env:ANDROID_SERIAL -ErrorAction SilentlyContinue
        } else {
            $env:ANDROID_SERIAL = Get-FirstOnlineAndroidSerial
            Write-Output "connectedDebugAndroidTest: running on first available device '$($env:ANDROID_SERIAL)'"
        }
    }

    $invocation = Get-GradleInvocation $gradle $gradleArguments
if ($PSBoundParameters.ContainsKey("Verbose")) {
    Write-Verbose "Gradle: $($gradle.Path) [$($gradle.Source)]"
    Write-Verbose "Command: $($invocation.Command) $($invocation.Arguments -join ' ')"
}

$label = if ($Mode -eq "jvm") {
    "Android JVM tests"
} elseif ($Mode -eq "connected") {
    "Android connected instrumentation tests"
} else {
    "Android debug APK build"
}
$result = Invoke-Captured $invocation.Command $invocation.Arguments $label
if ($result.ExitCode -ne 0) {
    Write-FailureDetails $gradle $result.Output $Test
    Write-BoundedFailure $result.Output
    [Console]::Error.WriteLine("FAIL mode=$Mode exit=$($result.ExitCode)")
    exit $result.ExitCode
}
} finally {
    if ($hadAndroidSerial) {
        $env:ANDROID_SERIAL = $savedAndroidSerial
    } else {
        Remove-Item Env:ANDROID_SERIAL -ErrorAction SilentlyContinue
    }
}

$artifacts = @(Get-ArtifactPaths $Mode)
$elapsed = ([DateTime]::UtcNow - $result.StartedAt).TotalSeconds
if ($Mode -eq "jvm") {
    $artifactLabel = if ($artifacts.Count -gt 0) { $artifacts -join ", " } else { "none found" }
    Write-Output "PASS mode=jvm elapsed=$('{0:N2}' -f $elapsed)s reports=$artifactLabel gradle=$($gradle.Path)"
} elseif ($Mode -eq "connected") {
    Write-Output "PASS mode=connected elapsed=$('{0:N2}' -f $elapsed)s gradle=$($gradle.Path)"
} else {
    $artifactLabel = if ($artifacts.Count -gt 0) { $artifacts -join ", " } else { "none found" }
    Write-Output "PASS mode=build elapsed=$('{0:N2}' -f $elapsed)s apks=$artifactLabel gradle=$($gradle.Path)"
}

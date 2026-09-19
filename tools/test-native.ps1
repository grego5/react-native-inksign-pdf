[CmdletBinding()]
param(
    [string]$Suite = "geometry",
    [switch]$Build
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot ".." )).Path
$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
$progressIntervalSeconds = 15
$progressPollIntervalSeconds = 1
$vsInstallPath = if (-not [string]::IsNullOrWhiteSpace($env:VSINSTALLDIR)) {
    $env:VSINSTALLDIR.TrimEnd("\")
} elseif (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
    Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\18\BuildTools"
} else {
    $null
}
$vsDevCmdPath = if ($null -ne $vsInstallPath) {
    Join-Path $vsInstallPath "Common7\Tools\VsDevCmd.bat"
} else {
    $null
}

$suiteTests = @{
    geometry = @(
        "StrokeEngineTests",
        "StrokeReplayTests",
        "UpstreamGeometryTests",
        "UpstreamOutputTests",
        "UpstreamPolicyTests"
    )
    lifecycle = @(
        "StrokeCheckpointTests",
        "InputNormalizerTests",
        "CurrentInkInputModelerTests",
        "CommittedCenterlineTests",
        "ContactLifecycleTests",
        "VelocityWidthModelTests",
        "FrameTransportTests",
        "PositionedTextModelTests"
    )
}

$allTests = @(
    "StrokeEngineTests",
    "StrokeBatchTests",
    "StrokeFixtureTests",
    "StrokePerformanceTests",
    "StrokeCheckpointTests",
    "StrokeEngineCTests",
    "StrokeReplayTests",
    "InputNormalizerTests",
    "CurrentInkInputModelerTests",
    "CommittedCenterlineTests",
    "ContactLifecycleTests",
    "VelocityWidthModelTests",
    "UpstreamGeometryTests",
    "UpstreamPolicyTests",
    "UpstreamOutputTests",
    "FrameTransportTests",
    "PositionedTextModelTests"
)

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

function Invoke-Captured([string]$Command, [string[]]$Arguments, [string]$Label,
    [switch]$StreamOutput) {
    $startTime = [DateTime]::UtcNow
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Command
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
    } else {
        $startInfo.Arguments = ($Arguments | ForEach-Object {
            ConvertTo-ProcessArgument ([string]$_)
        }) -join ' '
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    if ($StreamOutput) {
        $stdoutReader = $process.StandardOutput
        $stderrReader = $process.StandardError
        $stdoutTask = $stdoutReader.ReadLineAsync()
        $stderrTask = $stderrReader.ReadLineAsync()
        $stdoutDone = $false
        $stderrDone = $false
        $output = @()
        $lastProgressTime = $startTime

        while (-not $stdoutDone -or -not $stderrDone) {
            $receivedOutput = $false
            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stdoutDone = $true
                } else {
                    $output += $line
                    [Console]::Out.WriteLine($line)
                    $stdoutTask = $stdoutReader.ReadLineAsync()
                }
                $receivedOutput = $true
            }
            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                $line = $stderrTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stderrDone = $true
                } else {
                    $output += $line
                    [Console]::Error.WriteLine($line)
                    $stderrTask = $stderrReader.ReadLineAsync()
                }
                $receivedOutput = $true
            }

            $now = [DateTime]::UtcNow
            if (($now - $lastProgressTime).TotalSeconds -ge $progressIntervalSeconds -and
                -not $process.HasExited) {
                $elapsed = ($now - $startTime).TotalSeconds
                [Console]::Error.WriteLine(
                    "RUN $Label still running elapsed=$('{0:N0}' -f $elapsed)s"
                )
                $lastProgressTime = $now
            }
            if (-not $receivedOutput) {
                Start-Sleep -Milliseconds 100
            }
        }
        $process.WaitForExit()
    } else {
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
    }
    $exitCode = $process.ExitCode
    $process.Dispose()
    [pscustomobject]@{
        Output = $output
        ExitCode = $exitCode
    }
}

function Write-BoundedFailure([string[]]$Output) {
    $lines = @($Output | ForEach-Object { [string]$_ })
    # CTest prints a failed test's output before its final failed-test list.
    # Keep the tail so assertion diagnostics are not hidden by that list.
    $start = [Math]::Max(0, $lines.Count - 160)
    $count = [Math]::Min(160, $lines.Count - $start)
    if ($count -gt 0) {
        $lines[$start..($start + $count - 1)] | ForEach-Object {
            [Console]::Error.WriteLine($_)
        }
    }
}

function Get-ConfiguredBuild {
    # Keep the first configured directory in this order when several exist.
    # startup-debug is the repository's normal focused-validation directory.
    $candidates = @(
        (Join-Path $repositoryRoot "build\startup-debug"),
        (Join-Path $repositoryRoot "build\startup-release"),
        (Join-Path $repositoryRoot "build")
    )

    foreach ($candidate in $candidates) {
        $cache = Join-Path $candidate "CMakeCache.txt"
        if (Test-Path -LiteralPath $cache -PathType Leaf) {
            return $candidate
        }
    }

    Stop-Runner "no configured native build directory found; expected build\startup-debug, build\startup-release, or build"
}

function Get-CacheValue([string]$CachePath, [string]$Key) {
    $line = Select-String -LiteralPath $CachePath -Pattern "^$([regex]::Escape($Key)):[^=]*=(.*)$" |
        Select-Object -First 1
    if ($null -eq $line) {
        return $null
    }
    return $line.Matches[0].Groups[1].Value.Trim()
}

function Assert-NativeTargetsFresh([string[]]$TargetNames, [string]$BuildDirectory,
    [string]$Configuration) {
    $generator = Get-CacheValue (Join-Path $BuildDirectory "CMakeCache.txt") "CMAKE_GENERATOR"
    if ($generator -notmatch "^Ninja") {
        Write-Output "INFO native build freshness check is unavailable for generator '$generator'; use -Build when sources changed"
        return
    }

    $dryRunArguments = @(
        "--build", $BuildDirectory,
        "--config", $Configuration,
        "--parallel", "1",
        "--target"
    ) + $TargetNames + @("--", "-n")
    $dryRunResult = Invoke-Captured $cmake.Source $dryRunArguments "native build freshness check"
    if ($dryRunResult.ExitCode -ne 0) {
        Write-BoundedFailure $dryRunResult.Output
        Stop-Runner "could not check native build freshness; rerun with -Build" 1
    }
    if ($dryRunResult.Output -notmatch "(?im)^ninja: no work to do\.?\s*$") {
        Stop-Runner "native test targets are out of date in $BuildDirectory; rerun with -Build"
    }
}

function Initialize-MsvcEnvironment([string]$CachePath) {
    $compiler = Get-CacheValue $CachePath "CMAKE_CXX_COMPILER"
    if ($isWindowsHost -and $compiler -match "(?:^|[\\/])cl\.exe$") {
        if ([string]::IsNullOrWhiteSpace($vsInstallPath) -or
            -not (Test-Path -LiteralPath $vsDevCmdPath -PathType Leaf)) {
            Stop-Runner "MSVC compiler is configured, but VsDevCmd.bat was not found at $vsDevCmdPath"
        }

        # cl.exe can already be on PATH while INCLUDE/LIB are absent. Import
        # the complete developer environment instead of using compiler lookup
        # as a proxy for a usable MSVC setup.
        $environmentCommand = 'call "' + $vsDevCmdPath + '" -arch=amd64 >nul 2>nul && set'
        $environmentLines = @(& $env:ComSpec /d /s /c $environmentCommand)
        $environmentExitCode = $LASTEXITCODE
        if ($environmentExitCode -ne 0) {
            Stop-Runner "could not initialize the Visual Studio build environment with $vsDevCmdPath"
        }

        $environmentValues = @{}
        $pathValue = $null
        $fallbackPathValue = $null
        foreach ($environmentLine in $environmentLines) {
            $separator = ([string]$environmentLine).IndexOf('=')
            if ($separator -le 0) {
                continue
            }
            $environmentName = ([string]$environmentLine).Substring(0, $separator)
            $environmentValue = ([string]$environmentLine).Substring($separator + 1)
            if ($environmentName -ieq 'PATH') {
                if ($environmentValue -match '(?i)\\VC\\Tools\\MSVC\\') {
                    $pathValue = $environmentValue
                } elseif ($null -eq $fallbackPathValue) {
                    $fallbackPathValue = $environmentValue
                }
            } else {
                $environmentValues[$environmentName] = $environmentValue
            }
        }
        foreach ($environmentValue in $environmentValues.GetEnumerator()) {
            Set-Item -Path ("Env:{0}" -f $environmentValue.Key) -Value $environmentValue.Value
        }
        if ($null -eq $pathValue) {
            $pathValue = $fallbackPathValue
        }
        if ($null -ne $pathValue) {
            $env:Path = $pathValue
        }

        if ($null -eq (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
            Stop-Runner "MSVC compiler is configured, but cl.exe is unavailable after VsDevCmd initialization"
        }
    }
}

if ($Suite -notin @("geometry", "lifecycle", "all")) {
    Stop-Runner "unknown suite '$Suite'; expected geometry, lifecycle, or all"
}

$cmake = Get-Command cmake -ErrorAction SilentlyContinue
$ctest = Get-Command ctest -ErrorAction SilentlyContinue
if ($null -eq $cmake) {
    Stop-Runner "cmake is not available on PATH"
}
if ($null -eq $ctest) {
    Stop-Runner "ctest is not available on PATH"
}

$buildDirectory = Get-ConfiguredBuild
$cachePath = Join-Path $buildDirectory "CMakeCache.txt"
$configuration = Get-CacheValue $cachePath "CMAKE_BUILD_TYPE"
if ([string]::IsNullOrWhiteSpace($configuration)) {
    $configuration = "Debug"
}

$selectedTests = if ($Suite -eq "all") { $allTests } else { $suiteTests[$Suite] }
$regex = if ($Suite -eq "all") {
    $null
} else {
    "^(" + (($selectedTests | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")$"
}

if ($Build) {
    Initialize-MsvcEnvironment $cachePath
    # Let the configured generator use its normal worker count. The
    # freshness probe remains serial because it is only a dry-run.
    $buildArguments = @("--build", $buildDirectory, "--config", $configuration)
    if ($Suite -ne "all") {
        $buildArguments += "--target"
        $buildArguments += $selectedTests
    }

    $buildResult = Invoke-Captured $cmake.Source $buildArguments "native build"
    if ($buildResult.ExitCode -ne 0) {
        Write-BoundedFailure $buildResult.Output
        Stop-Runner "native build failed with exit code $($buildResult.ExitCode)" 1
    }
}

Assert-NativeTargetsFresh $selectedTests $buildDirectory $configuration

$discoveryArguments = @("--test-dir", $buildDirectory, "-N", "-C", $configuration)
if ($null -ne $regex) {
    $discoveryArguments += @("-R", $regex)
}
$discoveryResult = Invoke-Captured $ctest.Source $discoveryArguments "CTest discovery"
if ($discoveryResult.ExitCode -ne 0) {
    Write-BoundedFailure $discoveryResult.Output
    Stop-Runner "CTest discovery failed with exit code $($discoveryResult.ExitCode)" 1
}

$discoveredTests = @()
foreach ($line in $discoveryResult.Output) {
    if ($line -match "^\s*Test\s+#\d+:\s+(.+?)\s*$") {
        $discoveredTests += $Matches[1]
    }
}
if ($discoveredTests.Count -eq 0) {
    Stop-Runner "suite '$Suite' selected zero registered CTest tests in $buildDirectory"
}

if ($Suite -ne "all") {
    $missingExecutables = @(
        $discoveryResult.Output |
            ForEach-Object {
                if ([string]$_ -match "^\s*Could not find executable\s+(.+?)\s*$") {
                    $Matches[1]
                }
            }
    )
    if ($missingExecutables.Count -gt 0) {
        Stop-Runner "suite '$Suite' is partially built; missing executable(s): $($missingExecutables -join ', '). Re-run with -Build"
    }
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$testArguments = @("--test-dir", $buildDirectory, "--output-on-failure", "-C", $configuration)
if ($null -ne $regex) {
    $testArguments += @("-R", $regex)
}
$testResult = Invoke-Captured $ctest.Source $testArguments "CTest $Suite suite" -StreamOutput
$stopwatch.Stop()

$failedCount = 0
$summaryMatch = $testResult.Output -join "`n" -match "(?m)(\d+)\s+tests?\s+failed\s+out\s+of\s+(\d+)"
if ($summaryMatch) {
    $failedCount = [int]$Matches[1]
}
$selectedCount = $discoveredTests.Count
$passedCount = if ($testResult.ExitCode -eq 0) { $selectedCount } else { [Math]::Max(0, $selectedCount - $failedCount) }

if ($testResult.ExitCode -ne 0) {
    Write-BoundedFailure $testResult.Output
    [Console]::Error.WriteLine(
        "FAIL suite=$Suite configuration=$configuration selected=$selectedCount passed=$passedCount failed=$([Math]::Max(1, $failedCount)) elapsed=$('{0:N2}' -f $stopwatch.Elapsed.TotalSeconds)s"
    )
    exit $testResult.ExitCode
}

Write-Output "PASS suite=$Suite configuration=$configuration selected=$selectedCount passed=$passedCount failed=0 elapsed=$('{0:N2}' -f $stopwatch.Elapsed.TotalSeconds)s build=$([System.IO.Path]::GetFullPath($buildDirectory))"

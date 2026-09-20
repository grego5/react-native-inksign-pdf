[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Output,
    [int]$Duration = 20,
    [string]$Device,
    [switch]$StartEmulator,
    [string]$AvdName = "Pixel_7_Pro_API_33",
    [switch]$ProfileAllocations,
    [ValidateSet("json", "markdown", "both")]
    [string]$Format = "json",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "capture-trace.helpers.ps1")

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$defaultOutputUsed = [string]::IsNullOrWhiteSpace($Output)
if ($defaultOutputUsed) {
    $Output = Get-DefaultTraceOutput $repositoryRoot
}
$targetPackage = "com.margelo.nitro.inksignpdf.example"
$progressIntervalSeconds = 15
$progressPollIntervalSeconds = 1
$durationToleranceSeconds = 5
$emulatorBootTimeoutSeconds = 120
$firstFailureCode = $null
$failureMessage = $null
$adbPath = $null
$selectedDevice = $null
$remoteTrace = $null
$temporaryTrace = $null
$temporaryJson = $null
$temporaryMarkdown = $null
$emulatorProcess = $null

function Set-FirstFailure([int]$Code) {
    if ($null -eq $script:firstFailureCode) {
        $script:firstFailureCode = $Code
    }
}

function Stop-Capture([string]$Message, [int]$Code = 2) {
    Set-FirstFailure $Code
    throw $Message
}

function ConvertTo-ProcessArgument([string]$Argument) {
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }
    return '"' + $Argument.Replace('"', '\"') + '"'
}

function Invoke-Captured([string]$Command, [string[]]$Arguments, [string]$Label, [string]$StandardInput = $null) {
    $startTime = [DateTime]::UtcNow
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Command
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $null -ne $StandardInput
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
        Set-FirstFailure 1
        $startError = $_.Exception.Message
        $elevationHint = if ($startError -match '(?i)access is denied|permission') {
            " Try again from an elevated PowerShell window (Run as administrator)."
        } else {
            ""
        }
        throw "could not start $Label with '$Command': $startError$elevationHint"
    }

    if ($null -ne $StandardInput) {
        $process.StandardInput.Write($StandardInput)
        $process.StandardInput.Close()
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
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{
        Stdout = $stdout
        Stderr = $stderr
        ExitCode = $exitCode
        StartedAt = $startTime
    }
}

function Write-BoundedFailure([string]$Stdout, [string]$Stderr) {
    $combined = @()
    if (-not [string]::IsNullOrWhiteSpace($Stdout)) {
        $combined += @($Stdout -split "`r?`n")
    }
    if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
        $combined += @($Stderr -split "`r?`n")
    }
    $lines = @($combined | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $start = [Math]::Max(0, $lines.Count - 80)
    $count = [Math]::Min(80, $lines.Count - $start)
    if ($count -gt 0) {
        $lines[$start..($start + $count - 1)] | ForEach-Object {
            [Console]::Error.WriteLine([string]$_)
        }
    }
}

function Assert-ProcessSucceeded([pscustomobject]$Result, [string]$Label) {
    if ($Result.ExitCode -eq 0) {
        return
    }
    Set-FirstFailure $Result.ExitCode
    Write-BoundedFailure $Result.Stdout $Result.Stderr
    throw "$Label failed with exit code $($Result.ExitCode)"
}

function Get-SdkRoots {
    $roots = @()
    foreach ($value in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $roots += $value
        }
    }
    foreach ($localProperties in @(
            (Join-Path $repositoryRoot "example\android\local.properties"),
            (Join-Path $repositoryRoot "local.properties"))) {
        if (Test-Path -LiteralPath $localProperties -PathType Leaf) {
            $sdkLine = Get-Content -LiteralPath $localProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
            if ($null -ne $sdkLine) {
                $roots += ($sdkLine -replace '^sdk\.dir=', '').Replace('\\', '\')
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $roots += Join-Path $env:LOCALAPPDATA "Android\Sdk"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $roots += Join-Path $env:USERPROFILE "AppData\Local\Android\Sdk"
    }
    return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Get-AdbPath {
    $pathCommand = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pathCommand -and (Test-Path -LiteralPath $pathCommand.Source -PathType Leaf)) {
        return $pathCommand.Source
    }
    foreach ($sdkRoot in Get-SdkRoots) {
        foreach ($name in @("adb.exe", "adb")) {
            $candidate = Join-Path $sdkRoot "platform-tools\$name"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    Stop-Capture (
        "adb was not found on PATH or under the configured Android SDK roots. " +
        "Install Android SDK Platform-Tools or set ANDROID_HOME/ANDROID_SDK_ROOT; " +
        "if adb exists but is permission-restricted, try again from an elevated PowerShell window (Run as administrator)."
    )
}

function Get-EmulatorPath {
    foreach ($sdkRoot in Get-SdkRoots) {
        foreach ($name in @("emulator.exe", "emulator")) {
            $candidate = Join-Path $sdkRoot "emulator\$name"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }
    Stop-Capture (
        "Android emulator was not found under the configured Android SDK roots. " +
        "Install the Emulator package or set ANDROID_HOME/ANDROID_SDK_ROOT."
    )
}

function Start-ConfiguredEmulator([string]$Name) {
    $emulatorPath = Get-EmulatorPath
    $emulatorArguments = @(
        "-avd", $Name,
        "-accel", "on",
        "-no-boot-anim",
        "-no-snapshot"
    )
    try {
        return Start-Process -FilePath $emulatorPath -ArgumentList $emulatorArguments `
            -WorkingDirectory (Split-Path -Parent $emulatorPath) -WindowStyle Hidden -PassThru
    } catch {
        $startError = $_.Exception.Message
        $elevationHint = if ($startError -match '(?i)access is denied|permission') {
            " Try again from an elevated PowerShell window (Run as administrator)."
        } else {
            ""
        }
        Stop-Capture "could not start Android emulator '$Name' at '$emulatorPath': $startError$elevationHint"
    }
}

function Wait-ForEmulatorDevice([string]$Adb, [string]$RequestedDevice, [System.Diagnostics.Process]$EmulatorProcess) {
    $startedAt = [DateTime]::UtcNow
    $lastDevices = @()
    while (([DateTime]::UtcNow - $startedAt).TotalSeconds -lt $emulatorBootTimeoutSeconds) {
        if ($EmulatorProcess.HasExited) {
            Stop-Capture "Android emulator exited before becoming ready (exit=$($EmulatorProcess.ExitCode))"
        }
        $devicesResult = Invoke-Captured $Adb @("devices") "ADB device discovery during emulator boot"
        Assert-ProcessSucceeded $devicesResult "ADB device discovery during emulator boot"
        $lastDevices = @(ConvertFrom-AdbDevicesOutput ($devicesResult.Stdout -split "`r?`n"))
        if ($lastDevices.Count -gt 1) {
            Stop-Capture "an explicit -Device is required when multiple devices are observed during emulator boot; devices: $(Format-AdbDeviceList $lastDevices)"
        }
        if ($lastDevices.Count -eq 1) {
            if (-not [string]::IsNullOrWhiteSpace($RequestedDevice) -and
                $lastDevices[0].Serial -ne $RequestedDevice) {
                Stop-Capture "requested device '$RequestedDevice' was not observed after starting AVD '$AvdName'; devices: $(Format-AdbDeviceList $lastDevices)"
            }
            if ($lastDevices[0].State -eq "device") {
                return $lastDevices[0]
            }
        }
        $elapsed = ([DateTime]::UtcNow - $startedAt).TotalSeconds
        [Console]::Error.WriteLine(
            "RUN Android emulator still booting elapsed=$('{0:N0}' -f $elapsed)s state=$(Format-AdbDeviceList $lastDevices)"
        )
        Start-Sleep -Seconds 2
    }
    Stop-Capture (
        "Android emulator '$AvdName' did not become ready within ${emulatorBootTimeoutSeconds}s; " +
        "devices: $(Format-AdbDeviceList $lastDevices)"
    )
}

function Get-JsonMetric([object[]]$Metrics, [string]$Section, [string]$Metric, [string]$Scope) {
    return @($Metrics | Where-Object {
        $_.section -eq $Section -and $_.metric -eq $Metric -and $_.scope -eq $Scope
    }) | Select-Object -First 1
}

function Assert-TraceAnalysis([string]$JsonPath, [int]$RequestedDuration) {
    try {
        $payload = Get-Content -Raw -LiteralPath $JsonPath | ConvertFrom-Json
    } catch {
        Stop-Capture "analyzer JSON is malformed: $($_.Exception.Message)"
    }
    if ($null -eq $payload.metrics) {
        Stop-Capture "analyzer JSON does not contain metrics"
    }
    $metrics = @($payload.metrics)
    $durationMetric = Get-JsonMetric $metrics "trace" "duration" "trace"
    if ($null -eq $durationMetric -or $null -eq $durationMetric.value) {
        Stop-Capture "trace analysis did not report a measured duration"
    }
    $measuredDuration = [double]$durationMetric.value
    if ([Math]::Abs($measuredDuration - $RequestedDuration) -gt $durationToleranceSeconds) {
        Stop-Capture (
            "trace duration {0:N3}s is outside requested {1}s ± {2}s" -f
            $measuredDuration, $RequestedDuration, $durationToleranceSeconds
        )
    }

    $requiredGeometry = @(
        @{ Section = "native_timing"; Metric = "average"; Scope = "cpp_geometry" },
        @{ Section = "hot_paths"; Metric = "average"; Scope = "geometry" },
        @{ Section = "hot_paths"; Metric = "average"; Scope = "brush_tip_generation" },
        @{ Section = "hot_paths"; Metric = "average"; Scope = "upstream_extrusion" },
        @{ Section = "hot_paths"; Metric = "average"; Scope = "contour_publication" }
    )
    $missingGeometry = @($requiredGeometry | Where-Object {
        $metric = Get-JsonMetric $metrics $_.Section $_.Metric $_.Scope
        $null -eq $metric -or $null -eq $metric.value
    } | ForEach-Object { "$($_.Section)/$($_.Metric)/$($_.Scope)" })
    if ($missingGeometry.Count -gt 0) {
        Stop-Capture "missing geometry spans: $($missingGeometry -join ', ')"
    }
    $allocationMetric = Get-JsonMetric $metrics "allocation" "heap_profile_available" "target_process"
    $allocationAvailable = $null -ne $allocationMetric -and $allocationMetric.value -eq 1
    return [pscustomobject]@{
        MeasuredDuration = $measuredDuration
        MissingGeometry = @()
        AllocationProfileAvailable = $allocationAvailable
    }
}

try {
    if ($Duration -le 0 -or $Duration -gt 3600) {
        Stop-Capture "Duration must be between 1 and 3600 seconds"
    }
    $outputPath = [System.IO.Path]::GetFullPath($Output)
    $outputParent = Split-Path -Parent $outputPath
    if ([string]::IsNullOrWhiteSpace($outputParent)) {
        $outputParent = (Get-Location).Path
    }
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $outputParent -Force)
    }
    $reportPaths = Get-TraceReportPaths $outputPath
    $destinations = @($reportPaths.Trace, $reportPaths.Json)
    if ($Format -in @("markdown", "both")) {
        $destinations += $reportPaths.Markdown
    }
    foreach ($destination in $destinations) {
        if (Test-Path -LiteralPath $destination) {
            if (-not $Force) {
                Stop-Capture "refusing to overwrite existing output: $destination (use -Force explicitly)"
            }
            if ((Get-Item -LiteralPath $destination).PSIsContainer) {
                Stop-Capture "output destination is a directory: $destination"
            }
        }
    }

    $adbPath = Get-AdbPath
    $devicesResult = Invoke-Captured $adbPath @("devices") "ADB device discovery"
    Assert-ProcessSucceeded $devicesResult "ADB device discovery"
    $devices = @(ConvertFrom-AdbDevicesOutput ($devicesResult.Stdout -split "`r?`n"))
    if ($devices.Count -eq 0 -and $StartEmulator) {
        $emulatorProcess = Start-ConfiguredEmulator $AvdName
        $selectedDevice = Wait-ForEmulatorDevice $adbPath $Device $emulatorProcess
    } else {
        try {
            $selectedDevice = Select-AdbDevice $devices $Device
        } catch {
            $message = $_.Exception.Message
            if ($devices.Count -eq 0) {
                $message += " Use -StartEmulator to boot AVD '$AvdName', or connect a device."
            }
            Stop-Capture $message
        }
    }

    $captureId = [Guid]::NewGuid().ToString("N")
    $remoteTrace = "/data/misc/perfetto-traces/inksign-capture-$PID-$captureId.perfetto-trace"
    $temporaryTrace = Join-Path $outputParent ("." + [System.IO.Path]::GetFileName($outputPath) + "." + $captureId + ".tmp")
    $temporaryJson = Join-Path $outputParent ("." + [System.IO.Path]::GetFileName($reportPaths.Json) + "." + $captureId + ".tmp")
    if ($Format -in @("markdown", "both")) {
        $temporaryMarkdown = Join-Path $outputParent ("." + [System.IO.Path]::GetFileName($reportPaths.Markdown) + "." + $captureId + ".tmp")
    }

    if ($ProfileAllocations) {
        $perfettoArguments = @(
            "-s", $selectedDevice.Serial, "shell", "perfetto",
            "--txt", "-c", "-", "-o", $remoteTrace
        )
        $perfettoConfig = New-PerfettoAllocationConfig $Duration $targetPackage
        $captureResult = Invoke-Captured $adbPath $perfettoArguments "Perfetto allocation capture ($($selectedDevice.Serial))" $perfettoConfig
    } else {
        $perfettoArguments = @(
            "-s", $selectedDevice.Serial, "shell", "perfetto",
            "-o", $remoteTrace,
            "-t", "${Duration}s",
            "-b", "64mb",
            "-a", $targetPackage,
            "sched", "freq", "idle", "am", "wm", "gfx", "view", "input", "binder_driver", "dalvik"
        )
        $captureResult = Invoke-Captured $adbPath $perfettoArguments "Perfetto capture ($($selectedDevice.Serial))"
    }
    Assert-ProcessSucceeded $captureResult "Perfetto capture"
    [Console]::Error.WriteLine("DONE Perfetto recording; starting trace pull and report processing")

    $pullResult = Invoke-Captured $adbPath @("-s", $selectedDevice.Serial, "pull", $remoteTrace, $temporaryTrace) "Perfetto trace pull"
    Assert-ProcessSucceeded $pullResult "Perfetto trace pull"
    if (-not (Test-Path -LiteralPath $temporaryTrace -PathType Leaf)) {
        Stop-Capture "ADB pull completed without creating a local trace"
    }
    $traceInfo = Get-Item -LiteralPath $temporaryTrace
    if ($traceInfo.Length -le 0) {
        Stop-Capture "pulled trace is empty"
    }

    $pythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $pythonCommand) {
        Stop-Capture "python was not found on PATH for trace analysis"
    }
    $analyzer = Join-Path $repositoryRoot "tools\analyze-trace.py"
    $jsonResult = Invoke-Captured $pythonCommand.Source @($analyzer, $temporaryTrace, "--format", "json") "trace JSON analysis"
    Assert-ProcessSucceeded $jsonResult "trace JSON analysis"
    if ([string]::IsNullOrWhiteSpace($jsonResult.Stdout)) {
        Stop-Capture "trace JSON analysis returned no report"
    }
    [System.IO.File]::WriteAllText($temporaryJson, $jsonResult.Stdout, (New-Object System.Text.UTF8Encoding($false)))
    $analysis = Assert-TraceAnalysis $temporaryJson $Duration

    if ($Format -in @("markdown", "both")) {
        $markdownResult = Invoke-Captured $pythonCommand.Source @($analyzer, $temporaryTrace, "--format", "markdown") "trace Markdown analysis"
        Assert-ProcessSucceeded $markdownResult "trace Markdown analysis"
        if ([string]::IsNullOrWhiteSpace($markdownResult.Stdout)) {
            Stop-Capture "trace Markdown analysis returned no report"
        }
        [System.IO.File]::WriteAllText($temporaryMarkdown, $markdownResult.Stdout, (New-Object System.Text.UTF8Encoding($false)))
    }

    Move-Item -LiteralPath $temporaryTrace -Destination $reportPaths.Trace -Force:$Force
    $temporaryTrace = $null
    if ($Format -in @("json", "both")) {
        Move-Item -LiteralPath $temporaryJson -Destination $reportPaths.Json -Force:$Force
        $temporaryJson = $null
    } else {
        Remove-Item -LiteralPath $temporaryJson -Force
        $temporaryJson = $null
    }
    if ($Format -in @("markdown", "both")) {
        Move-Item -LiteralPath $temporaryMarkdown -Destination $reportPaths.Markdown -Force:$Force
        $temporaryMarkdown = $null
    }

    $traceSize = (Get-Item -LiteralPath $reportPaths.Trace).Length
    $outputMode = if ($defaultOutputUsed) { "default_timestamped" } else { "explicit" }
    $allocationMode = if (-not $ProfileAllocations) {
        "not_requested"
    } elseif ($analysis.AllocationProfileAvailable) {
        "available"
    } else {
        "unavailable"
    }
    if ($ProfileAllocations -and -not $analysis.AllocationProfileAvailable) {
        Write-Warning "Perfetto completed, but no heap-profile samples were present; allocation metrics remain unavailable."
    }
    $jsonOutput = if ($Format -in @("json", "both")) { $reportPaths.Json } else { "none" }
    $markdownOutput = if ($Format -in @("markdown", "both")) { $reportPaths.Markdown } else { "none" }
    Write-Output (
        "PASS serial={0} output={1} output_mode={2} format={3} allocation_profile={4} size={5} bytes duration={6:N3}s json={7} markdown={8} missing_geometry_spans=none" -f
        $selectedDevice.Serial, $reportPaths.Trace, $outputMode, $Format, $allocationMode, $traceSize,
        $analysis.MeasuredDuration, $jsonOutput, $markdownOutput
    )
} catch {
    $failureMessage = $_.Exception.Message
} finally {
    if ($null -ne $remoteTrace -and $null -ne $selectedDevice -and $null -ne $adbPath) {
        try {
            $cleanupResult = Invoke-Captured $adbPath @("-s", $selectedDevice.Serial, "shell", "rm", "-f", $remoteTrace) "Perfetto remote cleanup"
            if ($cleanupResult.ExitCode -ne 0) {
                Set-FirstFailure $cleanupResult.ExitCode
                if ([string]::IsNullOrWhiteSpace($failureMessage)) {
                    $failureMessage = "Perfetto remote cleanup failed with exit code $($cleanupResult.ExitCode)"
                }
            }
        } catch {
            Set-FirstFailure 1
            if ([string]::IsNullOrWhiteSpace($failureMessage)) {
                $failureMessage = $_.Exception.Message
            }
        }
    }
    foreach ($temporaryPath in @($temporaryTrace, $temporaryJson, $temporaryMarkdown)) {
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
    [Console]::Error.WriteLine("FAIL: $failureMessage")
    if ($null -eq $firstFailureCode) {
        $firstFailureCode = 1
    }
    exit $firstFailureCode
}

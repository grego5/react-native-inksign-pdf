[CmdletBinding()]
param(
    [string]$Manifest,
    [string]$Executable,
    [ValidateSet("debug", "release")]
    [string]$Config = "debug",
    [switch]$GenerateBaseline,
    [string]$BaselineOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$defaultManifest = Join-Path $PSScriptRoot "testdata\geometry-contract-manifest.json"
$defaultBaselineOutput = Join-Path $PSScriptRoot "geometry-contract-manifest.candidate.json"
if ([string]::IsNullOrWhiteSpace($Manifest)) {
    $Manifest = $defaultManifest
}
if ([string]::IsNullOrWhiteSpace($BaselineOutput)) {
    $BaselineOutput = $defaultBaselineOutput
}
$progressIntervalSeconds = 15
$progressPollIntervalSeconds = 1

function Stop-ContractCheck([string]$Message, [int]$Code = 2) {
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
            [void]$startInfo.ArgumentList.Add($argument)
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
    } catch [System.ComponentModel.Win32Exception] {
        Stop-ContractCheck "could not start $Label '$Command': $($_.Exception.Message). If access is restricted, retry from an elevated PowerShell window (Run as administrator)" 2
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $lastProgressTime = $startTime
    while (-not $process.HasExited) {
        Start-Sleep -Seconds $progressPollIntervalSeconds
        $now = [DateTime]::UtcNow
        if (($now - $lastProgressTime).TotalSeconds -ge $progressIntervalSeconds -and
            -not $process.HasExited) {
            [Console]::Error.WriteLine(
                "RUN $Label still running elapsed=$('{0:N0}' -f ($now - $startTime).TotalSeconds)s"
            )
            $lastProgressTime = $now
        }
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    [pscustomobject]@{
        Stdout = $stdout
        Stderr = $stderr
        ExitCode = $exitCode
    }
}

function Resolve-RepositoryPath([string]$Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $Path))
}

function Resolve-Executable {
    if (-not [string]::IsNullOrWhiteSpace($Executable)) {
        $candidate = Resolve-RepositoryPath $Executable
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            Stop-ContractCheck "ink_engine_cli executable not found at $candidate; build the native CLI first" 2
        }
        return $candidate
    }
    $executableName = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        "ink_engine_cli.exe"
    } else {
        "ink_engine_cli"
    }
    $buildDirectory = if ($Config -eq "release") { "startup-release" } else { "startup-debug" }
    $candidates = @(
        (Join-Path $repositoryRoot (Join-Path "build\$buildDirectory" $executableName)),
        (Join-Path $repositoryRoot (Join-Path "build\startup-release" $executableName)),
        (Join-Path $repositoryRoot (Join-Path "build" $executableName))
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    Stop-ContractCheck "ink_engine_cli was not found; build it with: cmake --build build\$buildDirectory --target ink_engine_cli --config $(if ($Config -eq 'release') { 'Release' } else { 'Debug' })" 2
}

function Read-Manifest([string]$Path) {
    $resolved = Resolve-RepositoryPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        Stop-ContractCheck "geometry contract manifest not found at $resolved" 2
    }
    try {
        $document = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    } catch {
        Stop-ContractCheck "malformed geometry contract manifest '$resolved': $($_.Exception.Message)" 2
    }
    if ($null -eq $document -or $document.version -ne 1 -or $null -eq $document.fixtures) {
        Stop-ContractCheck "geometry contract manifest must contain version=1 and fixtures" 2
    }
    return $document
}

function Parse-Summary([string]$Text) {
    $summaryPattern = '^PASS name=(?<name>\S+) operations=(?<operations>\d+) strokes=(?<strokes>\d+) outline_segments=(?<outline_segments>\d+) contours=(?<contours>\d+) max_chord=(?<max_chord>[-+0-9.eE]+) serialized_frame_bytes=(?<serialized_frame_bytes>\d+) transport_hash=(?<transport_hash>0x[0-9a-fA-F]+) geometry_unsupported=(?<geometry_unsupported>\d+)$'
    $summaryLines = @(
        $Text -split "`r?`n" | Where-Object {
            $_ -match $summaryPattern
        }
    )
    if ($summaryLines.Count -ne 1) {
        return $null
    }
    $summaryMatch = [regex]::Match([string]$summaryLines[0], $summaryPattern)
    if (-not $summaryMatch.Success) {
        return $null
    }
    try {
        [pscustomobject]@{
            Name = $summaryMatch.Groups['name'].Value
            Operations = [int64]$summaryMatch.Groups['operations'].Value
            Strokes = [int64]$summaryMatch.Groups['strokes'].Value
            OutlineSegments = [int64]$summaryMatch.Groups['outline_segments'].Value
            Contours = [int64]$summaryMatch.Groups['contours'].Value
            MaxChord = [double]::Parse($summaryMatch.Groups['max_chord'].Value, [Globalization.CultureInfo]::InvariantCulture)
            SerializedFrameBytes = [int64]$summaryMatch.Groups['serialized_frame_bytes'].Value
            TransportHash = $summaryMatch.Groups['transport_hash'].Value.ToLowerInvariant()
        }
    } catch {
        return $null
    }
}

function New-ContractEntry([object]$Summary) {
    [pscustomobject]@{
        name = $Summary.Name
        outline_segments = [pscustomobject]@{
            min = $Summary.OutlineSegments
            max = $Summary.OutlineSegments
        }
        chord_length_ceiling = $Summary.MaxChord
        contour_count = $Summary.Contours
        serialized_frame_bytes = $Summary.SerializedFrameBytes
        transport_hash = $Summary.TransportHash
    }
}

$executablePath = Resolve-Executable
$cliConfig = if ($Config -eq "release") { "Release" } else { "Debug" }

if ($GenerateBaseline) {
    $candidatePath = Resolve-RepositoryPath $BaselineOutput
    $manifestPath = Resolve-RepositoryPath $Manifest
    if ($candidatePath -eq $manifestPath) {
        Stop-ContractCheck "baseline output must not overwrite the tracked manifest" 2
    }
    $result = Invoke-Captured $executablePath @("--all", "--invariants-only", "--summary") "geometry baseline"
    $combinedOutput = $result.Stdout + $result.Stderr
    if ($result.ExitCode -ne 0) {
        [Console]::Error.WriteLine($combinedOutput.Trim())
        Stop-ContractCheck "geometry baseline CLI failed with exit code $($result.ExitCode)" 1
    }
    $summaries = @($combinedOutput -split "`r?`n" | ForEach-Object {
        if ($_ -match '^PASS name=') { Parse-Summary ([string]$_) }
    } | Where-Object { $null -ne $_ })
    if ($summaries.Count -eq 0) {
        Stop-ContractCheck "geometry baseline CLI returned no machine-stable summaries" 2
    }
    $document = [pscustomobject]@{
        version = 1
        contract = "stroke replay geometry and canonical frame transport"
        fixtures = @($summaries | ForEach-Object { New-ContractEntry $_ })
    }
    $parent = Split-Path -Parent $candidatePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $document | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $candidatePath -Encoding UTF8
    Write-Output "PASS baseline_candidate=$candidatePath fixtures=$($summaries.Count) executable=$executablePath config=$cliConfig"
    exit 0
}

$document = Read-Manifest $Manifest
$fixtures = @($document.fixtures)
if ($fixtures.Count -eq 0) {
    Stop-ContractCheck "geometry contract manifest contains no fixtures" 2
}

$failedFixtures = 0
foreach ($fixture in $fixtures) {
    if ([string]::IsNullOrWhiteSpace([string]$fixture.name) -or
        $null -eq $fixture.outline_segments -or
        $null -eq $fixture.chord_length_ceiling -or
        $null -eq $fixture.contour_count -or
        $null -eq $fixture.serialized_frame_bytes -or
        [string]::IsNullOrWhiteSpace([string]$fixture.transport_hash)) {
        Stop-ContractCheck "malformed contract entry" 2
    }
    $result = Invoke-Captured $executablePath @(
        "--fixture", [string]$fixture.name,
        "--invariants-only", "--summary"
    ) "geometry fixture $($fixture.name)"
    $summary = Parse-Summary ($result.Stdout + $result.Stderr)
    $mismatch = $null
    if ($result.ExitCode -ne 0) {
        $mismatch = "CLI failed with exit code $($result.ExitCode)"
    } elseif ($null -eq $summary) {
        $mismatch = "malformed or missing machine-stable summary"
    } elseif ($summary.Name -ne [string]$fixture.name) {
        $mismatch = "expected fixture name '$($fixture.name)', actual '$($summary.Name)'"
    } else {
        $minSegments = [int64]$fixture.outline_segments.min
        $maxSegments = [int64]$fixture.outline_segments.max
        $ceiling = [double]::Parse([string]$fixture.chord_length_ceiling, [Globalization.CultureInfo]::InvariantCulture)
        $expectedHash = ([string]$fixture.transport_hash).ToLowerInvariant()
        if ($summary.OutlineSegments -lt $minSegments -or $summary.OutlineSegments -gt $maxSegments) {
            $mismatch = "outline_segments expected [$minSegments,$maxSegments], actual $($summary.OutlineSegments)"
        } elseif ($summary.MaxChord -gt $ceiling + 1e-9) {
            $mismatch = "max_chord expected <= $ceiling, actual $($summary.MaxChord)"
        } elseif ($summary.Contours -ne [int64]$fixture.contour_count) {
            $mismatch = "contour_count expected $($fixture.contour_count), actual $($summary.Contours)"
        } elseif ($summary.SerializedFrameBytes -ne [int64]$fixture.serialized_frame_bytes) {
            $mismatch = "serialized_frame_bytes expected $($fixture.serialized_frame_bytes), actual $($summary.SerializedFrameBytes)"
        } elseif ($summary.TransportHash -ne $expectedHash) {
            $mismatch = "transport_hash expected $expectedHash, actual $($summary.TransportHash)"
        }
    }
    if ($null -ne $mismatch) {
        ++$failedFixtures
        [Console]::Error.WriteLine("FAIL fixture=$($fixture.name) $mismatch")
    } else {
        Write-Output "PASS fixture=$($fixture.name) outline_segments=$($summary.OutlineSegments) contours=$($summary.Contours) serialized_frame_bytes=$($summary.SerializedFrameBytes) transport_hash=$($summary.TransportHash)"
    }
}

if ($failedFixtures -ne 0) {
    [Console]::Error.WriteLine("FAIL fixtures_failed=$failedFixtures fixtures_checked=$($fixtures.Count)")
    exit 1
}
Write-Output "PASS fixtures_failed=0 fixtures_checked=$($fixtures.Count) executable=$executablePath config=$cliConfig"

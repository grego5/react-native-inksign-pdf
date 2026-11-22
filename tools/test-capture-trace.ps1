[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "capture-trace.helpers.ps1")

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message (actual=$Actual expected=$Expected)"
    }
}

function Assert-Throws([scriptblock]$Action, [string]$ExpectedText, [string]$Message) {
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike "*$ExpectedText*") {
            throw "$Message (unexpected error: $($_.Exception.Message))"
        }
        return
    }
    throw "$Message (no error)"
}

$zero = @(ConvertFrom-AdbDevicesOutput @("List of devices attached", ""))
Assert-Equal $zero.Count 0 "zero-device parsing"

$one = @(ConvertFrom-AdbDevicesOutput @("List of devices attached", "emulator-5554 device"))
Assert-Equal $one.Count 1 "one-device parsing count"
Assert-Equal $one[0].Serial "emulator-5554" "one-device serial"
Assert-Equal (Select-AdbDevice $one $null).Serial "emulator-5554" "one-device selection"

$multiple = @(ConvertFrom-AdbDevicesOutput @("a device", "b device"))
Assert-Throws { Select-AdbDevice $multiple $null } "explicit -Device" "multiple-device rejection"

$offline = @(ConvertFrom-AdbDevicesOutput @("a offline"))
Assert-Throws { Select-AdbDevice $offline $null } "not ready" "offline-device rejection"

$unauthorized = @(ConvertFrom-AdbDevicesOutput @("a unauthorized"))
Assert-Throws { Select-AdbDevice $unauthorized $null } "not ready" "unauthorized-device rejection"

Assert-Throws { Select-AdbDevice $one "missing" } "not observed" "unknown-serial rejection"

$defaultOutput = Get-DefaultTraceOutput "repo" ([datetime]::Parse("2026-09-05T14:30:45"))
Assert-Equal $defaultOutput "repo\diagnostics\traces\capture-2026-09-05_14-30-45.perfetto-trace" "timestamped default output"

$allocationConfig = New-PerfettoAllocationConfig 20 "com.margelo.nitro.inksignpdf.example"
if ($allocationConfig -notmatch 'name: "android\.heapprofd"' -or
    $allocationConfig -notmatch 'target_buffer: 0' -or
    $allocationConfig -notmatch 'process_cmdline: "com\.margelo\.nitro\.inksignpdf\.example"' -or
    $allocationConfig -notmatch 'atrace_categories: "dalvik"' -or
    $allocationConfig -notmatch 'duration_ms: 20000') {
    throw "allocation profiling config does not contain the required Perfetto sources"
}

Write-Output "PASS capture-trace helper parsing"

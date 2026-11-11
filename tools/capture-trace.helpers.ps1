Set-StrictMode -Version Latest

function ConvertFrom-AdbDevicesOutput([string[]]$Lines) {
    $devices = @()
    foreach ($line in $Lines) {
        $text = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "List of devices attached" -or $text.StartsWith("*")) {
            continue
        }
        $parts = $text -split '\s+'
        if ($parts.Count -ge 2) {
            $devices += [pscustomobject]@{
                Serial = $parts[0]
                State = $parts[1]
            }
        }
    }
    return $devices
}

function Format-AdbDeviceList([object[]]$Devices) {
    if ($null -eq $Devices -or $Devices.Count -eq 0) {
        return "none"
    }
    return (($Devices | ForEach-Object { "$($_.Serial)=$($_.State)" }) -join ", ")
}

function Select-AdbDevice([object[]]$Devices, [string]$Device) {
    $records = @($Devices)
    if (-not [string]::IsNullOrWhiteSpace($Device)) {
        $selected = @($records | Where-Object { $_.Serial -eq $Device })
        if ($selected.Count -eq 0) {
            throw "requested device '$Device' was not observed; devices: $(Format-AdbDeviceList $records)"
        }
        if ($selected.Count -gt 1) {
            throw "requested device '$Device' appeared multiple times; devices: $(Format-AdbDeviceList $records)"
        }
        if ($selected[0].State -ne "device") {
            throw "requested device '$Device' is not ready (state=$($selected[0].State)); devices: $(Format-AdbDeviceList $records)"
        }
        return $selected[0]
    }

    if ($records.Count -eq 0) {
        throw "no Android devices were observed; devices: none"
    }
    if ($records.Count -ne 1) {
        throw "an explicit -Device is required when multiple devices are observed; devices: $(Format-AdbDeviceList $records)"
    }
    if ($records[0].State -ne "device") {
        throw "the only observed device is not ready (state=$($records[0].State)); devices: $(Format-AdbDeviceList $records)"
    }
    return $records[0]
}

function Get-TraceReportPaths([string]$TracePath) {
    return [pscustomobject]@{
        Trace = $TracePath
        Json = [System.IO.Path]::ChangeExtension($TracePath, ".json")
        Markdown = [System.IO.Path]::ChangeExtension($TracePath, ".md")
    }
}

function Get-DefaultTraceOutput([string]$RepositoryRoot, [datetime]$Now = (Get-Date)) {
    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        throw "a repository root is required for the default trace output"
    }
    $fileName = "capture-{0}.perfetto-trace" -f $Now.ToString("yyyy-MM-dd_HH-mm-ss")
    return Join-Path $RepositoryRoot (Join-Path "diagnostics\traces" $fileName)
}

function New-PerfettoAllocationConfig([int]$DurationSeconds, [string]$PackageName) {
    if ($DurationSeconds -le 0) {
        throw "Perfetto duration must be positive"
    }
    if ([string]::IsNullOrWhiteSpace($PackageName)) {
        throw "Perfetto allocation profiling requires an application package"
    }

    $durationMilliseconds = $DurationSeconds * 1000
    return @"
buffers { size_kb: 65536 fill_policy: RING_BUFFER }
duration_ms: $durationMilliseconds
data_sources {
  config {
    name: "linux.ftrace"
    target_buffer: 0
    ftrace_config {
      atrace_categories: "sched"
      atrace_categories: "freq"
      atrace_categories: "idle"
      atrace_categories: "am"
      atrace_categories: "wm"
      atrace_categories: "gfx"
      atrace_categories: "view"
      atrace_categories: "input"
      atrace_categories: "binder_driver"
      atrace_categories: "dalvik"
      atrace_apps: "$PackageName"
    }
  }
}
data_sources {
  config {
    name: "android.heapprofd"
    target_buffer: 0
    heapprofd_config {
      process_cmdline: "$PackageName"
      sampling_interval_bytes: 4096
      shmem_size_bytes: 8388608
    }
  }
}
"@
}

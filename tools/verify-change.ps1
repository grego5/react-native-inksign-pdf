[CmdletBinding()]
param(
    [switch]$DryRun,
    [string[]]$Paths,
    [string]$Trace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$progressIntervalSeconds = 15
$progressPollIntervalSeconds = 1
$isWindowsHost = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

$checkDefinitions = [ordered]@{
    diff_check = [pscustomobject]@{
        Label = "git diff check"
        Command = "git"
        Arguments = @("diff", "--check", "--", ":!nitrogen/generated/**")
    }
    native_geometry = [pscustomobject]@{
        Label = "native geometry suite"
        Command = "powershell-runner"
        Arguments = @("tools\test-native.ps1", "-Suite", "geometry")
    }
    geometry_contract = [pscustomobject]@{
        Label = "geometry contract"
        Command = "powershell-runner"
        Arguments = @("tools\check-geometry-contract.ps1")
    }
    native_lifecycle = [pscustomobject]@{
        Label = "native lifecycle suite"
        Command = "powershell-runner"
        Arguments = @("tools\test-native.ps1", "-Suite", "lifecycle")
    }
    native_all = [pscustomobject]@{
        Label = "all native tests"
        Command = "powershell-runner"
        Arguments = @("tools\test-native.ps1", "-Suite", "all", "-Build")
    }
    android_jvm = [pscustomobject]@{
        Label = "Android JVM tests"
        Command = "powershell-runner"
        Arguments = @("tools\test-android.ps1", "-Mode", "jvm")
    }
    android_build = [pscustomobject]@{
        Label = "Android debug build"
        Command = "powershell-runner"
        Arguments = @("tools\test-android.ps1", "-Mode", "build")
    }
    ios_lifecycle = [pscustomobject]@{
        Label = "iOS lifecycle/export contract"
        Command = "powershell-runner"
        Arguments = @("tools\test-ios-lifecycle.ps1")
    }
    artifact_parity = [pscustomobject]@{
        Label = "managed artifact parity"
        Command = "powershell-runner"
        Arguments = @("tools\check-managed-artifact-parity.ps1")
    }
    typescript = [pscustomobject]@{
        Label = "TypeScript check"
        Command = "npx"
        Arguments = @("tsc", "--noEmit", "--pretty", "false")
    }
    trace_analysis = [pscustomobject]@{
        Label = "Perfetto analyzer smoke"
        Command = "python"
        Arguments = @()
    }
    tooling_tests = [pscustomobject]@{
        Label = "tooling tests"
        Command = "python"
        Arguments = @("-m", "unittest", "discover", "-s", "tools", "-p", "test_*.py")
    }
    documentation_paths = [pscustomobject]@{
        Label = "documentation path check"
        Command = "internal"
        Arguments = @()
    }
    text_contract = [pscustomobject]@{
        Label = "text annotation test contract"
        Command = "powershell-runner"
        Arguments = @("tools\check-text-test-contract.ps1")
    }
}

$pathRules = @(
    [pscustomobject]@{ Name = "generated"; Pattern = '^nitrogen/generated/'; Checks = @("diff_check"); Area = "generated" },
    [pscustomobject]@{ Name = "native geometry"; Pattern = '^(cpp/upstream/|cpp/replay/|cpp/circular/|cpp/modeling/|cpp/input/|cpp/core/StrokeOutline|cpp/StrokeEngine|cpp/tests/(replay|upstream)/)'; Checks = @("native_geometry", "geometry_contract", "diff_check"); Area = "native-geometry" },
    [pscustomobject]@{ Name = "native C++"; Pattern = '^cpp/'; Checks = @("native_lifecycle", "diff_check"); Area = "native-cpp" },
    [pscustomobject]@{ Name = "Android instrumentation"; Pattern = '^android/src/androidTest/'; Checks = @("android_build", "diff_check"); Area = "android-instrumentation" },
    [pscustomobject]@{ Name = "Android native"; Pattern = '^android/src/(main/cpp|debug|release)/'; Checks = @("android_jvm", "android_build", "diff_check"); Area = "android-native" },
    [pscustomobject]@{ Name = "Android source"; Pattern = '^android/'; Checks = @("android_jvm", "artifact_parity", "diff_check"); Area = "android" },
    [pscustomobject]@{ Name = "Android project"; Pattern = '^(example/android/|android\.gradle$|gradle/|gradlew)'; Checks = @("android_build", "diff_check"); Area = "android-build" },
    [pscustomobject]@{ Name = "iOS source"; Pattern = '^ios/'; Checks = @("ios_lifecycle", "artifact_parity", "diff_check"); Area = "ios" },
    [pscustomobject]@{ Name = "iOS tests"; Pattern = '^ios-tests/'; Checks = @("ios_lifecycle", "diff_check"); Area = "ios" },
    [pscustomobject]@{ Name = "Perfetto tooling"; Pattern = '(^|/)(trace-analysis\.sql|analyze-trace\.py|compare-traces\.py|capture-trace[^/]*\.ps1|InkPerfetto|StrokeTraceRecorder)'; Checks = @("trace_analysis", "diff_check"); Area = "tracing" },
    [pscustomobject]@{ Name = "TypeScript"; Pattern = '(^src/|\.(ts|tsx|mjs)$)'; Checks = @("typescript", "artifact_parity", "diff_check"); Area = "typescript" },
    [pscustomobject]@{ Name = "Build system"; Pattern = '(^|/)(CMakeLists\.txt|.*\.cmake|package\.json|package-lock\.json|nitro\.json)$'; Checks = @("native_all", "android_build", "typescript", "diff_check"); Area = "build-system" },
    [pscustomobject]@{ Name = "Text test contract"; Pattern = '^(tasks/01-text-interaction-contract\.md|tools/check-text-test-contract\.ps1|tools/testdata/text-annotation-boundaries\.json)$'; Checks = @("text_contract", "diff_check"); Area = "text-contract" },
    [pscustomobject]@{ Name = "Tooling"; Pattern = '^tools/'; Checks = @("tooling_tests", "diff_check"); Area = "tooling" },
    [pscustomobject]@{ Name = "Documentation"; Pattern = '(^\.agents/.*\.md$|^Tasks/.*\.md$|(^|/)(README|CHANGELOG|CONTRIBUTING)(\.md)?$|\.md$)'; Checks = @("documentation_paths", "diff_check"); Area = "documentation" }
)

function Stop-Verification([string]$Message, [int]$Code = 2) {
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
        return [pscustomobject]@{ ExitCode = 127; Output = @("could not start $Label`: $($_.Exception.Message)") }
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $lastProgressTime = $startTime
    while (-not $process.HasExited) {
        Start-Sleep -Seconds $progressPollIntervalSeconds
        $now = [DateTime]::UtcNow
        if (($now - $lastProgressTime).TotalSeconds -ge $progressIntervalSeconds -and
            -not $process.HasExited) {
            [Console]::Error.WriteLine("RUN $Label still running elapsed=$('{0:N0}' -f ($now - $startTime).TotalSeconds)s")
            $lastProgressTime = $now
        }
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    $output = @()
    if (-not [string]::IsNullOrEmpty($stdout)) { $output += @($stdout -split "`r?`n") }
    if (-not [string]::IsNullOrEmpty($stderr)) { $output += @($stderr -split "`r?`n") }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-PowerShellCommand {
    if ($isWindowsHost) {
        $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        if ($null -ne $pwsh) { return $pwsh.Source }
        $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if ($null -ne $powershell) { return $powershell.Source }
    }
    return $null
}

function Get-ChangedPaths {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { Stop-Verification "git is not available on PATH" 2 }
    $pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $outputs = @()
    foreach ($arguments in @(
        @("diff", "--name-only", "--diff-filter=ACMR"),
        @("diff", "--cached", "--name-only", "--diff-filter=ACMR"),
        @("ls-files", "--others", "--exclude-standard")
    )) {
        $gitOutput = @(& $git.Source @arguments)
        if ($LASTEXITCODE -ne 0) { Stop-Verification "could not collect changed paths from git" 2 }
        $outputs += $gitOutput
    }
    foreach ($line in $outputs) {
        $normalized = ([string]$line).Trim().Replace('\', '/')
        if (-not [string]::IsNullOrWhiteSpace($normalized)) { [void]$pathSet.Add($normalized) }
    }
    return @($pathSet | Sort-Object)
}

function Resolve-TracePath {
    if (-not [string]::IsNullOrWhiteSpace($Trace)) {
        $candidate = if ([System.IO.Path]::IsPathRooted($Trace)) { $Trace } else { Join-Path $repositoryRoot $Trace }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
        return $null
    }
    $diagnostics = Join-Path $repositoryRoot "diagnostics"
    if (-not (Test-Path -LiteralPath $diagnostics -PathType Container)) { return $null }
    $ignored = @(Get-ChildItem -LiteralPath $diagnostics -File -Filter "*.perfetto-trace" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $null -ne (git check-ignore $_.FullName 2>$null) } |
        Sort-Object LastWriteTime -Descending)
    if ($ignored.Count -eq 0) { return $null }
    return $ignored[0].FullName
}

function Get-Classification([string]$Path) {
    foreach ($rule in $pathRules) {
        if ($Path -match $rule.Pattern) {
            return [pscustomobject]@{ Area = $rule.Area; Rule = $rule.Name; Checks = $rule.Checks }
        }
    }
    if ($Path -match '\.(c|cc|cpp|cxx|h|hpp)$') {
        return [pscustomobject]@{ Area = "unknown-native"; Rule = "unknown C++"; Checks = @("native_all", "diff_check") }
    }
    if ($Path -match '(^|/)android/') {
        return [pscustomobject]@{ Area = "unknown-android"; Rule = "unknown Android"; Checks = @("android_jvm", "android_build", "diff_check") }
    }
    if ($Path -match '\.(ts|tsx|js|jsx)$') {
        return [pscustomobject]@{ Area = "unknown-script"; Rule = "unknown TypeScript/JavaScript"; Checks = @("typescript", "diff_check") }
    }
    return [pscustomobject]@{ Area = "unknown"; Rule = "conservative fallback"; Checks = @("native_all", "android_build", "typescript", "diff_check") }
}

function Get-CommandText([string]$Name, [string[]]$Arguments) {
    $argumentText = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '
    return "$Name $argumentText".Trim()
}

function Test-DocumentationPaths([string[]]$ChangedPaths) {
    foreach ($path in $ChangedPaths) {
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    }
    return $true
}

if (-not $PSBoundParameters.ContainsKey("Paths")) {
    $Paths = Get-ChangedPaths
} else {
    $Paths = @($Paths | ForEach-Object { ([string]$_) -split ';' } |
        ForEach-Object { ([string]$_).Trim().Replace('\', '/') } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

if ($Paths.Count -eq 0) {
    Write-Output "PASS clean-tree selected=0 passed=0 failed=0 skipped=0 unavailable=0"
    exit 0
}

$classifications = @{}
$selectedChecks = New-Object 'System.Collections.Generic.List[string]'
foreach ($path in $Paths) {
    $classification = Get-Classification $path
    $classifications[$path] = $classification
    foreach ($check in $classification.Checks) {
        if (-not $selectedChecks.Contains($check)) { [void]$selectedChecks.Add($check) }
    }
}

$requestedChecks = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($checkName in $selectedChecks) { [void]$requestedChecks.Add($checkName) }
$validationOrder = @(
    "native_geometry", "geometry_contract", "native_lifecycle", "native_all",
    "android_jvm", "android_build", "ios_lifecycle", "artifact_parity", "typescript", "trace_analysis",
    "text_contract", "tooling_tests", "documentation_paths", "diff_check"
)
$selectedChecks = New-Object 'System.Collections.Generic.List[string]'
foreach ($checkName in $validationOrder) {
    if ($requestedChecks.Contains($checkName)) { [void]$selectedChecks.Add($checkName) }
}

Write-Output "CHANGED paths=$($Paths.Count)"
foreach ($path in $Paths) {
    $classification = $classifications[$path]
    Write-Output "AREA path=$path rule=$($classification.Rule) area=$($classification.Area) checks=$($classification.Checks -join ',')"
}

$tracePath = Resolve-TracePath
$traceRequested = $selectedChecks.Contains("trace_analysis")
if ($selectedChecks.Contains("trace_analysis")) {
    if ($null -eq $tracePath) {
        $selectedChecks.Remove("trace_analysis")
        Write-Output "UNAVAILABLE check=trace_analysis reason=no ignored diagnostics/**/*.perfetto-trace found"
    } else {
        $checkDefinitions.trace_analysis.Arguments = @("tools\analyze-trace.py", $tracePath, "--format", "json")
    }
}

$passed = 0
$failed = 0
$skipped = 0
$unavailable = if ($traceRequested -and $null -eq $tracePath) { 1 } else { 0 }
$matrix = @()

foreach ($checkName in $selectedChecks) {
    $definition = $checkDefinitions[$checkName]
    $commandName = $definition.Command
    $arguments = @($definition.Arguments)
    if ($commandName -eq "powershell-runner") {
        $powerShell = Get-PowerShellCommand
        if ($null -eq $powerShell) {
            $matrix += [pscustomobject]@{ Name = $checkName; Status = "unavailable"; Detail = "PowerShell executable not found" }
            ++$unavailable
            continue
        }
        $scriptPath = Join-Path $repositoryRoot $arguments[0]
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scriptPath) + @($arguments | Select-Object -Skip 1)
        $commandName = $powerShell
    } elseif ($commandName -ne "internal") {
        $resolvedCommand = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($null -eq $resolvedCommand) {
            $matrix += [pscustomobject]@{ Name = $checkName; Status = "unavailable"; Detail = "$($definition.Command) not found on PATH" }
            ++$unavailable
            continue
        }
        if ($isWindowsHost -and $resolvedCommand.CommandType -eq "ExternalScript") {
            $nativeCommand = Get-Command ($commandName + ".cmd") -ErrorAction SilentlyContinue
            if ($null -ne $nativeCommand) { $resolvedCommand = $nativeCommand }
        }
        $commandName = $resolvedCommand.Source
    }
    Write-Output "PLAN check=$checkName command=$(Get-CommandText $definition.Command $definition.Arguments)"
    if ($DryRun) {
        $matrix += [pscustomobject]@{ Name = $checkName; Status = "skipped"; Detail = "dry-run" }
        ++$skipped
        continue
    }
    if ($checkName -eq "documentation_paths") {
        $exitCode = if (Test-DocumentationPaths $Paths) { 0 } else { 1 }
        $result = [pscustomobject]@{ ExitCode = $exitCode; Output = @() }
    } else {
        $result = Invoke-Captured $commandName $arguments $definition.Label
    }
    if ($result.ExitCode -ne 0) {
        $failed = 1
        $matrix += [pscustomobject]@{ Name = $checkName; Status = "failed"; Detail = "exit=$($result.ExitCode)" }
        $result.Output | Select-Object -Last 80 | ForEach-Object { [Console]::Error.WriteLine($_) }
        [Console]::Error.WriteLine("FAIL check=$checkName exit=$($result.ExitCode)")
        break
    }
    $matrix += [pscustomobject]@{ Name = $checkName; Status = "passed"; Detail = "exit=0" }
    ++$passed
}

$executedNames = @($matrix | ForEach-Object { $_.Name })
$notRun = @($selectedChecks | Where-Object { $executedNames -notcontains $_ })
foreach ($checkName in $notRun) {
    $matrix += [pscustomobject]@{ Name = $checkName; Status = "not-run"; Detail = "stopped after first failure" }
}

Write-Output "MATRIX"
foreach ($row in $matrix) {
    Write-Output "RESULT check=$($row.Name) status=$($row.Status) detail=$($row.Detail)"
}
$notRunCount = @($matrix | Where-Object { $_.Status -eq "not-run" }).Count
if ($failed -ne 0) {
    [Console]::Error.WriteLine("FAIL selected=$($selectedChecks.Count) passed=$passed failed=1 skipped=$skipped unavailable=$unavailable not_run=$notRunCount")
    exit 1
}
Write-Output "PASS selected=$($selectedChecks.Count) passed=$passed failed=0 skipped=$skipped unavailable=$unavailable not_run=$notRunCount"

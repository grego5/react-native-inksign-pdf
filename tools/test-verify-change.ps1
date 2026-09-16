[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$checker = Join-Path $PSScriptRoot "verify-change.ps1"
$shell = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $shell) { $shell = Get-Command powershell.exe -ErrorAction SilentlyContinue }
if ($null -eq $shell) { throw "PowerShell executable not found" }

function Invoke-Verify([string[]]$Arguments) {
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $checker @Arguments 2>&1)
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    [pscustomobject]@{ Output = ($output -join "`n"); ExitCode = $LASTEXITCODE }
}

function Test-Plan([string]$Name, [string[]]$ChangedPaths, [string[]]$ExpectedChecks) {
    $arguments = @("-DryRun", "-Paths", ($ChangedPaths -join ";"))
    $result = Invoke-Verify $arguments
    if ($result.ExitCode -ne 0) { throw "$Name dry-run failed: $($result.Output)" }
    $actual = @(
        [regex]::Matches($result.Output, '(?m)^RESULT check=([^ ]+) status=skipped') |
            ForEach-Object { $_.Groups[1].Value }
    )
    if (($actual -join ",") -ne ($ExpectedChecks -join ",")) {
        throw "$Name selected [$($actual -join ',')] instead of [$($ExpectedChecks -join ',')]"
    }
    if ($result.Output -match 'documentation_paths' -and
        $ExpectedChecks -notcontains "documentation_paths") {
        throw "$Name was incorrectly classified as documentation-only"
    }
}

Test-Plan "upstream" @("cpp/upstream/UpstreamStrokeGeometry.cpp") @("native_geometry", "geometry_contract", "diff_check")
Test-Plan "Android" @("android/src/main/java/com/example/Ink.kt") @("android_jvm", "artifact_parity", "diff_check")
Test-Plan "iOS" @("ios/PdfView.swift") @("ios_lifecycle", "artifact_parity", "diff_check")
Test-Plan "tracing" @("tools/trace-analysis.sql") @("trace_analysis", "diff_check")
Test-Plan "documentation" @("Tasks/06-changed-area-verification.md") @("documentation_paths", "diff_check")
Test-Plan "mixed" @("android/src/main/java/com/example/Ink.kt", "cpp/upstream/UpstreamStrokeGeometry.cpp") @("native_geometry", "geometry_contract", "android_jvm", "artifact_parity", "diff_check")
Test-Plan "generated" @("nitrogen/generated/shared/c++/HybridPdfViewSpec.hpp") @("diff_check")
Test-Plan "text contract" @("tasks/01-text-interaction-contract.md") @("text_contract", "diff_check")
Test-Plan "unknown" @("unknown.xyz") @("native_all", "android_build", "typescript", "diff_check")

$clean = Invoke-Verify @("-Paths", ";")
if ($clean.ExitCode -ne 0 -or $clean.Output -notmatch "PASS clean-tree selected=0") {
    throw "explicit empty path list was not treated as a clean no-op: $($clean.Output)"
}

$failure = Invoke-Verify @("-Paths", "tools/trace-analysis.sql", "-Trace", ".git/HEAD")
if ($failure.ExitCode -eq 0 -or
    $failure.Output -notmatch "FAIL check=trace_analysis" -or
    $failure.Output -match "RESULT check=diff_check status=(passed|failed|skipped)") {
    throw "a failed check did not stop later checks: $($failure.Output)"
}

Write-Output "PASS changed-area verification tests"

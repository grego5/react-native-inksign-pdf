[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$checker = Join-Path $PSScriptRoot "check-geometry-contract.ps1"
$manifestPath = Join-Path $PSScriptRoot "testdata\geometry-contract-manifest.json"
$shell = (Get-Command pwsh.exe -ErrorAction SilentlyContinue)
if ($null -eq $shell) {
    $shell = Get-Command powershell.exe -ErrorAction SilentlyContinue
}
if ($null -eq $shell) {
    throw "PowerShell executable not found"
}

$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("inksign-geometry-contract-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testDirectory | Out-Null

function Invoke-Checker([string[]]$Arguments) {
    $previousErrorAction = $ErrorActionPreference
    try {
        # Windows PowerShell promotes native stderr to NativeCommandError when
        # the caller uses ErrorAction=Stop. Expected mismatch cases use stderr
        # as part of their assertion, so capture it without terminating here.
        $ErrorActionPreference = "Continue"
        $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $checker @Arguments 2>&1)
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    [pscustomobject]@{
        Output = ($output -join "`n")
        ExitCode = $LASTEXITCODE
    }
}

function Test-ExpectedFailure([string]$Name, [string]$Manifest) {
    $result = Invoke-Checker @("-Manifest", $Manifest)
    if ($result.ExitCode -eq 0 -or $result.Output -notmatch "FAIL fixture=") {
        throw "$Name mismatch was not rejected: $($result.Output)"
    }
}

try {
    $first = Invoke-Checker @()
    $second = Invoke-Checker @()
    if ($first.ExitCode -ne 0 -or $second.ExitCode -ne 0 -or $first.Output -ne $second.Output) {
        throw "identical geometry contract runs were not deterministic"
    }

    $cases = @(
        @{ Name = "outline range"; Property = "outline" },
        @{ Name = "chord ceiling"; Property = "chord" },
        @{ Name = "contour count"; Property = "contours" },
        @{ Name = "serialized bytes"; Property = "bytes" },
        @{ Name = "transport hash"; Property = "hash" }
    )
    foreach ($case in $cases) {
        $copy = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $entry = $copy.fixtures[0]
        switch ($case.Property) {
            "outline" { $entry.outline_segments.max = [int]$entry.outline_segments.max - 1 }
            "chord" { $entry.chord_length_ceiling = 0 }
            "contours" { $entry.contour_count = [int]$entry.contour_count + 1 }
            "bytes" { $entry.serialized_frame_bytes = [int]$entry.serialized_frame_bytes + 1 }
            "hash" { $entry.transport_hash = "0x0000000000000000" }
        }
        $caseManifest = Join-Path $testDirectory ($case.Property + ".json")
        $copy | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $caseManifest -Encoding UTF8
        Test-ExpectedFailure $case.Name $caseManifest
    }

    $trackedContents = Get-Content -LiteralPath $manifestPath -Raw
    $candidate = Join-Path $testDirectory "candidate.json"
    $generated = Invoke-Checker @("-GenerateBaseline", "-BaselineOutput", $candidate)
    if ($generated.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "baseline generation failed: $($generated.Output)"
    }
    if ((Get-Content -LiteralPath $manifestPath -Raw) -ne $trackedContents) {
        throw "baseline generation modified the tracked manifest"
    }
    Write-Output "PASS geometry contract wrapper tests"
} finally {
    if (Test-Path -LiteralPath $testDirectory) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}

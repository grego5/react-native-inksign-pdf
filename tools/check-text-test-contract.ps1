[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$contractPath = Join-Path $repositoryRoot "tasks\01-text-interaction-contract.md"
$fixturePath = Join-Path $repositoryRoot "tools\testdata\text-annotation-boundaries.json"

if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    throw "text interaction contract is missing: $contractPath"
}
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
    throw "text annotation boundary fixture is missing: $fixturePath"
}

$contract = Get-Content -Raw -LiteralPath $contractPath
$requiredContractCases = @(
    "tap-to-edit",
    "long-press-to-drag",
    "unchanged-cancelled-drag",
    "outside-tap-settlement",
    "one-shot-placement",
    "minimum-presentation-geometry",
    "overlap-priority",
    "caret-visibility",
    "rtl-direction",
    "lifecycle-history"
)
foreach ($case in $requiredContractCases) {
    if ($contract -notmatch "(?m)^\|\s*``$([regex]::Escape($case))``\s*\|") {
        throw "named text annotation contract case is missing: $case"
    }
}

$fixture = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json
if ($fixture.schemaVersion -ne 1) { throw "unsupported text annotation fixture schema" }
if ($fixture.document.generation -ne 17 -or
    $fixture.document.activePageIndex -ne 1 -or
    $fixture.document.pageCount -ne 3) {
    throw "text annotation fixture document identity changed"
}
if ($fixture.layout.width -ne 320 -or
    $fixture.layout.height -ne 480 -or
    $fixture.layout.usable -ne $true) {
    throw "text annotation fixture layout changed"
}

$requiredTokens = @(
    "editorCommit",
    "dragCommit",
    "previewCompletion",
    "exportCapture",
    "replacement",
    "disposal"
)
$actualTokens = @($fixture.completionTokens | ForEach-Object { [string]$_.name })
$actualTokenKey = (@($actualTokens | Sort-Object) -join ",")
$requiredTokenKey = (@($requiredTokens | Sort-Object) -join ",")
if ($actualTokenKey -ne $requiredTokenKey) {
    throw "text annotation fixture completion boundaries changed"
}
if (($fixture.completionTokens | ForEach-Object { [string]$_.token } | Sort-Object -Unique).Count -ne $requiredTokens.Count) {
    throw "text annotation fixture completion tokens must be unique"
}
if ($fixture.supersession.oldGeneration -ne 17 -or $fixture.supersession.newGeneration -ne 18) {
    throw "text annotation fixture supersession identity changed"
}

$productionRoots = @(
    (Join-Path $repositoryRoot "android\src\main"),
    (Join-Path $repositoryRoot "ios"),
    (Join-Path $repositoryRoot "cpp"),
    (Join-Path $repositoryRoot "src")
)
$productionExtensions = @("*.kt", "*.java", "*.swift", "*.m", "*.mm", "*.c", "*.cc", "*.cpp", "*.h", "*.hpp", "*.ts", "*.tsx")
$forbiddenTextSeam = '(?i)(text|annotation).*(observer|counter|poll|sleep|ForTest)|(observer|counter|poll|sleep|ForTest).*(text|annotation)'

foreach ($productionRoot in $productionRoots) {
    if (-not (Test-Path -LiteralPath $productionRoot -PathType Container)) { continue }
    foreach ($extension in $productionExtensions) {
        foreach ($file in Get-ChildItem -LiteralPath $productionRoot -Recurse -File -Filter $extension) {
            $matches = Select-String -LiteralPath $file.FullName -Pattern $forbiddenTextSeam
            if ($null -ne $matches) {
                $match = @($matches)[0]
                throw "production text test seam is forbidden: $($file.FullName):$($match.LineNumber)"
            }
        }
    }
}

function Assert-SourceContains {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Description
    )

    if (-not (Select-String -LiteralPath $Path -Pattern $Pattern -Quiet)) {
        throw "required text interaction contract is missing ($Description): $Path"
    }
}

function Assert-SourceAbsent {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Description
    )

    if (Select-String -LiteralPath $Path -Pattern $Pattern -Quiet) {
        throw "removed text interaction state is still present ($Description): $Path"
    }
}

$androidOverlayPath = Join-Path $repositoryRoot "android\src\main\java\com\margelo\nitro\inksignpdf\TextInteractionOverlay.kt"
$androidHybridPath = Join-Path $repositoryRoot "android\src\main\java\com\margelo\nitro\inksignpdf\HybridInkSignView.kt"
$typescriptContractPath = Join-Path $repositoryRoot "src\InkSignView.nitro.ts"
$examplePath = Join-Path $repositoryRoot "example\src\App.tsx"

Assert-SourceContains $androidOverlayPath 'fun increaseTextSize\(\)' 'Android increaseTextSize command'
Assert-SourceContains $androidOverlayPath 'fun decreaseTextSize\(\)' 'Android decreaseTextSize command'
Assert-SourceContains $androidOverlayPath 'fun removeTextAnnotation\(\)' 'Android removeTextAnnotation command'
Assert-SourceContains $androidOverlayPath 'text_not_focused' 'Android missing-selection error'
Assert-SourceContains $androidOverlayPath 'interactionMode\(\)' 'Android native interaction mode'
Assert-SourceContains $androidOverlayPath 'sealed interface InteractionState' 'payload-based Android interaction state'
Assert-SourceContains $androidOverlayPath 'WindowInsetsCompat.Type.ime\(\)' 'API 24-compatible IME insets'
Assert-SourceContains $androidOverlayPath 'ViewCompat.setOnApplyWindowInsetsListener' 'AndroidX inset routing'
Assert-SourceContains $androidOverlayPath 'dragCancelled' 'drag cancellation outcome'
Assert-SourceContains $androidOverlayPath 'focusTextForEditing' 'viewport-owned edit focus'
Assert-SourceContains $androidOverlayPath 'normalizeTextFontSize' 'Android shared default-font policy'
Assert-SourceContains $androidHybridPath 'override fun increaseTextSize\(\)' 'Hybrid increaseTextSize command'
Assert-SourceContains $androidHybridPath 'override fun decreaseTextSize\(\)' 'Hybrid decreaseTextSize command'
Assert-SourceContains $androidHybridPath 'override fun removeTextAnnotation\(\)' 'Hybrid removeTextAnnotation command'
Assert-SourceContains $androidHybridPath 'runTextCommand' 'Hybrid UI-thread command dispatch'
Assert-SourceContains $typescriptContractPath 'increaseTextSize\(\): number' 'Nitro increaseTextSize contract'
Assert-SourceContains $typescriptContractPath 'decreaseTextSize\(\): number' 'Nitro decreaseTextSize contract'
Assert-SourceContains $typescriptContractPath 'removeTextAnnotation\(\): void' 'Nitro removeTextAnnotation contract'
Assert-SourceContains $typescriptContractPath 'insertAnnotationOn\(\): void' 'Nitro insertAnnotationOn contract'
Assert-SourceContains $typescriptContractPath 'insertAnnotationOff\(\): void' 'Nitro insertAnnotationOff contract'
Assert-SourceContains $typescriptContractPath 'export type InteractionMode' 'Nitro interaction mode union'
Assert-SourceContains $typescriptContractPath 'mode: InteractionMode' 'Nitro mode snapshot field'
Assert-SourceContains $typescriptContractPath 'keyboardAvoidanceEnabled\?: boolean' 'Nitro keyboard avoidance policy'

$removedToolbarState = '(?i)\b(toolbar|bottomInset|toolbarLayoutDirection|fontControls|minusButton|plusButton|deleteButton|positionToolbar)\b'
$focusedCommandAlias = '(?i)\b(increaseFocusedTextSize|decreaseFocusedTextSize|removeFocusedText)\b'
Assert-SourceAbsent $androidOverlayPath $removedToolbarState 'native annotation toolbar state'
Assert-SourceAbsent $androidOverlayPath $focusedCommandAlias 'focused command naming aliases'
Assert-SourceAbsent $androidOverlayPath 'setOnLongClickListener|var onDragStart|var onDragMove|var onDragEnd' 'editor-owned annotation drag interception'
Assert-SourceAbsent $androidHybridPath $focusedCommandAlias 'focused command naming aliases'
Assert-SourceAbsent $typescriptContractPath $focusedCommandAlias 'focused command naming aliases'
Assert-SourceAbsent $androidOverlayPath 'onTextFocusChange|TextFocusChangeEvent' 'removed Android focus callback'
Assert-SourceAbsent $androidOverlayPath '\bselectAndEdit\b|changeCommittedFont\b' 'obsolete Android text interaction branches'
Assert-SourceAbsent $androidOverlayPath 'WindowInsets\.Type\.ime|android\.view\.WindowInsets' 'API-30-only IME access'
Assert-SourceAbsent $androidOverlayPath 'private var (selectedId|editing|pendingPlacement|dragTextLayer)' 'parallel interaction state fields'
Assert-SourceAbsent $androidHybridPath 'onTextFocusChange|TextFocusChangeEvent' 'removed Android focus callback'
Assert-SourceAbsent $typescriptContractPath 'onTextFocusChange|TextFocusChangeEvent' 'removed TypeScript focus callback'
Assert-SourceAbsent $typescriptContractPath 'addTextAnnotation' 'centered text creation API'
Assert-SourceAbsent $typescriptContractPath '(?i)onPlacement|placement\??\s*:' 'JavaScript-owned placement state or callback'
Assert-SourceAbsent $typescriptContractPath 'insertAnnotation(?:On|Off)\(\s*[^)]' 'coordinate-taking placement API'
Assert-SourceContains $examplePath "state\.mode === 'textPlacement'" 'example placement state comes from native snapshot'
Assert-SourceContains $examplePath "state\.mode !== 'textEditing'.*state\.mode !== 'textSelected'" 'example text commands require native selection state'
Assert-SourceAbsent $examplePath 'textPlacementArmed|setTextPlacementArmed' 'example has no placement mirror'
Assert-SourceAbsent $examplePath 'onTextFocusChange|TextFocusChangeEvent' 'example has no focus callback mirror'
Assert-SourceAbsent $examplePath 'const \[mode, setMode\]' 'example has no view-mode mirror'

Write-Output "PASS text annotation test contract"

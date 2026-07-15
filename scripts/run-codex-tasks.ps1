[CmdletBinding()]
param(
    [string]$TaskDirectory = "docs/fund/tasks",
    [string]$StateDirectory = ".codex-task-state",
    [string]$Model = "gpt-5.6-terra",
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,
    [switch]$Yolo,
    [string[]]$TaskFiles = @(
        "08-filesystem.md",
        "09-process.md",
        "10-json-schema.md",
        "11-http-curl-sse.md",
        "12-compression-hash.md",
        "13-sqlite.md",
        "14-observability.md",
        "15-libuv-tooling.md",
        "16-testing-faults.md",
        "17-profiles-ci-acceptance.md",
        "18-platform-optimization-gate.md",
        "19-platform-runtime-acceptance.md"
    )
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

function Resolve-RepositoryPath {
    param([Parameter(Mandatory)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $RepoRoot $Path
}

function Get-HeadCommit {
    return (& git rev-parse HEAD).Trim()
}

function Get-WorkingTreeStatus {
    return (& git status --porcelain)
}

function Test-TaskCommit {
    param(
        [Parameter(Mandatory)][string]$InitialHead,
        [Parameter(Mandatory)][string]$TaskId
    )

    $currentHead = Get-HeadCommit
    $commitSubject = (& git log -1 --pretty=%s).Trim()
    $expectedSubject = "$TaskId done"

    & git merge-base --is-ancestor $InitialHead $currentHead
    $isDescendant = $LASTEXITCODE -eq 0

    return [PSCustomObject]@{
        CurrentHead = $currentHead
        CommitSubject = $commitSubject
        ExpectedSubject = $expectedSubject
        IsComplete = $currentHead -ne $InitialHead -and
            $isDescendant -and
            $commitSubject -eq $expectedSubject
    }
}

function Invoke-CodexTask {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Task,
        [Parameter(Mandatory)][string]$SetupPath,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][bool]$YoloMode
    )

    $taskId = $Task.BaseName
    $resultPath = Join-Path $StatePath "$taskId.attempt-$Attempt.md"
    $eventsPath = Join-Path $StatePath "$taskId.attempt-$Attempt.jsonl"
    $setup = Get-Content -LiteralPath $SetupPath -Raw
    $taskDocument = Get-Content -LiteralPath $Task.FullName -Raw

    $prompt = @"
Implement exactly one Foundation task. Both source documents are included below.

Global setup document: $SetupPath
--- BEGIN SETUP ---
$setup
--- END SETUP ---

Assigned task document: $($Task.FullName)
--- BEGIN TASK ---
$taskDocument
--- END TASK ---

Required procedure:
1. If present, read AGENTS.md and follow it.
2. Inspect the relevant existing implementation, completed prerequisite artifacts, and tests.
3. Implement only the assigned task. Do not begin a later task.
4. Preserve unrelated working-tree changes.
5. Add or update tests required by the task.
6. Run every acceptance command in the task document and fix failures caused by this task.
7. Review git diff for unintended changes.
8. Commit only when all acceptance criteria pass, using exactly this subject:

$taskId done

Do not run destructive Git commands, including git reset, git restore, git clean,
force checkout, or history rewriting.

If blocked, do not create the success commit. Leave useful work in the working tree
and explain the blocker and exact next action.

Your final response must include implementation summary, files changed, commands run,
test results, commit hash, and remaining risks.
"@

    $codexArguments = @(
        "exec",
        "--cd", $RepoRoot,
        "--model", $Model,
        "--json",
        "--output-last-message", $resultPath
    )
    if ($YoloMode) {
        $codexArguments += "--dangerously-bypass-approvals-and-sandbox"
    }
    else {
        $codexArguments += "--sandbox", "workspace-write"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $prompt |
            & codex @codexArguments 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $eventsPath |
            Out-Host

        $exitCode = $LASTEXITCODE
        return $exitCode
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Resume-CodexTask {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Task,
        [Parameter(Mandatory)][string]$SetupPath,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][bool]$YoloMode
    )

    $taskId = $Task.BaseName
    $resultPath = Join-Path $StatePath "$taskId.resume-$Attempt.md"
    $eventsPath = Join-Path $StatePath "$taskId.resume-$Attempt.jsonl"
    $setup = Get-Content -LiteralPath $SetupPath -Raw
    $taskDocument = Get-Content -LiteralPath $Task.FullName -Raw
    $prompt = @"
Continue only the current task $taskId.

Global setup document: $SetupPath
--- BEGIN SETUP ---
$setup
--- END SETUP ---

Assigned task document: $($Task.FullName)
--- BEGIN TASK ---
$taskDocument
--- END TASK ---

Inspect the current working-tree diff and prior command output, determine why
completion validation failed, then finish the task. Run all required acceptance
checks, review the diff, and create the exact commit subject:

$taskId done

Do not start another task or discard useful existing changes.
"@

    $codexArguments = @(
        "exec",
        "resume",
        "--last",
        "--json",
        "--output-last-message", $resultPath
    )
    if ($YoloMode) {
        $codexArguments += "--dangerously-bypass-approvals-and-sandbox"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $prompt |
            & codex @codexArguments 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $eventsPath |
            Out-Host

        $exitCode = $LASTEXITCODE
        return $exitCode
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

$taskDirectoryPath = Resolve-RepositoryPath $TaskDirectory
$stateDirectoryPath = Resolve-RepositoryPath $StateDirectory
$setupPath = Join-Path $taskDirectoryPath "setup.md"

if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
    throw "Global setup document was not found: $setupPath"
}

New-Item -ItemType Directory -Force -Path $stateDirectoryPath | Out-Null

$tasks = foreach ($taskFile in $TaskFiles) {
    $taskPath = Join-Path $taskDirectoryPath $taskFile
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        throw "Task document was not found: $taskPath"
    }

    Get-Item -LiteralPath $taskPath
}

if ($tasks.Count -eq 0) {
    throw "TaskFiles must contain at least one task document"
}

foreach ($task in $tasks) {
    $taskId = $task.BaseName
    $donePath = Join-Path $stateDirectoryPath "$taskId.done"
    $failurePath = Join-Path $stateDirectoryPath "$taskId.failed.md"

    if (Test-Path -LiteralPath $donePath -PathType Leaf) {
        Write-Host "[SKIP] $taskId"
        continue
    }

    Write-Host "`n========================================"
    Write-Host "[TASK] $taskId"
    Write-Host "========================================"

    $initialHead = Get-HeadCommit
    $success = $false

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "[ATTEMPT] $attempt / $MaxAttempts"

        if ($attempt -eq 1) {
            $exitCode = Invoke-CodexTask -Task $task -SetupPath $setupPath `
                -StatePath $stateDirectoryPath -Attempt $attempt -YoloMode $Yolo
        }
        else {
            $exitCode = Resume-CodexTask -Task $task -SetupPath $setupPath `
                -StatePath $stateDirectoryPath -Attempt $attempt -YoloMode $Yolo
        }

        if ($exitCode -ne 0) {
            Write-Warning "Codex exited with code $exitCode"
        }

        $commit = Test-TaskCommit -InitialHead $initialHead -TaskId $taskId
        if ($exitCode -eq 0 -and $commit.IsComplete) {
            @"
task=$taskId
commit=$($commit.CurrentHead)
completed_at=$(Get-Date -Format o)
attempt=$attempt
"@ | Set-Content -LiteralPath $donePath

            Remove-Item -LiteralPath $failurePath -ErrorAction SilentlyContinue
            Write-Host "[DONE] $taskId"
            Write-Host "[COMMIT] $($commit.CurrentHead)"
            $success = $true
            break
        }

        $status = Get-WorkingTreeStatus
        @"
# Task failure

Task: $taskId
Attempt: $attempt
Exit code: $exitCode
Initial HEAD: $initialHead
Current HEAD: $($commit.CurrentHead)
Expected commit: $($commit.ExpectedSubject)
Actual commit: $($commit.CommitSubject)

## Working tree

~~~text
$status
~~~
"@ | Set-Content -LiteralPath $failurePath

        if ($attempt -lt $MaxAttempts) {
            Write-Warning "Task incomplete; resuming the most recent Codex session."
        }
    }

    if (-not $success) {
        throw "Task $taskId failed after $MaxAttempts attempts. See $failurePath"
    }
}

Write-Host "`nAll tasks completed."

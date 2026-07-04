param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Branch = "main",
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$SourcePath = $PSScriptRoot,
    [string]$WorkflowFile = "build-trollstore-ipa.yml",
    [string]$ArtifactName = "GPTNative-ipa",
    [string]$OutDir = (Join-Path (Get-Location) "github-build-output"),
    [int]$TimeoutMinutes = 45,
    [int]$PollSeconds = 10,
    [switch]$CreateRepo,
    [ValidateSet("private", "public")]
    [string]$RepoVisibility = "private"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Split-Path -Parent $PSCommandPath
}

if ([string]::IsNullOrWhiteSpace($Token)) {
    throw "Missing GitHub token. Pass -Token or set `$env:GITHUB_TOKEN. The token needs repo and actions/workflow permissions."
}

$repoParts = $Repo.Split("/")
if ($repoParts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($repoParts[0]) -or [string]::IsNullOrWhiteSpace($repoParts[1])) {
    throw "Repo must be in owner/name format."
}

$Owner = $repoParts[0]
$RepoName = $repoParts[1]
$ApiBase = "https://api.github.com"
$Headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "GPTNative-TrollStore-Builder"
}

function ConvertTo-JsonBody {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Depth 100 -Compress)
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        $Body = $null,
        [string]$OutFile = $null,
        [switch]$AllowNotFound
    )

    $uri = if ($Path.StartsWith("https://")) { $Path } else { "$ApiBase$Path" }
    try {
        if ($null -ne $Body) {
            $json = ConvertTo-JsonBody $Body
            if ($OutFile) {
                return Invoke-WebRequest -Method $Method -Uri $uri -Headers $Headers -ContentType "application/json" -Body $json -OutFile $OutFile
            }
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers -ContentType "application/json" -Body $json
        }

        if ($OutFile) {
            return Invoke-WebRequest -Method $Method -Uri $uri -Headers $Headers -OutFile $OutFile
        }
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers
    } catch {
        $response = $_.Exception.Response
        if ($AllowNotFound -and $response) {
            $statusCode = [int]$response.StatusCode
            if ($statusCode -eq 404 -or $statusCode -eq 409) {
                return $null
            }
        }
        throw
    }
}

function Get-RelativeGitPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rootUri = [Uri]((Resolve-Path -LiteralPath $Root).Path.TrimEnd("\") + "\")
    $fileUri = [Uri]((Resolve-Path -LiteralPath $Path).Path)
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fileUri).ToString()).Replace("\", "/")
}

function Test-ExcludedPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $p = $RelativePath.Replace("\", "/")
    if ($p -match '(^|/)\.git(/|$)') { return $true }
    if ($p -match '(^|/)\.git-askpass\..*$') { return $true }
    if ($p -match '(^|/)build(/|$)') { return $true }
    if ($p -match '(^|/)DerivedData(/|$)') { return $true }
    if ($p -match '(^|/)github-build-output(/|$)') { return $true }
    if ($p -match '(^|/)github-api-build.*$') { return $true }
    if ($p -match '(^|/)actions-run-.*(/|$)') { return $true }
    if ($p -match '(^|/)actions-job-.*\.log$') { return $true }
    if ($p -match '\.xcodeproj/') { return $true }
    if ($p -match '\.xcworkspace/') { return $true }
    if ($p.EndsWith(".ipa") -or $p.EndsWith(".zip")) { return $true }
    if ($p.EndsWith(".DS_Store")) { return $true }
    return $false
}

function Ensure-Repository {
    $repoInfo = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$RepoName" -AllowNotFound
    if ($repoInfo) {
        return $repoInfo
    }

    if (-not $CreateRepo) {
        throw "Repository $Repo was not found. Create it first, or rerun with -CreateRepo."
    }

    $viewer = Invoke-GitHubApi -Method GET -Path "/user"
    $private = ($RepoVisibility -eq "private")
    $body = @{
        name      = $RepoName
        private   = $private
        auto_init = $false
    }

    if ($viewer.login -eq $Owner) {
        Write-Host "Creating personal repository $Repo..."
        return Invoke-GitHubApi -Method POST -Path "/user/repos" -Body $body
    }

    Write-Host "Creating organization repository $Repo..."
    return Invoke-GitHubApi -Method POST -Path "/orgs/$Owner/repos" -Body $body
}

function New-CleanTreeCommit {
    param([string]$ParentSha)

    $root = (Resolve-Path -LiteralPath $SourcePath).Path
    $files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
        $relative = Get-RelativeGitPath -Root $root -Path $_.FullName
        -not (Test-ExcludedPath -RelativePath $relative)
    }

    if (-not $files) {
        throw "No files found to upload from $root."
    }

    Write-Host "Uploading $($files.Count) files to GitHub blobs..."
    $tree = New-Object System.Collections.Generic.List[object]

    foreach ($file in $files) {
        $relative = Get-RelativeGitPath -Root $root -Path $file.FullName
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        $blob = Invoke-GitHubApi -Method POST -Path "/repos/$Owner/$RepoName/git/blobs" -Body @{
            content  = [Convert]::ToBase64String($bytes)
            encoding = "base64"
        }

        $mode = if ($relative.EndsWith(".sh")) { "100755" } else { "100644" }
        $tree.Add(@{
            path = $relative
            mode = $mode
            type = "blob"
            sha  = $blob.sha
        })
    }

    Write-Host "Creating clean repository tree..."
    $treeResult = Invoke-GitHubApi -Method POST -Path "/repos/$Owner/$RepoName/git/trees" -Body @{
        tree = $tree
    }

    $commitBody = @{
        message = "Build GPTNative TrollStore IPA via GitHub Actions"
        tree    = $treeResult.sha
    }
    if (-not [string]::IsNullOrWhiteSpace($ParentSha)) {
        $commitBody["parents"] = @($ParentSha)
    }

    Write-Host "Creating commit..."
    return Invoke-GitHubApi -Method POST -Path "/repos/$Owner/$RepoName/git/commits" -Body $commitBody
}

function Wait-ForWorkflowRun {
    param(
        [datetime]$SinceUtc,
        [string]$HeadSha
    )

    $deadline = (Get-Date).ToUniversalTime().AddMinutes($TimeoutMinutes)
    $run = $null

    Write-Host "Waiting for workflow run to appear..."
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        $runs = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$RepoName/actions/workflows/$WorkflowFile/runs?branch=$Branch&event=workflow_dispatch&per_page=10"
        $run = $runs.workflow_runs |
            Where-Object {
                $createdAt = ([datetime]$_.created_at).ToUniversalTime()
                $createdAt -ge $SinceUtc.AddSeconds(-5) -and
                    ([string]::IsNullOrWhiteSpace($HeadSha) -or $_.head_sha -eq $HeadSha)
            } |
            Sort-Object created_at -Descending |
            Select-Object -First 1

        if ($run) {
            break
        }
        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $run) {
        throw "Workflow run did not appear before timeout."
    }

    Write-Host "Run: $($run.html_url)"
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        $run = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$RepoName/actions/runs/$($run.id)"
        Write-Host ("Status: {0} / {1}" -f $run.status, $run.conclusion)

        if ($run.status -eq "completed") {
            if ($run.conclusion -ne "success") {
                Write-WorkflowFailureDiagnostics -Run $run
                throw "Workflow completed with conclusion '$($run.conclusion)': $($run.html_url)"
            }
            return $run
        }
        Start-Sleep -Seconds $PollSeconds
    }

    throw "Workflow run timed out: $($run.html_url)"
}

function Write-WorkflowFailureDiagnostics {
    param([Parameter(Mandatory = $true)]$Run)

    try {
        $jobs = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$RepoName/actions/runs/$($Run.id)/jobs?per_page=100"
        foreach ($job in $jobs.jobs) {
            Write-Host ("Job '{0}' concluded: {1}" -f $job.name, $job.conclusion)
            if ([string]::IsNullOrWhiteSpace($job.check_run_url)) {
                continue
            }

            $checkRun = Invoke-GitHubApi -Method GET -Path $job.check_run_url
            if (-not $checkRun.output -or $checkRun.output.annotations_count -le 0) {
                continue
            }

            $annotations = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$RepoName/check-runs/$($checkRun.id)/annotations?per_page=100"
            foreach ($annotation in $annotations) {
                Write-Host ("{0}: {1}" -f $annotation.annotation_level, $annotation.message)
            }
        }
    } catch {
        Write-Host "Could not fetch workflow failure diagnostics: $($_.Exception.Message)"
    }
}

function Invoke-WorkflowDispatchWithRetry {
    param([datetime]$DispatchTimeUtc)

    $deadline = (Get-Date).ToUniversalTime().AddMinutes(3)
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        try {
            Invoke-GitHubApi -Method POST -Path "/repos/$Owner/$RepoName/actions/workflows/$WorkflowFile/dispatches" -Body @{
                ref = $Branch
            } | Out-Null
            Write-Host "Workflow dispatched."
            return
        } catch {
            Write-Host "Dispatch not ready yet; retrying in $PollSeconds seconds..."
            Start-Sleep -Seconds $PollSeconds
        }
    }

    throw "Could not dispatch workflow $WorkflowFile. Check that Actions are enabled for $Repo."
}

function Download-Artifact {
    param([Parameter(Mandatory = $true)]$Run)

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $artifactList = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$RepoName/actions/runs/$($Run.id)/artifacts"
    $artifact = $artifactList.artifacts | Where-Object { $_.name -eq $ArtifactName } | Select-Object -First 1
    if (-not $artifact) {
        throw "Artifact '$ArtifactName' was not found for run $($Run.id)."
    }

    $zipPath = Join-Path $OutDir "$ArtifactName.zip"
    $extractPath = Join-Path $OutDir $ArtifactName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    if (Test-Path -LiteralPath $extractPath) { Remove-Item -LiteralPath $extractPath -Recurse -Force }

    Write-Host "Downloading artifact to $zipPath..."
    Invoke-GitHubApi -Method GET -Path $artifact.archive_download_url -OutFile $zipPath | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

    $ipa = Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "*.ipa" | Select-Object -First 1
    if (-not $ipa) {
        throw "Downloaded artifact did not contain an IPA."
    }

    $finalIpa = Join-Path $OutDir $ipa.Name
    Copy-Item -LiteralPath $ipa.FullName -Destination $finalIpa -Force
    return $finalIpa
}

$sourceRoot = (Resolve-Path -LiteralPath $SourcePath).Path
$workflowPath = Join-Path $sourceRoot ".github\workflows\$WorkflowFile"
if (-not (Test-Path -LiteralPath $workflowPath)) {
    throw "Missing workflow file: $workflowPath"
}

Write-Host "Using source: $sourceRoot"
Write-Host "Using repository: $Repo / branch $Branch"
Ensure-Repository | Out-Null

$ref = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$RepoName/git/ref/heads/$Branch" -AllowNotFound
if (-not $ref) {
    Write-Host "Initializing empty repository branch $Branch..."
    Invoke-GitHubApi -Method PUT -Path "/repos/$Owner/$RepoName/contents/.init" -Body @{
        message = "Initialize repository"
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("init"))
        branch  = $Branch
    } | Out-Null
    $ref = Invoke-GitHubApi -Method GET -Path "/repos/$Owner/$RepoName/git/ref/heads/$Branch" -AllowNotFound
}
$parentSha = if ($ref) { $ref.object.sha } else { $null }
$commit = New-CleanTreeCommit -ParentSha $parentSha

if ($ref) {
    Write-Host "Updating branch $Branch with clean tree commit..."
    Invoke-GitHubApi -Method PATCH -Path "/repos/$Owner/$RepoName/git/refs/heads/$Branch" -Body @{
        sha   = $commit.sha
        force = $true
    } | Out-Null
} else {
    Write-Host "Creating branch $Branch..."
    Invoke-GitHubApi -Method POST -Path "/repos/$Owner/$RepoName/git/refs" -Body @{
        ref = "refs/heads/$Branch"
        sha = $commit.sha
    } | Out-Null
}

try {
    Invoke-GitHubApi -Method PATCH -Path "/repos/$Owner/$RepoName" -Body @{
        default_branch = $Branch
    } | Out-Null
    Write-Host "Default branch set to $Branch."
} catch {
    Write-Host "Could not set default branch to $Branch. Continuing; dispatch may still work if this branch is already the default."
}

$dispatchTime = (Get-Date).ToUniversalTime()
Invoke-WorkflowDispatchWithRetry -DispatchTimeUtc $dispatchTime
$run = Wait-ForWorkflowRun -SinceUtc $dispatchTime -HeadSha $commit.sha
$ipaPath = Download-Artifact -Run $run

Write-Host ""
Write-Host "Done. IPA downloaded to:"
Write-Host $ipaPath

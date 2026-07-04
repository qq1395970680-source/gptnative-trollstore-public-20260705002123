param(
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    [string]$Branch = "main",
    [string]$Token = $env:GITHUB_TOKEN,
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "..\outputs"),
    [int]$TimeoutMinutes = 45,
    [int]$PollSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$builder = Join-Path $PSScriptRoot "Build-IPA-With-GitHubApi.ps1"
if (-not (Test-Path -LiteralPath $builder)) {
    throw "Missing builder script: $builder"
}

& $builder `
    -Repo $Repo `
    -Branch $Branch `
    -Token $Token `
    -SourcePath $PSScriptRoot `
    -OutDir $OutDir `
    -TimeoutMinutes $TimeoutMinutes `
    -PollSeconds $PollSeconds `
    -CreateRepo `
    -RepoVisibility public

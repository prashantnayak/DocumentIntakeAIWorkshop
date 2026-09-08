<#
.SYNOPSIS
    Verifies every pinned public AVM module version referenced under infra/
    actually exists in the Microsoft Container Registry, and reports when a
    newer version has been published.

.DESCRIPTION
    This script replaces the Bicep `use-recent-module-versions` linter rule,
    which is switched off in bicepconfig.json.

    That rule performs an ASYNCHRONOUS registry lookup that only completes
    reliably inside the Bicep language server (editor). Running
    `az bicep build` / `bicep build` from a command line emits
    "Available module versions have not yet been downloaded" for a
    nondeterministic subset of module references on every run, even
    immediately after `bicep restore --force`, because the build finishes
    before the background fetch does. Leaving the rule enabled therefore makes
    a warning-free build impossible to achieve or to assert on in CI.

    This script performs the same check deterministically and synchronously:

      * FAIL (exit 1)  - a pinned version does not exist in the registry. That
                         is a real, breaking error: the deployment cannot
                         restore the module.
      * REPORT         - a newer version exists. Informational only, so a
                         brand-new upstream AVM release does not spuriously
                         break an unrelated pull request. Bump deliberately,
                         and update the AVM manifest in docs/architecture.md
                         in the same change.

.PARAMETER InfraPath
    Root directory to scan for .bicep files. Defaults to the repository's
    infra/ directory.

.PARAMETER FailOnOutdated
    Also exit non-zero when a newer module version is available. Off by
    default; useful for a scheduled dependency-refresh job.

.EXAMPLE
    ./scripts/verify-avm-module-versions.ps1
#>
[CmdletBinding()]
param(
    [string]$InfraPath,

    [switch]$FailOnOutdated
)

$ErrorActionPreference = 'Stop'

if (-not $InfraPath) {
    $InfraPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'infra'
}

if (-not (Test-Path -Path $InfraPath)) {
    throw "Infra path '$InfraPath' does not exist."
}

function ConvertTo-ComparableVersion {
    param([string]$Tag)

    # AVM tags are plain SemVer (e.g. 0.33.0). Anything that is not parseable
    # (pre-release/build metadata) is deliberately excluded from the "newest"
    # comparison so a preview tag never looks newer than a stable one.
    [version]$parsed = $null
    if ([version]::TryParse($Tag, [ref]$parsed)) { return $parsed }
    return $null
}

$pattern = "br/public:(?<path>avm/[A-Za-z0-9\-/]+):(?<version>[0-9A-Za-z\.\-]+)"
$references = @{}

Get-ChildItem -Path $InfraPath -Recurse -Filter '*.bicep' | ForEach-Object {
    $file = $_
    foreach ($match in [regex]::Matches((Get-Content -Raw -Path $file.FullName), $pattern)) {
        $key = "$($match.Groups['path'].Value):$($match.Groups['version'].Value)"
        if (-not $references.ContainsKey($key)) {
            $references[$key] = [pscustomobject]@{
                ModulePath = $match.Groups['path'].Value
                Version    = $match.Groups['version'].Value
                Files      = [System.Collections.Generic.List[string]]::new()
            }
        }
        $relative = $file.FullName.Substring($InfraPath.Length).TrimStart('\', '/')
        if (-not $references[$key].Files.Contains($relative)) {
            $references[$key].Files.Add($relative)
        }
    }
}

if ($references.Count -eq 0) {
    throw "No 'br/public:avm/...' module references found under '$InfraPath' -- check the path."
}

$missing = [System.Collections.Generic.List[string]]::new()
$outdated = [System.Collections.Generic.List[string]]::new()

foreach ($reference in ($references.Values | Sort-Object ModulePath, Version)) {
    $uri = "https://mcr.microsoft.com/v2/bicep/$($reference.ModulePath)/tags/list"
    $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
    $tags = @($response.tags)

    if ($tags -notcontains $reference.Version) {
        $missing.Add("$($reference.ModulePath):$($reference.Version) (referenced by $($reference.Files -join ', ')) does not exist in the registry.")
        continue
    }

    $pinned = ConvertTo-ComparableVersion -Tag $reference.Version
    $newest = $tags |
        ForEach-Object { ConvertTo-ComparableVersion -Tag $_ } |
        Where-Object { $null -ne $_ } |
        Sort-Object -Descending |
        Select-Object -First 1

    if ($pinned -and $newest -and $newest -gt $pinned) {
        $outdated.Add("$($reference.ModulePath):$($reference.Version) -> $newest available (referenced by $($reference.Files -join ', '))")
        Write-Host "  [outdated] $($reference.ModulePath):$($reference.Version) (newest $newest)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  [ok]       $($reference.ModulePath):$($reference.Version)" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host "Checked $($references.Count) pinned AVM module reference(s)." -ForegroundColor Cyan

if ($outdated.Count -gt 0) {
    Write-Host ''
    Write-Host "$($outdated.Count) module reference(s) have a newer published version:" -ForegroundColor Yellow
    $outdated | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    Write-Host 'Bump deliberately and update the AVM manifest table in docs/architecture.md in the same change.' -ForegroundColor Yellow
}

if ($missing.Count -gt 0) {
    Write-Host ''
    $missing | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($missing.Count) pinned AVM module version(s) do not exist in the registry."
}

if ($FailOnOutdated -and $outdated.Count -gt 0) {
    throw "$($outdated.Count) pinned AVM module version(s) are outdated and -FailOnOutdated was specified."
}

Write-Host 'All pinned AVM module versions exist in the Microsoft Container Registry.' -ForegroundColor Green

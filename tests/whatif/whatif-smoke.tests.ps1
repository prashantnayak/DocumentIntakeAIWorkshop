#Requires -Modules Pester
<#
.SYNOPSIS
    Pester wrapper for an `az deployment sub what-if` smoke test against
    infra/main.bicep + infra/params/dev.bicepparam. Non-mutating -- what-if
    never creates, modifies, or deletes any resource.

.DESCRIPTION
    Requires an authenticated `az login` (or OIDC federated login in CI) with
    at least Reader + Microsoft.Resources/deployments/write at the target
    subscription scope. Run from the repository root:
        Invoke-Pester -Path tests/whatif/whatif-smoke.tests.ps1 -Output Detailed

    This is the same command .github/workflows/pr-validate.yml runs and
    posts as a PR comment.
#>

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $templateFile = Join-Path $repoRoot 'infra\main.bicep'
    $parameterFile = Join-Path $repoRoot 'infra\params\dev.bicepparam'
    $script:Location = if ($env:INTAKEAI_LOCATION) { $env:INTAKEAI_LOCATION } else { 'eastus2' }
    $deploymentName = "whatif-smoke-$(Get-Date -Format 'yyyyMMddHHmmss')"

    $script:WhatIfOutput = az deployment sub what-if `
        --location $script:Location `
        --template-file $templateFile `
        --parameters $parameterFile `
        --name $deploymentName `
        --no-pretty-print 2>&1 | Out-String
    $script:WhatIfExitCode = $LASTEXITCODE
}

Describe 'What-If smoke test -- infra/main.bicep (dev)' {
    It 'authenticates and evaluates the subscription-scoped deployment without an ARM error' {
        if ($script:WhatIfExitCode -ne 0) {
            Write-Host $script:WhatIfOutput -ForegroundColor Red
        }
        $script:WhatIfExitCode | Should -Be 0
    }

    It 'does not report any resource being deleted unexpectedly' {
        # A clean first-time deployment should only ever Create; Delete would
        # indicate the template diverged from what is already deployed.
        $script:WhatIfOutput | Should -Not -Match '(?m)^\s*-\s'
    }
}

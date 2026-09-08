#Requires -Modules Pester, PSRule, PSRule.Rules.Azure
<#
.SYNOPSIS
    Pester wrapper that runs PSRule for Azure against the compiled infra
    templates and fails the test run if any non-suppressed rule fails.

.DESCRIPTION
    Precompiles infra/main.bicep + infra/params/dev.bicepparam to ARM JSON
    (avoiding PSRule.Rules.Azure's own Bicep-expansion timeout on this
    subscription-scoped, multi-module template -- see
    https://azure.github.io/PSRule.Rules.Azure/setup/setup-bicep/), exports
    resource data with Export-AzRuleTemplateData, then asserts with
    Invoke-PSRule using tests/ps-rule/ps-rule.yaml (which documents every
    accepted exclusion/suppression with its rationale).

.NOTES
    Run from the repository root:
        Invoke-Pester -Path tests/ps-rule/ps-rule.tests.ps1 -Output Detailed
#>

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $infraDir = Join-Path $repoRoot 'infra'
    $outDir = Join-Path $PSScriptRoot 'out'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $templateFile = Join-Path $outDir 'main.json'
    $parametersFile = Join-Path $outDir 'dev.parameters.json'
    $resourceDataFile = Join-Path $outDir 'resources.json'

    & az bicep build --file (Join-Path $infraDir 'main.bicep') --outfile $templateFile 2>&1 | Out-Null
    & az bicep build-params --file (Join-Path $infraDir 'params\dev.bicepparam') --outfile $parametersFile 2>&1 | Out-Null

    Import-Module PSRule.Rules.Azure -Force
    Export-AzRuleTemplateData -TemplateFile $templateFile -ParameterFile $parametersFile -OutputPath $resourceDataFile -ErrorAction Stop

    $script:PSRuleResult = Invoke-PSRule -InputPath $resourceDataFile -Module 'PSRule.Rules.Azure' -Option (Join-Path $PSScriptRoot 'ps-rule.yaml') -ErrorAction Stop
}

Describe 'PSRule for Azure -- infra/main.bicep (dev)' {
    It 'produces at least one rule result' {
        $script:PSRuleResult.Count | Should -BeGreaterThan 0
    }

    It 'has no failing rules beyond the documented exclusions/suppressions in ps-rule.yaml' {
        $failures = $script:PSRuleResult | Where-Object { $_.Outcome -eq 'Fail' }
        if ($failures) {
            $summary = ($failures | ForEach-Object { "$($_.RuleName) on $($_.TargetName): $($_.Reason -join '; ')" }) -join "`n"
            Write-Host "Unexpected PSRule failures:`n$summary" -ForegroundColor Red
        }
        $failures.Count | Should -Be 0
    }
}

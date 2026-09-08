<#
.SYNOPSIS
    Generates the synthetic, non-PHI PDF fixtures used to validate the
    Document Intake AI pipeline end to end.

.DESCRIPTION
    Azure AI Document Intelligence only accepts PDF, JPEG, PNG, BMP, TIFF,
    HEIF and Office formats -- a .txt file is rejected before analysis even
    begins, so a plain-text fixture cannot exercise the pipeline. This script
    writes a minimal, standards-conformant PDF 1.4 document (catalog, one
    page, Helvetica base-14 font, one uncompressed content stream, a correct
    cross-reference table) entirely from generated primitives.

    Nothing is copied from any third-party document, template, form, or
    sample. Every value is an obviously fabricated placeholder, and no real
    or sample PHI is present or implied.

    Regenerate the committed fixtures from the repository root with:
        ./tests/fixtures/New-SyntheticIntakePdf.ps1

.PARAMETER OutputDirectory
    Directory that receives the generated PDFs. Defaults to this script's own
    directory (tests/fixtures).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OutputDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

function ConvertTo-PdfLiteral {
    param([string]$Text)

    # Escape the three characters that are special inside a PDF string
    # literal. Everything the fixtures use is plain ASCII.
    return $Text.Replace('\', '\\').Replace('(', '\(').Replace(')', '\)')
}

function New-SyntheticPdf {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines
    )

    $contentBuilder = [System.Text.StringBuilder]::new()
    [void]$contentBuilder.Append("BT`n/F1 11 Tf`n54 738 Td`n15 TL`n")
    foreach ($line in $Lines) {
        [void]$contentBuilder.Append('(' + (ConvertTo-PdfLiteral -Text $line) + ") Tj T*`n")
    }
    [void]$contentBuilder.Append("ET`n")
    $content = $contentBuilder.ToString()
    $contentLength = [System.Text.Encoding]::ASCII.GetByteCount($content)

    $objects = @(
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Length $contentLength >>`nstream`n${content}endstream"
    )

    $builder = [System.Text.StringBuilder]::new()
    # No binary comment marker: every byte in these fixtures is 7-bit ASCII,
    # so the marker would serve no purpose and would not survive the ASCII
    # encoding used below.
    [void]$builder.Append("%PDF-1.4`n")

    $offsets = @()
    for ($i = 0; $i -lt $objects.Count; $i++) {
        $offsets += [System.Text.Encoding]::ASCII.GetByteCount($builder.ToString())
        [void]$builder.Append("$($i + 1) 0 obj`n$($objects[$i])`nendobj`n")
    }

    $xrefOffset = [System.Text.Encoding]::ASCII.GetByteCount($builder.ToString())
    [void]$builder.Append("xref`n0 $($objects.Count + 1)`n")
    [void]$builder.Append("0000000000 65535 f `n")
    foreach ($offset in $offsets) {
        [void]$builder.Append(('{0:0000000000} 00000 n ' -f $offset) + "`n")
    }
    [void]$builder.Append("trailer`n<< /Size $($objects.Count + 1) /Root 1 0 R >>`nstartxref`n$xrefOffset`n%%EOF`n")

    if ($PSCmdlet.ShouldProcess($Path, 'Write synthetic PDF fixture')) {
        [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::ASCII.GetBytes($builder.ToString()))
        Write-Host "Wrote $Path ($([System.IO.FileInfo]::new($Path).Length) bytes)." -ForegroundColor Green
    }
}

$completeLines = @(
    'SYNTHETIC TEST FIXTURE - NOT REAL PHI - SAFE FOR SOURCE CONTROL',
    '',
    'Referral / Intake Form (SAMPLE)',
    '',
    'Document Type: General Intake Form',
    '',
    'Patient Identifier: SYN-TEST-0000001',
    'Date of Service: 2020-01-01',
    'Provider: Dr. Sample Synthetic MD',
    '',
    'Patient Name: Jane Q. Testpatient (FICTIONAL)',
    'Date of Birth: 1900-01-01 (FICTIONAL)',
    'Facility: Contoso Test Clinic (FICTIONAL FACILITY)',
    '',
    'Reason for Referral:',
    'Placeholder text generated solely for pipeline testing. It does not',
    'describe any real medical condition, treatment, or individual.',
    '',
    'All three required fields are present with key/value labels the',
    'prebuilt-layout keyValuePairs add-on can extract, so a correctly',
    'configured deployment routes this document down the auto-approve path.'
)

$missingFieldsLines = @(
    'SYNTHETIC TEST FIXTURE - NOT REAL PHI - SAFE FOR SOURCE CONTROL',
    '',
    'Referral / Intake Form (SAMPLE - INCOMPLETE)',
    '',
    'Document Type: General Intake Form',
    '',
    'Patient Identifier: SYN-TEST-0000002',
    '',
    'Patient Name: John Q. Testpatient (FICTIONAL)',
    'Facility: Contoso Test Clinic (FICTIONAL FACILITY)',
    '',
    'Reason for Referral:',
    'Placeholder text generated solely for pipeline testing. It does not',
    'describe any real medical condition, treatment, or individual.',
    '',
    'Date of Service and Provider are deliberately absent, so the',
    'RequiredFieldsGate fires and the document is routed to human review',
    'instead of being auto-approved.'
)

New-SyntheticPdf -Path (Join-Path $OutputDirectory 'sample-intake-document.pdf') -Lines $completeLines -WhatIf:$WhatIfPreference
New-SyntheticPdf -Path (Join-Path $OutputDirectory 'sample-intake-document-missing-fields.pdf') -Lines $missingFieldsLines -WhatIf:$WhatIfPreference

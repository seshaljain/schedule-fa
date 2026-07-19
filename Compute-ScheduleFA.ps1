<#
.SYNOPSIS
    Computes Schedule FA (Table A3) values for Microsoft (MSFT) shares held via
    Fidelity, using the SBI TT-buy-rate methodology required for ITR-2.

.DESCRIPTION
    For a given calendar year, this utility parses the Fidelity "MSFT Stock
    Details.csv" lot export and produces, per lot, the Schedule FA figures
    required for ITR-2:
        - Initial value of the investment (INR)
        - Peak value of investment during the period (INR)
        - Closing balance (INR)
        - Total gross amount paid/credited i.e. dividends (INR)
        - Total gross proceeds from sale / redemption (INR)

    Conversion methodology (validated against a prior known-good FY25 filing):
      * Asset values (initial / peak / closing) use the SBI TT Buy Rate on the
        ACTUAL transaction date (last published rate on or before that date).
      * Dividends use Rule 128: the SBI TT Buy Rate on the LAST DAY OF THE MONTH
        IMMEDIATELY PRECEDING the month in which the dividend is paid/credited.
      * FMV at acquisition:
            - RSU / stock award (share source "DO") -> Cost basis/share (CSV)
            - ESPP            (share source "SP")   -> MSFT market close on date
      * Peak = qty * max over [Jan 1 .. Dec 31 of Year] of (daily High * TTBR(day))
      * Closing = qty * MSFT close(Dec 31) * TTBR(Dec 31)

.PARAMETER Year
    Calendar year to compute (e.g. 2025 for AY 2026-27).

.PARAMETER LotCsv
    Path to the Fidelity "MSFT Stock Details.csv" export.

.PARAMETER WorkDir
    Directory holding / caching SBI_USD.csv and MSFT_ohlc.csv. Data is
    downloaded automatically if missing.

.PARAMETER OutDir
    Where to write the output report (CSV + HTML). Defaults to WorkDir's parent.

.PARAMETER NraRate
    US NRA withholding rate on dividends. Default 0.25 (India-US DTAA Art. 10 rate
    with a valid W-8BEN on file). Use 0.30 if the W-8BEN has lapsed or is missing.

.PARAMETER UsTaxWithheldUsd
    Optional override of the total US tax withheld (USD) from statements, for the
    rare mixed-rate year (W-8BEN lapses mid-year). Leave 0 to derive from NraRate.

.EXAMPLE
    .\Compute-ScheduleFA.ps1 -Year 2025 -LotCsv ".\MSFT Stock Details.csv"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$Year,
    [Parameter(Mandatory)][string]$LotCsv,
    [string]$WorkDir = (Join-Path $PSScriptRoot '_work'),
    [string]$OutDir  = $PSScriptRoot,
    [ValidateSet('CY','FY')][string]$DividendBasis = 'FY',
    # US NRA withholding rate on dividends. 0.25 = India-US DTAA (Art. 10) rate with a
    # valid W-8BEN on file; use 0.30 if the W-8BEN has lapsed/is missing. The rate is a
    # property of the payment year (W-8BEN status at pay date), applied to every dividend
    # paid in the period regardless of when the underlying lot was acquired.
    [ValidateRange(0.0, 1.0)][double]$NraRate = 0.25,
    # Optional override: actual total US tax withheld (USD) from statements, for the rare
    # case a W-8BEN lapses mid-year (mixed 25%/30% payments). Leave 0 to derive from NraRate.
    [double]$UsTaxWithheldUsd = 0,
    [switch]$RefreshPrices
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# MSFT dividend calendar (ex-date, pay-date, dividend per share in USD).
# Source: Microsoft Investor Relations dividend history, cached as a global
# constants file in WorkDir (MSFT_Dividends.csv) alongside SBI_USD / MSFT_ohlc.
# Pay date drives the Rule-128 conversion rate; ex date drives lot entitlement.
# ---------------------------------------------------------------------------
$dividendFile = Join-Path $WorkDir 'MSFT_Dividends.csv'
if (-not (Test-Path $dividendFile)) { throw "MSFT dividend history not found: $dividendFile" }
$Dividends = Import-Csv $dividendFile | ForEach-Object {
    [pscustomobject]@{ Ex = $_.Ex; Pay = $_.Pay; Dps = [double]$_.Dps }
}

# ---------------------------------------------------------------------------
# Entity metadata for the Schedule FA A3 form (constants, per issuer).
# For a different company/broker, edit these to match the issuing entity.
# CountryCode 2 = United States (ITR country code list).
# ---------------------------------------------------------------------------
$EntityCountry     = 'UNITED STATES'
$EntityCountryCode = '2'
$EntityName        = 'Microsoft Corporation'
$EntityAddress     = 'One Microsoft Way Redmond Washington'
$EntityZip         = '98052'
$EntityNature      = 'Listed'

# ---------------------------------------------------------------------------
# Table A2 (Foreign Custodial Account) defaults.
# Pre-filled for the common case: Microsoft India employees holding MSFT
# RSU/ESPP shares through Fidelity Stock Plan Services (custodian = Fidelity
# Personal Trust Company, participant = beneficiary of the plan trust).
# Account Number and Opening Date are per-user placeholders.
# If your custodian is different, edit these constants accordingly.
# Only the three monetary A2 columns (Peak / Closing / Amount paid) are computed.
# ---------------------------------------------------------------------------
$A2InstitutionName    = 'Fidelity Stock Plan Services Participant Trust / Fidelity Personal Trust Company'
$A2InstitutionAddress = '245 Summer Street Boston Massachusetts'
$A2Zip                = '02210'
$A2AccountNumber      = '[input_value_here]'
$A2Status             = 'Beneficiary'
$A2OpeningDate        = '[yyyy-mm-dd]'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-OnOrBefore {
    # Returns the value in $map for the greatest key <= $date (yyyy-MM-dd string).
    param([string[]]$Keys, [hashtable]$Map, [string]$Date)
    $lo = 0; $hi = $Keys.Count - 1; $ans = $null
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        if ($Keys[$mid] -le $Date) { $ans = $Keys[$mid]; $lo = $mid + 1 }
        else { $hi = $mid - 1 }
    }
    if ($null -eq $ans) { throw "No data on or before $Date" }
    return $Map[$ans]
}

function Get-PrevMonthEnd {
    param([string]$Date)  # yyyy-MM-dd -> last day of previous month
    $d = [datetime]::ParseExact($Date, 'yyyy-MM-dd', $null)
    return ($d.AddDays(1 - $d.Day).AddDays(-1)).ToString('yyyy-MM-dd')
}

# ---------------------------------------------------------------------------
# Data acquisition (SBI rates + MSFT OHLC), cached in WorkDir
# ---------------------------------------------------------------------------
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
if (-not (Test-Path $OutDir))  { New-Item -ItemType Directory -Force -Path $OutDir  | Out-Null }
$sbiPath  = Join-Path $WorkDir 'SBI_USD.csv'
$msftPath = Join-Path $WorkDir 'MSFT_ohlc.csv'

if ($RefreshPrices -or -not (Test-Path $sbiPath)) {
    Write-Host "Downloading SBI USD reference rates..."
    $u = 'https://raw.githubusercontent.com/sahilgupta/sbi-fx-ratekeeper/refs/heads/main/csv_files/SBI_REFERENCE_RATES_USD.csv'
    Invoke-WebRequest -Uri $u -OutFile $sbiPath -UseBasicParsing
}
if ($RefreshPrices -or -not (Test-Path $msftPath)) {
    Write-Host "Downloading MSFT daily prices from Yahoo Finance..."
    # Start well before any plausible ESPP/RSU acquisition so pre-2023 lots resolve
    # their acquisition-date close (peak/closing only ever need the filing year).
    $p1 = [int][double]::Parse((Get-Date '2000-01-01Z' -UFormat %s))
    $p2 = [int][double]::Parse((Get-Date (Get-Date).AddDays(1) -UFormat %s))
    $u  = "https://query1.finance.yahoo.com/v8/finance/chart/MSFT?period1=$p1&period2=$p2&interval=1d"
    $raw = (Invoke-WebRequest -Uri $u -Headers @{ 'User-Agent'='Mozilla/5.0' } -UseBasicParsing).Content
    $j = $raw | ConvertFrom-Json
    $res = $j.chart.result[0]
    $q   = $res.indicators.quote[0]
    $rows = for ($i=0; $i -lt $res.timestamp.Count; $i++) {
        if ($null -eq $q.close[$i]) { continue }
        [pscustomobject]@{
            Date  = ([datetimeoffset]::FromUnixTimeSeconds($res.timestamp[$i])).UtcDateTime.ToString('yyyy-MM-dd')
            Close = [math]::Round([double]$q.close[$i],4)
            High  = [math]::Round([double]$q.high[$i],4)
        }
    }
    $rows | Export-Csv -Path $msftPath -NoTypeInformation
}

# ---------------------------------------------------------------------------
# Load rate + price series
# ---------------------------------------------------------------------------
$ttbr = @{}
foreach ($line in Get-Content $sbiPath | Select-Object -Skip 1) {
    $c = $line -split ','
    if ($c.Count -lt 3) { continue }
    $dt = ($c[0] -split '\s+')[0]
    $val = 0.0
    if ([double]::TryParse($c[2], [ref]$val) -and $val -gt 0) { $ttbr[$dt] = $val }
}
$ttbrKeys = $ttbr.Keys | Sort-Object

$close = @{}; $high = @{}
foreach ($r in Import-Csv $msftPath) {
    $close[$r.Date] = [double]$r.Close
    $high[$r.Date]  = [double]$r.High
}
$priceKeys = $close.Keys | Sort-Object

function TTBR([string]$d)  { Get-OnOrBefore -Keys $ttbrKeys  -Map $ttbr  -Date $d }
function Close([string]$d) { Get-OnOrBefore -Keys $priceKeys -Map $close -Date $d }

# ---------------------------------------------------------------------------
# Period bounds
# ---------------------------------------------------------------------------
$yStart = "$Year-01-01"
$yEnd   = "$Year-12-31"
$closePrice = Close $yEnd            # MSFT close on last trading day <= Dec 31
$closeRate  = TTBR  $yEnd

# Pre-compute the daily High*TTBR series within the year (for peak lookups)
$yearDays = $priceKeys | Where-Object { $_ -ge $yStart -and $_ -le $yEnd }
$dailyInr = foreach ($d in $yearDays) {
    [pscustomobject]@{ Date=$d; Val = $high[$d] * (TTBR $d) }
}

# ---------------------------------------------------------------------------
# Process lots
# ---------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$sn = 0
foreach ($lot in Import-Csv $LotCsv) {
    if (-not $lot.'Date acquired' -or $lot.'Date acquired' -notmatch '^[A-Za-z]{3}-\d{2}-\d{4}$') { continue }
    $acq = [datetime]::ParseExact($lot.'Date acquired', 'MMM-dd-yyyy', [System.Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd')
    if ($acq -gt $yEnd) { continue }   # not acquired yet in this period

    $qty       = [double]$lot.Quantity
    $cbShare   = [double]$lot.'Cost basis/share'
    $source    = $lot.'Share source'    # DO = RSU/award, SP = ESPP

    # FMV at acquisition
    if ($source -eq 'SP') { $fmv = Close $acq } else { $fmv = $cbShare }
    $acqRate   = TTBR $acq
    $initial   = $qty * $fmv * $acqRate

    # Peak over [max(acq, Jan 1) .. Dec 31] of daily High * TTBR
    $winStart = if ($acq -gt $yStart) { $acq } else { $yStart }
    $peakUnit = ($dailyInr | Where-Object { $_.Date -ge $winStart } | Measure-Object -Property Val -Maximum).Maximum
    $peak     = $qty * $peakUnit

    # Closing
    $closing  = $qty * $closePrice * $closeRate

    # Dividends: held at ex-date -> qty * dps * TTBR(prev-month-end of pay date)
    $div = 0.0
    foreach ($dv in $Dividends) {
        if ($dv.Ex -ge $yStart -and $dv.Ex -le $yEnd -and $acq -le $dv.Ex) {
            $div += $qty * $dv.Dps * (TTBR (Get-PrevMonthEnd $dv.Pay))
        }
    }

    $sn++
    $results.Add([pscustomobject]@{
        'S.No'          = $sn
        'Date acquired' = $acq
        'Qty'           = [math]::Round($qty,4)
        'Source'        = $source
        'Initial (INR)' = [math]::Round($initial)
        'Peak (INR)'    = [math]::Round($peak)
        'Closing (INR)' = [math]::Round($closing)
        'Dividend (INR)'= [math]::Round($div)
        'Sale (INR)'    = 0
    })
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Schedule FA - Table A3 : Microsoft Corporation (MSFT) - Calendar Year $Year" -ForegroundColor Cyan
Write-Host "SBI TTBR on $yEnd = $closeRate ; MSFT close = `$$closePrice" -ForegroundColor DarkGray
$results | Format-Table -AutoSize

$tot = [pscustomobject]@{
    Lots      = $results.Count
    Initial   = ($results | Measure-Object 'Initial (INR)' -Sum).Sum
    Peak      = ($results | Measure-Object 'Peak (INR)' -Sum).Sum
    Closing   = ($results | Measure-Object 'Closing (INR)' -Sum).Sum
    Dividend  = ($results | Measure-Object 'Dividend (INR)' -Sum).Sum
}
Write-Host "TOTALS:" -ForegroundColor Cyan
$tot | Format-List

$csvOut = Join-Path $OutDir "ScheduleFA_A3_CY$Year.csv"
$results | Export-Csv -Path $csvOut -NoTypeInformation
Write-Host "Written: $csvOut" -ForegroundColor Green

# ITR-2 Schedule FA Table A3 import format (exact official column order/headers).
$itrRows = foreach ($r in $results) {
    [pscustomobject][ordered]@{
        'Country/Region name'                                                                = $EntityCountry
        'Country Name and Code'                                                               = $EntityCountryCode
        'Name of entity'                                                                      = $EntityName
        'Address of entity'                                                                   = $EntityAddress
        'ZIP Code'                                                                            = $EntityZip
        'Nature of entity'                                                                    = $EntityNature
        'Date of acquiring the interest'                                                      = $r.'Date acquired'
        'Initial value of the investment'                                                     = $r.'Initial (INR)'
        'Peak value of investment during the Period'                                          = $r.'Peak (INR)'
        'Closing balance'                                                                     = $r.'Closing (INR)'
        'Total gross amount paid/credited with respect to the holding during the period'      = $r.'Dividend (INR)'
        'Total gross proceeds from sale or redemption of investment during the period'        = $r.'Sale (INR)'
    }
}
$itrOut = Join-Path $OutDir "ScheduleFA_A3_ITR_CY$Year.csv"
$itrRows | Export-Csv -Path $itrOut -NoTypeInformation
Write-Host "Written: $itrOut  (ITR-2 A3 import format)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Table A2 - Foreign custodial account (aggregate over all lots, CY basis).
# Same reporting window as A3 (calendar year). Closing/Amount-paid are exact
# sums of A3 per-lot values (same reporting day; identity under CY dividends).
# Peak is the account-level daily maximum: max_d in [1-Jan..31-Dec] of
#     shares_held(d) * High(d) * TTBR(d).
# This is bounded above by the sum of per-lot peaks (lots peak on different
# days). User-identifying fields are hardcoded [input_value_here] placeholders.
# ---------------------------------------------------------------------------
# Hoist $allLots so both A2 (peak) and the dividend section reuse the same list.
$allLots = @(Import-Csv $LotCsv | Where-Object { $_.'Date acquired' -match '^[A-Za-z]{3}-\d{2}-\d{4}$' } |
    ForEach-Object {
        [pscustomobject]@{
            Acq = [datetime]::ParseExact($_.'Date acquired','MMM-dd-yyyy',[System.Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd')
            Qty = [double]$_.Quantity
        }
    })
function SharesHeld([string]$d) { ($allLots | Where-Object { $_.Acq -le $d } | Measure-Object Qty -Sum).Sum }

$a2Closing  = [long](($results | Measure-Object 'Closing (INR)' -Sum).Sum)
$a2Dividend = [long](($results | Measure-Object 'Dividend (INR)' -Sum).Sum)
$a2PeakUnit = 0.0
foreach ($e in $dailyInr) {
    $sh = 0.0
    foreach ($l in $allLots) { if ($l.Acq -le $e.Date) { $sh += $l.Qty } }
    $v = $sh * $e.Val
    if ($v -gt $a2PeakUnit) { $a2PeakUnit = $v }
}
$a2Peak = [math]::Round($a2PeakUnit)

$a2Row = [pscustomobject][ordered]@{
    'Country/Region name'                                                                 = $EntityCountry
    'Country Name and Code'                                                                = $EntityCountryCode
    'Name of financial institution in which the account is held'                           = $A2InstitutionName
    'Address of financial institution'                                                     = $A2InstitutionAddress
    'ZIP Code'                                                                             = $A2Zip
    'Account number'                                                                       = $A2AccountNumber
    'Status'                                                                               = $A2Status
    'Account opening date'                                                                 = $A2OpeningDate
    'Peak balance during the period'                                                       = $a2Peak
    'Closing balance'                                                                      = $a2Closing
    'Gross amount paid/credited to the account during the period'                          = $a2Dividend
}
$a2Out = Join-Path $OutDir "ScheduleFA_A2_ITR_CY$Year.csv"
$a2Row | Export-Csv -Path $a2Out -NoTypeInformation
Write-Host ""
Write-Host "Schedule FA - Table A2 : Foreign custodial account - Calendar Year $Year" -ForegroundColor Cyan
Write-Host ("  Peak balance    : INR {0:N0}" -f $a2Peak)
Write-Host ("  Closing balance : INR {0:N0}" -f $a2Closing)
Write-Host ("  Amount paid     : INR {0:N0}" -f $a2Dividend)
Write-Host "  NOTE: fill in [input_value_here] and [yyyy-mm-dd] cells in $a2Out before uploading." -ForegroundColor Yellow
Write-Host "Written: $a2Out  (ITR-2 A2 import format)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Dividend income schedule (Schedule OS / FSI) - total holding basis.
# Bucketed into ITR-2 "Schedule OS" advance-tax quarters by dividend PAY date.
# Income and foreign tax converted per Rule 128 (prev-month-end of pay date).
# ---------------------------------------------------------------------------
# Choose the reporting window
if ($DividendBasis -eq 'FY') {
    $divStart = "$($Year)-04-01"; $divEnd = "$($Year+1)-03-31"
    $periodLabel = "FY $Year-$(($Year+1).ToString().Substring(2))"
} else {
    $divStart = "$Year-01-01"; $divEnd = "$Year-12-31"
    $periodLabel = "CY $Year"
}

function OsQuarter([string]$d) {
    # Indian FY advance-tax quarters (FY starts 1 Apr; Jan-Mar are late in the FY)
    $mo = [int]$d.Substring(5,2); $dy = [int]$d.Substring(8,2)
    $key = $mo*100 + $dy
    if     ($key -ge 401  -and $key -le 615)  { 'Upto 15/6' }
    elseif ($key -ge 616  -and $key -le 915)  { '16/6-15/9' }
    elseif ($key -ge 916  -and $key -le 1215) { '16/9-15/12' }
    elseif ($key -ge 1216 -or  $key -le 315)  { '16/12-15/3' }
    else { '16/3-31/3' }
}

$divRows = New-Object System.Collections.Generic.List[object]
foreach ($dv in $Dividends | Where-Object { $_.Pay -ge $divStart -and $_.Pay -le $divEnd }) {
    $sh   = SharesHeld $dv.Ex
    $rate = TTBR (Get-PrevMonthEnd $dv.Pay)
    $usd  = $sh * $dv.Dps
    $taxInr = [math]::Round($usd * $NraRate * $rate)   # NRA tax withheld, converted at this dividend's Rule-128 rate
    $divRows.Add([pscustomobject]@{
        Ex=$dv.Ex; Pay=$dv.Pay; Shares=[math]::Round($sh,4); Dps=$dv.Dps
        USD=[math]::Round($usd,2); Rate=$rate; INR=[math]::Round($usd*$rate)
        UsTaxINR=$taxInr
        Qtr=(OsQuarter $dv.Pay)
    })
}
$divIncomeInr = ($divRows | Measure-Object INR -Sum).Sum
if ($UsTaxWithheldUsd -gt 0) {
    # Manual override for mixed-rate years: lump total withheld at the period-end Rule-128 rate.
    $usTaxInr = [math]::Round($UsTaxWithheldUsd * (TTBR (Get-PrevMonthEnd $divEnd)))
    $usTaxSrc = "override: `$$UsTaxWithheldUsd withheld"
} else {
    # Derived per-dividend at each payment's Rule-128 rate using the treaty NRA rate.
    $usTaxInr = ($divRows | Measure-Object UsTaxINR -Sum).Sum
    $usTaxSrc = "{0:P0} of dividends (W-8BEN treaty rate)" -f $NraRate
}

Write-Host ""
Write-Host "Schedule OS / FSI - Foreign dividend income ($periodLabel)" -ForegroundColor Cyan
$divRows | Format-Table -AutoSize
Write-Host ("Total foreign dividend income : INR {0}" -f $divIncomeInr) -ForegroundColor Cyan
Write-Host ("US tax withheld ($usTaxSrc) : INR $usTaxInr  (Form 67 / DTAA relief)") -ForegroundColor Cyan

$osQ = @{}
foreach ($b in 'Upto 15/6','16/6-15/9','16/9-15/12','16/12-15/3','16/3-31/3') { $osQ[$b] = 0 }
foreach ($r in $divRows) { $osQ[$r.Qtr] += $r.INR }
Write-Host "Schedule OS quarterly breakdown:" -ForegroundColor DarkGray
$osQ.GetEnumerator() | Sort-Object Name | ForEach-Object { "  {0,-12} {1}" -f $_.Key, $_.Value }

$divCsv = Join-Path $OutDir "ScheduleFA_Dividends_$($DividendBasis)$Year.csv"
$divRows | Export-Csv -Path $divCsv -NoTypeInformation

# ---------------------------------------------------------------------------
# HTML report (Schedule FA Table A3 + dividend schedule)
# ---------------------------------------------------------------------------
$entity = $EntityName
$addr   = "$EntityAddress $EntityZip"
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append(@"
<!DOCTYPE html><html><head><meta charset='utf-8'><title>Schedule FA CY$Year</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b}
h1{font-size:20px}h2{font-size:16px;color:#0b5394;margin-top:28px}
table{border-collapse:collapse;width:100%;margin-top:8px;font-size:13px}
th,td{border:1px solid #ccc;padding:6px 8px;text-align:right}
th{background:#eef3fa;text-align:center}td.l,th.l{text-align:left}
tfoot td{font-weight:bold;background:#f7f9fc}
.small{color:#666;font-size:12px}
</style></head><body>
<h1>Schedule FA - Foreign Assets (ITR-2) - Calendar Year $Year</h1>
<p class='small'>Country: 2 - UNITED STATES OF AMERICA &nbsp;|&nbsp; Entity: $entity, $addr (Listed Company)<br>
Closing rate: SBI TTBR $closeRate on $yEnd &nbsp;|&nbsp; MSFT close `$$closePrice<br>
Values converted using SBI TT Buy Rate. Asset values use the actual-date rate; dividends use Rule 128 (last day of the month preceding the pay date).</p>
<h2>Table A2 - Details of foreign custodial account</h2>
<p class='small'>User-identifying fields are hardcoded placeholders - fill [input_value_here] and [yyyy-mm-dd] with your custodian's details before uploading.</p>
<table><thead><tr>
<th class='l'>Field</th><th class='l'>Value</th></tr></thead><tbody>
<tr><td class='l'>Country/Region name</td><td class='l'>$EntityCountry</td></tr>
<tr><td class='l'>Country Name and Code</td><td class='l'>$EntityCountryCode</td></tr>
<tr><td class='l'>Name of financial institution</td><td class='l'>$A2InstitutionName</td></tr>
<tr><td class='l'>Address of financial institution</td><td class='l'>$A2InstitutionAddress</td></tr>
<tr><td class='l'>ZIP Code</td><td class='l'>$A2Zip</td></tr>
<tr><td class='l'>Account number</td><td class='l'>$A2AccountNumber</td></tr>
<tr><td class='l'>Status</td><td class='l'>$A2Status</td></tr>
<tr><td class='l'>Account opening date</td><td class='l'>$A2OpeningDate</td></tr>
<tr><td class='l'>Peak balance during the period (INR)</td><td>$('{0:N0}' -f $a2Peak)</td></tr>
<tr><td class='l'>Closing balance (INR)</td><td>$('{0:N0}' -f $a2Closing)</td></tr>
<tr><td class='l'>Gross amount paid/credited to the account (INR)</td><td>$('{0:N0}' -f $a2Dividend)</td></tr>
</tbody></table>
<h2>Table A3 - Details of foreign assets and income</h2>
<table><thead><tr>
<th>S.No</th><th>Date of acquiring interest</th><th>Qty</th><th>Source</th>
<th>Initial value (INR)</th><th>Peak value (INR)</th><th>Closing balance (INR)</th>
<th>Gross amount paid/credited (INR)</th><th>Gross proceeds from sale (INR)</th></tr></thead><tbody>
"@)
foreach ($r in $results) {
    [void]$sb.Append("<tr><td>$($r.'S.No')</td><td class='l'>$($r.'Date acquired')</td><td>$($r.Qty)</td><td>$($r.Source)</td><td>$('{0:N0}' -f $r.'Initial (INR)')</td><td>$('{0:N0}' -f $r.'Peak (INR)')</td><td>$('{0:N0}' -f $r.'Closing (INR)')</td><td>$('{0:N0}' -f $r.'Dividend (INR)')</td><td>0</td></tr>")
}
[void]$sb.Append("</tbody><tfoot><tr><td colspan='4' class='l'>TOTAL ($($results.Count) lots)</td><td>$('{0:N0}' -f $tot.Initial)</td><td>$('{0:N0}' -f $tot.Peak)</td><td>$('{0:N0}' -f $tot.Closing)</td><td>$('{0:N0}' -f $tot.Dividend)</td><td>0</td></tr></tfoot></table>")
[void]$sb.Append("<h2>Schedule OS / FSI - Foreign dividend income ($periodLabel)</h2><table><thead><tr><th>Ex-date</th><th>Pay-date</th><th>Shares</th><th>DPS (USD)</th><th>Gross (USD)</th><th>SBI rate</th><th>Income (INR)</th><th>US tax withheld (INR)</th><th>ITR OS quarter</th></tr></thead><tbody>")
foreach ($r in $divRows) {
    [void]$sb.Append("<tr><td class='l'>$($r.Ex)</td><td class='l'>$($r.Pay)</td><td>$($r.Shares)</td><td>$($r.Dps)</td><td>$($r.USD)</td><td>$($r.Rate)</td><td>$('{0:N0}' -f $r.INR)</td><td>$('{0:N0}' -f $r.UsTaxINR)</td><td class='l'>$($r.Qtr)</td></tr>")
}
[void]$sb.Append("</tbody><tfoot><tr><td colspan='6' class='l'>Total foreign dividend income</td><td>$('{0:N0}' -f $divIncomeInr)</td><td>$('{0:N0}' -f $usTaxInr)</td><td></td></tr></tfoot></table>")
[void]$sb.Append("<p class='small'>US tax withheld (NRA, $usTaxSrc): INR $usTaxInr - claim DTAA relief via Form 67 (Schedule FSI / TR).</p>")
[void]$sb.Append("<p class='small'>Generated by Compute-ScheduleFA.ps1. Validated against a prior known-good FY25 filing (peak/closing/dividend exact; initial within &plusmn;INR1 rounding). Not tax advice - verify with your CA.</p></body></html>")

$htmlOut = Join-Path $OutDir "ScheduleFA_Report_CY$Year.html"
[System.IO.File]::WriteAllText($htmlOut, $sb.ToString())
Write-Host "Written: $divCsv" -ForegroundColor Green
Write-Host "Written: $htmlOut" -ForegroundColor Green

return $results

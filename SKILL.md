---
name: schedule-fa-foreign-equity
description: >-
  Compute India ITR-2 "Schedule FA" (foreign assets) disclosure and the related
  foreign dividend income + foreign tax credit for shares held in a US brokerage
  (e.g. Microsoft RSUs/ESPP via Fidelity). Produces the Table A3 per-lot Initial /
  Peak / Closing / Dividend values, the Schedule OS/FSI dividend schedule, and the
  Form 67 foreign-tax-credit figure. Use when a resident Indian taxpayer needs to
  fill Schedule FA for US equity, or to reconcile a filed return.
---

# Schedule FA — Foreign Equity (US shares held via a broker)

## What this skill does

For an Indian tax resident holding US-listed shares (RSU / ESPP / direct), it
computes everything needed to file **Schedule FA (Table A3)** of ITR-2 for a given
**calendar year**, plus the matching **foreign dividend income (Schedule OS/FSI)**
and **foreign tax credit (Schedule TR / Form 67)** on a **financial-year** basis.

Per lot it produces:

| Field | Schedule FA A3 column |
|---|---|
| Initial value of investment (INR) | Col 6 |
| Peak value during the period (INR) | Col 7 |
| Closing balance (INR) | Col 8 |
| Gross amount paid/credited i.e. dividends (INR) | Col 9 |
| Gross proceeds from sale/redemption (INR) | Col 10 |

> **Important scope note.** Schedule FA Table A3 is reported for the **calendar
> year** (1 Jan – 31 Dec). Dividend *income* in Schedule OS and the foreign tax
> credit in Schedule FSI/TR are reported for the Indian **financial year**
> (1 Apr – 31 Mar). This skill computes both bases; do not mix them.

> **Not tax advice.** This automates a defensible methodology validated against a
> prior known-good filing. The taxpayer must verify with a CA.

---

## Inputs the user must provide

1. **Broker lot export** — one row per tax lot. From Fidelity this is the
   *"View by Lots"* export, `MSFT Stock Details.csv`, with columns:
   `Date acquired` (e.g. `Aug-15-2024`), `Quantity`, `Cost basis`,
   `Cost basis/share`, `Value`, `Gain/loss`, `Grant date`,
   `Share source` (**`DO`** = RSU/stock award, **`SP`** = ESPP), `Holding period`.
2. **Ticker** and the **entity's legal name/address** for the A3 form
   (e.g. Microsoft Corporation, One Microsoft Way, Redmond, WA 98052 — a listed
   company). For a different employer, substitute the ticker and adjust the
   dividend + price sources below.
3. **Filing year** (the calendar year for A3; FY is derived as that year's Apr →
   next year's Mar for dividends).
4. **W-8BEN status** — determines the US dividend withholding rate (see §NRA).
5. *(Optional, for validation)* a prior year's known-good Schedule FA output, or
   the broker's year-end statement.

---

## Data sources (all free / public)

| Data | Source | Notes |
|---|---|---|
| **USD→INR TTBR** (SBI TT Buy Rate) | `https://raw.githubusercontent.com/sahilgupta/sbi-fx-ratekeeper/refs/heads/main/csv_files/SBI_REFERENCE_RATES_USD.csv` | Column 1 = date, column 3 = **TT BUY** rate. This is the rate the Income-tax Rules require (TT buying rate of SBI). Forward-fill: use the last published rate **on or before** the target date (weekends/holidays have no row). |
| **MSFT daily OHLC** (Close + High) | Yahoo Finance chart API: `https://query1.finance.yahoo.com/v8/finance/chart/MSFT?period1=<epoch>&period2=<epoch>&interval=1d` with header `User-Agent: Mozilla/5.0` | Returns **unadjusted** OHLC in `chart.result[0].indicators.quote[0]` (`close`, `high`) — these match brokerage statement prices. Fetch from an early year (e.g. 2000) so pre-recent ESPP acquisition dates resolve. **Split caveat:** Yahoo `close` is split-adjusted; MSFT's last split was Feb 2003, so any post-2003 lot is accurate. Do **not** use `adjclose` (dividend-adjusted). |
| **MSFT dividend history** (ex-date, pay-date, DPS) | Microsoft Investor Relations: `https://www.microsoft.com/en-us/investor/dividends-and-stock-history` (downloadable spreadsheet). Cached here as `MSFT_Dividends.csv` (columns `Period, Type, Ex, Pay, Dps`). | **Ex-date** drives which lots are entitled; **Pay-date** drives the conversion rate. Cross-check DPS/pay-dates against your broker statements. |
| **Broker lot data** | User's brokerage export (see Inputs). | Source of truth for quantity, acquisition date, cost basis, share source. |
| **US tax withheld** (for FTC) | Derived (see §NRA), or the broker's per-payment "Non-Resident Tax" line. | Do **not** use the calendar-year 1042-S total against FY income — that CY/FY mismatch under-claims the credit. |

### Data snapshot & refresh
`_work/SBI_USD.csv`, `_work/MSFT_ohlc.csv` and `_work/MSFT_Dividends.csv` are
**committed to this repo** as a versioned, auditable snapshot. This makes runs
deterministic and offline-safe, and lets you reproduce exactly the figures you
filed even if the upstream APIs later change. **Before each year's filing**,
refresh the rate/price series (the dividend history is manual — update it from
Microsoft IR when a new dividend is declared):
```powershell
.\Compute-ScheduleFA.ps1 -Year <YYYY> -LotCsv "<lots>.csv" -RefreshPrices
```
The refresh must run after 31 Dec of the filing year so the year-end close and
December SBI rates are present. Commit the updated CSVs so the snapshot stays
current and auditable.

---

## Methodology (the exact rules)

Let `TTBR(d)` = SBI TT-buy rate on-or-before date `d`. All INR rounded to whole
rupees at the end.

### 1. Which lots to include
Every lot **acquired on or before 31 Dec of the filing year** and **not sold**.
(If a lot was sold, report proceeds in Col 10 and pro-rate the period; the base
case here is buy-and-hold — Fidelity RSUs/ESPP are typically never sold.)

### 2. Initial value (INR) — `qty × FMV_usd × TTBR(acq_date)`
`FMV_usd` at acquisition depends on share source:
- **RSU / award (`DO`)** → `Cost basis/share` from the lot CSV (= FMV at vest).
- **ESPP (`SP`)** → **MSFT market close on the acquisition date** (Yahoo `close`,
  on-or-before). ESPP cost basis is discounted, so use market close, not cost.

### 3. Peak value (INR) — `qty × max_d( High(d) × TTBR(d) )`
over the window `d ∈ [ max(acq_date, 1-Jan-of-year) .. 31-Dec-of-year ]`.
Use the **daily High**, converted at that day's TTBR, and take the max of the
INR product (not max price × separate rate). The window is **clamped to 1 Jan of
the filing year**, so older lots never need pre-year prices for peak.

### 4. Closing balance (INR) — `qty × Close(31-Dec) × TTBR(31-Dec)`
Uses MSFT close on the last trading day on/before 31 Dec and that date's TTBR.

### 5. Dividends (INR) — **Rule 128**
For each dividend where `acq_date ≤ ex_date` and the dividend falls in the
reporting period:
```
dividend_inr = qty × DPS × TTBR( last day of the month IMMEDIATELY PRECEDING pay_date )
```
This is the key subtlety: **asset values use the actual-date rate, but dividend
income uses the rate of the last day of the month *before* the pay month** (Rule
128 — "telegraphic transfer buying rate on the last day of the month immediately
preceding the month in which the income is paid").
- For **A3 Col 9** (calendar-year), include dividends with `pay_date` in
  1 Jan – 31 Dec of the year.
- For **Schedule OS/FSI** (financial-year), include dividends with `pay_date` in
  1 Apr – 31 Mar.

### 6. US NRA withholding (foreign tax credit) — §NRA
US withholds tax on each dividend paid to a non-resident:
- **25%** — India–US DTAA (Art. 10) rate, applies while a **valid W-8BEN** is on
  file. This is the normal case.
- **30%** — statutory NRA rate if the W-8BEN has **lapsed/is missing** (they
  expire ~3 years after signing).

The rate is a property of the **payment year** (W-8BEN status at pay date),
applied to **every** dividend paid that year regardless of when the underlying
lot was acquired. Compute per-dividend and convert at that dividend's Rule-128
rate:
```
us_tax_inr = Σ  qty × DPS × NraRate × TTBR( prev-month-end of pay_date )
```
This reproduces the broker's actual withholding within rounding (verified: derived
$34.78 vs statement $34.75 for one year). Claim this FY-matched figure via
**Form 67 / Schedule FSI / TR** — **not** the calendar-year 1042-S total.

### 7. Sale proceeds (Col 10)
`0` for buy-and-hold. If a lot was sold, enter the gross USD proceeds ×
TTBR(sale date).

### Rounding
Round only final INR values. Banker's vs away-from-zero rounding can cause ±₹1
differences on individual lots — immaterial, but note it when reconciling.

---

## Execution

### Can this be done without the PowerShell script?
**Yes.** Everything above is fully specified — an AI agent with shell + Python (or
any spreadsheet-literate user) can reproduce it from the data sources alone. This
SKILL.md is self-sufficient.

**But bundling the script is recommended** because it is already validated to the
rupee against a known-good prior-year filing, and it removes the risk of a model
re-deriving Rule 128 / the peak window / share-source FMV incorrectly each run.
Two paths:

### Path A — Bundled script (recommended, deterministic)
Run `Compute-ScheduleFA.ps1` (bundled alongside this file). It caches all data in
a `_work` directory and reads the dividend history from `_work/MSFT_Dividends.csv`.
```powershell
# Calendar-year A3 + FY dividend schedule (default DividendBasis = FY)
.\Compute-ScheduleFA.ps1 -Year 2025 -LotCsv ".\MSFT Stock Details.csv" -WorkDir ".\_work"
```
Key parameters: `-Year`, `-LotCsv`, `-WorkDir`, `-OutDir`,
`-DividendBasis CY|FY`, `-NraRate` (default `0.25`; use `0.30` if W-8BEN lapsed),
`-UsTaxWithheldUsd` (override for a mixed-rate year), `-RefreshPrices`.
Outputs: `ScheduleFA_A3_<CY>.csv`, `ScheduleFA_Dividends_<basis>.csv`, and an HTML
report.

### Path B — Fully manual (no script)
An agent should:
1. **Download** the three data files (SBI CSV, Yahoo MSFT OHLC from ~2000→today,
   MSFT dividend history) and the user's lot CSV.
2. Build lookup maps: `TTBR(d)` and `Close(d)`/`High(d)` with on-or-before
   (forward-fill) semantics.
3. For each lot, apply §§2–5 above; for the portfolio, sum per column.
4. Compute the FY dividend schedule and §6 withholding.
5. Emit the A3 table + dividend/FTC schedule.

A compact reference implementation (Python) is fine; the arithmetic is small
(tens of lots × a few hundred trading days).

---

## Validation (always do this)
Before trusting a year's output, **reproduce a known-good prior year**:
- If the user has a known-good filing (from any tool or their CA) last year, run
  this skill for that same year and confirm Peak / Closing / Dividend match and
  Initial within ±₹1.
- Cross-check the **closing** figure against the broker's year-end statement
  (shares × Dec-31 close), and the **dividend** total against the statement's
  ordinary-dividends line.
- Cross-check derived §6 withholding against the statement's total "Non-Resident
  Tax" for the same period.

---

## Common pitfalls
- **CY vs FY mismatch** — A3 is calendar-year; dividend income + FTC are
  financial-year. Using the CY 1042-S withholding against FY income under-claims
  the foreign tax credit.
- **Wrong rate column** — use SBI **TT BUY** (col 3), not TT sell or the mid rate.
- **Rule 128 date** — dividends convert at the **prev-month-end of pay date**, not
  the pay date itself and not the ex-date.
- **ESPP initial value** — use market close at acquisition, not the discounted
  cost basis.
- **Peak** — daily **High** (not close), max of the INR product, window clamped to
  1 Jan of the year.
- **Placement on the form** — listed foreign shares belong in **Table A3 (Foreign
  Equity & Debt Interest)**. Reporting them only under Section B (Financial
  Interest) or A2 (Custodial Account) omits the required Peak/Closing values.
- **Split-adjusted prices** — only relevant for pre-2003 MSFT dates; ignore for any
  realistic current-employee lot.

## Adapting to another company / broker
- Replace the **ticker** in the Yahoo URL and the **entity name/address** in A3.
- Replace the **dividend history** source with that company's IR dividend page.
- Map the broker's lot export columns to: acquisition date, quantity, cost
  basis/share, and a share-source flag (award vs purchase-plan) so the correct
  FMV rule is applied.
- The SBI TTBR source, Rule 128, and NRA logic are unchanged for any US equity.

# Schedule FA — Foreign Assets filing helper

Compute India **ITR‑2 "Schedule FA"** (foreign assets) plus the matching foreign
**dividend income** and **foreign tax credit** for US shares held via a broker
(built for **Microsoft RSUs/ESPP via Fidelity**, adaptable to any US equity).

> ⚠️ **Not tax advice.** This automates a defensible, validated methodology. Verify
> the output with a CA before filing.

---

## TL;DR — how to file foreign assets

1. **Export your lots** from the broker (Fidelity's `View open lots.csv`). 
2. **Refresh data & run** (after 31 Dec of the year you're filing for):
   ```powershell
   .\Compute-ScheduleFA.ps1 -Year 2025 -LotCsv ".\View open lots.csv" -RefreshPrices
   ```
3. **Read the output** (`ScheduleFA_A3_CY2025.csv` + the HTML report) — Table A3
   per lot (Initial / Peak / Closing / Dividend, INR), the FY dividend total, and
   the US tax withheld.
4. **Validate** against last year's known‑good numbers and your broker's year‑end
   statement (see the script's regression check).
5. **File on the ITR portal**:
   - **Schedule FA → Table A3** — one row per lot: Initial / Peak / Closing /
     Dividend (INR).
   - **Schedule OS** — add the foreign dividend total to your dividend income.
   - **Schedule FSI + TR (Form 67)** — claim the US tax withheld as foreign tax
     credit.
   - **Answer "Yes"** to the "held foreign assets / income outside India?"
     question, and keep the generated report + statements for your records.

Full methodology, data sources, and a script‑free manual path are in
[`SKILL.md`](./SKILL.md).

---

## The two calendars — don't mix them

This is the single most common mistake.

| What you report | Period | Where |
|---|---|---|
| **Assets** (Initial / Peak / Closing value of shares) | **Calendar Year** — 1 Jan → 31 Dec | Schedule FA, Table A3 |
| **Dividend income** | **Financial Year** — 1 Apr → 31 Mar | Schedule OS |
| **Foreign tax credit** on those dividends | **Financial Year** — 1 Apr → 31 Mar | Schedule FSI / TR + Form 67 |

So for **AY 2026‑27** you disclose assets held during **CY 2025**, but the dividend
income + credit are for **FY 2025‑26**. The script computes both bases.

> The US 1042‑S tax statement is **calendar‑year**. Using its withholding total
> against **financial‑year** income under‑claims your credit — compute the
> FY‑matched figure instead (the script does this).

---

## The date & conversion rules

All INR conversion uses the **SBI TT Buy Rate (TTBR)** — the rate the Income‑tax
Rules require. When a date has no published rate (weekend/holiday), use the last
rate **on or before** that date.

| Value | Rate date | Price used |
|---|---|---|
| **Initial value** | TTBR on the **acquisition date** | RSU: cost basis/share · ESPP: market close on acq date |
| **Peak value** | TTBR on **each day**, take the max INR | daily **High**, over `[max(acq, 1‑Jan) … 31‑Dec]` |
| **Closing value** | TTBR on **31 Dec** | MSFT close on 31 Dec |
| **Dividend** (Rule 128) | TTBR on the **last day of the month *before* the pay month** | declared dividend‑per‑share |
| **US tax withheld** | same Rule‑128 date as each dividend | 25% (valid W‑8BEN) or 30% (lapsed) |

Key subtleties:
- **Rule 128**: dividends (and their foreign tax) convert at the rate of the *last
  day of the month preceding the pay date* — **not** the pay date, **not** the
  ex‑date. Asset values, by contrast, use the actual transaction date.
- **Peak** uses the daily **High** (not close), and the window starts at **1 Jan**
  of the filing year — so old lots never need pre‑year prices for peak.
- **ESPP initial value** uses the **market close** at purchase, not the discounted
  cost basis.
- **W‑8BEN**: with a valid form on file, US withholds **25%** (India‑US DTAA);
  if it lapses (expires ~3 yrs), **30%**. The rate applies to every dividend paid
  that year, regardless of when the shares were acquired.

---

## Where it goes on the ITR

- **Table A3 — Foreign Equity & Debt Interest**: this is the correct place for
  listed foreign shares. Reporting them only under Section B (financial interest)
  or A2 (custodial account) omits the required Peak/Closing values.
- **Schedule OS**: foreign dividends add to "Dividend income".
- **Schedule FSI / TR + Form 67**: claim the US withholding as DTAA relief
  (section 90). **Form 67 must be filed before/with the return** for the credit.

---

## Data sources

| Data | Source |
|---|---|
| USD→INR TTBR | SBI reference rates — `sahilgupta/sbi-fx-ratekeeper` (GitHub) |
| MSFT daily prices | Yahoo Finance chart API (unadjusted OHLC) |
| MSFT dividend history | Microsoft Investor Relations dividends page |
| Your lots | Broker export |

The rate/price/dividend CSVs are **committed under `_work/`** as a versioned,
auditable snapshot — so runs are deterministic and reproducible even if the
upstream APIs change. Refresh them before each year's filing with `-RefreshPrices`
and re‑commit.

---

## Files

```
SKILL.md                    Full methodology + data sources (AI-agent skill)
Compute-ScheduleFA.ps1      The computation engine
_work/SBI_USD.csv           SBI TTBR snapshot        (committed)
_work/MSFT_ohlc.csv         MSFT daily OHLC snapshot (committed)
_work/MSFT_Dividends.csv    MSFT dividend history    (committed)
```

## Script parameters

`-Year` · `-LotCsv` · `-WorkDir` · `-OutDir` · `-DividendBasis CY|FY` (default FY)
· `-NraRate` (default 0.25; use 0.30 if W‑8BEN lapsed) · `-UsTaxWithheldUsd`
(override for a mixed‑rate year) · `-RefreshPrices`.

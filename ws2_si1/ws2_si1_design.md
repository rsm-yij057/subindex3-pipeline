# WS2 Sub-Index 1 — Installed and Committed Capacity
**Design Document (for team discussion before implementation)**

**Project:** UCSD Rady MSBA Capstone — Chessboard Sovereign Index (CSI)
**Workstream 2:** Compute Infrastructure Index (CII), weight 40% of CII total
**Sub-Index 1:** Installed and Committed Capacity, weight 40% of WS2
**Document version:** v0.1 (draft for review)
**Author note:** This document distills the CSI Scope Doc (pp. 7, 16) into an executable plan. Open questions for the team are flagged as **[Q]** throughout.

---

## 1. Purpose & scope

Per the CSI Scope Doc (p. 7):

> *Measures current operational AI compute capacity and the committed pipeline.*

In one sentence: **"How much AI-relevant data center capacity is each country running today, how much is in the pipeline, and how concentrated is that pipeline relative to the installed base?"**

What this sub-index does **not** cover (handled elsewhere in WS2):
- Growth velocity / quarter-over-quarter rate → **WS2 SI2**
- Quality of compute (chip generation, hyperscaler diversity, training presence) → **WS2 SI3**

What it does cover that is unique to SI1:
- A **facility-level master database** of every relevant data center in the 6-country universe, refreshed quarterly. This database is reused as the single source of truth for SI2 (which derives growth from SI1's quarterly snapshots) and partially for SI3 (which adds chip/operator metadata to the same facility records).

---

## 2. Country universe

Same 6 countries as WS1 SI3, no additions:

| Country | M49 | ISO3 | CSI archetype |
|---|---|---|---|
| USA | 842 | USA | Benchmark / AI Superpower |
| UAE | 784 | ARE | Substrate Superpower |
| Brazil | 076 | BRA | High-substrate, low-governance |
| India | 356 | IND | Complex / bifurcated |
| Singapore | 702 | SGP | Processor under pressure |
| Philippines | 608 | PHL | Structural short |

---

## 3. Sub-index decomposition

Per the scope doc, WS2 has 3 sub-indices and SI1 is **one** of them. For full context:

| ID | Name | Weight | Owner |
|---|---|---|---|
| **WS2 SI1** | **Installed and Committed Capacity** | **40%** | **← this document** |
| WS2 SI2 | Growth Velocity | 35% | (separate scope) |
| WS2 SI3 | Compute Quality and Access | 25% | (separate scope) |

**`CII = 0.40 × SI1 + 0.35 × SI2 + 0.25 × SI3`**

---

## 4. Metrics table — WS2 SI1

The scope doc lists **4 metrics** for SI1. The scoring formula uses **3 of them**. The 4th (investment value) is collected as part of the facility database but is not in the composite formula — see **[Q1]**.

| # | Metric code | Display name | Unit | Granularity | Used in score? | Weight in score |
|---|---|---|---|---|---|---|
| 1 | `installed_capacity_mw` | Installed data center capacity | MW | Country-quarter | ✅ Yes | **0.40** |
| 2 | `pipeline_capacity_mw` | Permitted / under-construction capacity | MW | Country-quarter | ✅ Yes | **0.40** |
| 3 | `pipeline_multiplier` | Pipeline ÷ installed | ratio | Country-quarter | ✅ Yes | **0.20** |
| 4 | `committed_investment_usd` | Total committed hyperscaler investment value | USD | Country-quarter | ❌ Diagnostic only | 0 (overlay) |

**Scoring formula (per scope doc p. 7):**

```
SI1_score = 0.40 × normalize(installed_capacity_mw)
          + 0.40 × normalize(pipeline_capacity_mw)
          + 0.20 × normalize(pipeline_multiplier)
```

Where `normalize(x)` = min-max scaling to 0–100 across the 6-country universe (per the common methodology, p. 4).

> **[Q1] — Decision needed:** The scope doc lists `committed_investment_usd` as a metric but omits it from the scoring formula. Three options:
> - **A.** Treat as diagnostic overlay only (default — what this doc currently assumes; mirrors how `yoy_growth` and `value_add_ratio` are handled in WS1 SI3).
> - **B.** Re-allocate the 0.20 multiplier weight as e.g. 0.10 multiplier + 0.10 investment.
> - **C.** Add it as a 4th term and re-base existing weights to sum to 1.0.
> Recommend **A** to stay literal to the scope doc; flag in the methodology paper as a documented deviation if (B) or (C) is chosen.

> **[Q2] — Status taxonomy:** The scope doc defines 4 statuses for the facility database — `operational`, `permitted`, `under_construction`, `announced`. Only the first 3 cleanly map to the 2 score metrics:
> - `installed_capacity_mw` = sum of `operational`
> - `pipeline_capacity_mw` = sum of `permitted` + `under_construction`
>
> Where does `announced` go? Three options:
> - **A.** Exclude from both (most conservative; "announced" projects often slip or cancel).
> - **B.** Include in pipeline (most generous; matches how DC industry reports the "total commitment").
> - **C.** Include in pipeline but with a 0.5 weight (compromise).
> Recommend **A** for the headline score + report (B) as a sensitivity in the methodology paper.

> **[Q3] — "AI-relevant" filter:** Should we include all data centers, or only those above a capacity threshold (e.g. ≥10 MW), or only those with hyperscaler/colo operators? Filtering matters because:
> - Singapore alone has dozens of small enterprise DCs that aren't running AI training;
> - Including them inflates Singapore's installed total but they don't represent AI compute capacity.
> Three options:
> - **A.** No filter (most data, most noise).
> - **B.** ≥10 MW threshold (matches DC Byte's "wholesale colo" cutoff and the typical AI-cluster minimum).
> - **C.** Operator-based filter (only major hyperscalers + colo: AWS / Azure / GCP / Meta / Equinix / Digital Realty / NTT / etc.).
> Recommend **B** as the headline + (A) as a sensitivity test.

---

## 5. The facility-level master database

This is the **core deliverable** of SI1. Country-level metrics are computed by aggregating this table.

### 5.1 Required schema (from scope doc, p. 7, verbatim)

| Field | Type | Source-derivable? | Notes |
|---|---|---|---|
| `country` | varchar | ✅ | Always one of the 6 target countries |
| `facility_name` | varchar | ✅ | Often "Operator Campus N" — keep verbatim from source |
| `operator` | varchar | ✅ | Owner / operator (e.g. AWS, Equinix MA5) |
| `capacity_mw` | numeric | ✅ | Critical IT load if reported; gross MW otherwise (note in `notes`) |
| `status` | enum | ✅ | `operational` / `permitted` / `under_construction` / `announced` |
| `date_announced` | date | ⚠️ Partial | Often not disclosed; will be NULL frequently |
| `date_operational` | date | ⚠️ Partial | NULL for non-operational facilities |
| `investment_value_usd` | numeric | ⚠️ Partial | Only disclosed for hyperscaler announcements |
| `energy_source` | varchar | ⚠️ Partial | "renewable" / "grid" / "natural gas" / "mixed" / NULL |
| `chip_type_if_known` | varchar | ⚠️ Partial | "H100" / "B200" / "MI300" / "TPU v5" / NULL — primarily used by SI3 |

### 5.2 Suggested PostgreSQL DDL (preview only — full DDL in the schema phase)

To stay aligned with the SI1 / SI3 pattern (single database, per-workstream prefix):

```sql
-- Facility master table (the heart of WS2)
ws2_facilities                  -- one row per data center facility
ws2_facility_snapshots          -- quarterly snapshots of capacity_mw + status (so SI2 can compute deltas)
ws2_si1_country_metrics         -- aggregated country-quarter metrics (the 4 metrics in §4)
ws2_si1_scores                  -- normalized 0-100 scores per country-quarter

-- Reused / shared with SI1 / SI3 conventions:
ws2_collection_runs, ws2_collection_log, ws2_data_gaps
v_ws2_si1_completeness, v_ws2_si1_latest, v_ws2_si1_recent_runs
```

> **[Q4] — Schema co-location:** Should WS2 live in the **same database** as WS1 (`subindex_3` / `subindex_1`), or its own database (`subindex_csi` shared, or `compute_index` separate)? The scope doc (p. 4) says: *"Each workstream maintains its own schema but all must be joinable on country and time period for integration."* This implies one shared database with workstream-prefixed schemas (e.g. `ws1.si3_*`, `ws2.si1_*`). Recommend **one shared database** (`csi`) with one schema per workstream. **Confirm before DDL is written.**

---

## 6. Data sources

The scope doc (p. 16) lists multiple data sources for "Data Centers and Compute". Not all are equal — here's the recon plan:

### 6.1 Primary candidates (recon needed)

| Source | Access | Coverage | Format | Pros | Cons |
|---|---|---|---|---|---|
| **DC Byte** | Academic license — needs request | Global, all 6 countries | Web app + CSV export | Industry gold standard; facility-level; status field; quarterly updates | Requires institutional license; not free; license terms may restrict redistribution |
| **Cushman & Wakefield Global Data Center Market Comparison** | Free annual PDF report | Top ~50 markets globally; covers USA, India, Singapore at city level; Brazil and UAE limited | PDF | Free; respected source; capacity numbers | Annual not quarterly; market-level not facility-level; Philippines coverage thin |
| **Hyperscaler SEC filings (10-K / 10-Q)** | Free (EDGAR) | USA + global presence of US hyperscalers | XBRL / HTML | Authoritative for committed investment USD; quarterly | Capex aggregated globally — country split rarely disclosed; only covers AWS / Azure / Meta / Google's own facilities |
| **National regulatory filings** (large-load permit applications) | Free, varies by country | Country-by-country: e.g. Virginia SCC, ERCOT in USA; EMA in Singapore | PDF / web forms | Authoritative for permitted MW | Each country needs custom scraper; UAE and Philippines may not publish |
| **Data Center Dynamics + DatacenterHawk + The Information** | Free articles / paid newsletter | Global news coverage | News articles | Captures announcements early | Unstructured; requires NLP or manual extraction |
| **Hyperscaler press releases + investor day decks** | Free | Major announcements | HTML / PDF | Authoritative for `date_announced` and `investment_value_usd` | Coverage is uneven (UAE often not disclosed) |
| **Ember / IEA / national grid operator load forecasts** | Free, varies | Power sector view of large-load growth | CSV / API | Cross-checks DC Byte's MW numbers | Doesn't disaggregate by facility |

### 6.2 Recommended source hierarchy

For each `(country, facility)` row:

1. **Tier 1 (preferred):** DC Byte → if license obtained, this becomes the primary source for ~80% of fields
2. **Tier 2 (cross-check):** Cushman & Wakefield + national regulator filings
3. **Tier 3 (gap fill):** News articles + press releases (with citation)

**Provenance is mandatory** (per scope doc p. 4): every row in `ws2_facilities` must record `source`, `source_url`, `date_collected` so the data is fully auditable.

> **[Q5] — DC Byte access:** Has anyone on the team / through Rady requested DC Byte academic access? **This is the most important early-blocking decision.** If DC Byte is unavailable, the project pivots to a Cushman + regulator + news scraping approach, which is roughly **3× more work** for materially worse coverage on UAE and Philippines.

> **[Q6] — Manual vs. automated collection:** Given the unstructured nature of facility data, the scope doc explicitly mandates handling diverse source types (p. 4). Realistic split:
> - **~40% automated** (SEC EDGAR, regulator portals with structured data, hyperscaler region APIs where they exist)
> - **~60% manual + LLM-assisted** (news articles, press releases, DC Byte exports)
> The pipeline therefore needs a **manual-entry interface** with provenance enforcement (probably a CSV template with required columns + a validation script) — not just API ingest like SI3. **Confirm scope.**

### 6.3 Per-country expected coverage

| Country | Primary source | Expected gaps | Mitigation |
|---|---|---|---|
| USA | DC Byte + state regulators (Virginia, Texas) | None expected — US market is most-covered | — |
| Singapore | DC Byte + EMA / IMDA | Some operational MW disclosure restricted | Cushman cross-check |
| India | DC Byte + power-purchase filings | Tier-2 cities undercounted | News scraping for announcements |
| Brazil | DC Byte + ANEEL | Status field often "announced" — slips frequent | Conservative on `announced` |
| UAE | Press releases + sovereign vehicle disclosures | DC Byte coverage thin pre-2024; G42 / Mubadala disclosures sparse | Manual collection with high citation discipline |
| Philippines | News articles + PEZA filings | Lowest coverage | Accept low-confidence flag in `data_gaps` |

---

## 7. Refresh cadence

Scope doc (p. 4): **quarterly**. Concrete cycle:

| Phase | Timing | Activity |
|---|---|---|
| Quarter snapshot | Within 30 days of quarter-end | Re-fetch DC Byte, regulator filings, news; update `ws2_facility_snapshots` |
| Reconciliation | Days 30–45 | Cross-check DC Byte vs. Cushman vs. news; resolve conflicts; log to `ws2_data_gaps` |
| Score computation | Days 45–60 | Recompute country-quarter metrics + scores; sensitivity-test |
| Methodology update | Days 60–90 | Document any source changes, weight changes, escalations |

The scope doc also says (p. 4): *"All time-series metrics should be structured for rolling 4-quarter calculations."* — This means SI1 needs to retain at least 4 quarters of `ws2_facility_snapshots` so SI2 can compute QoQ deltas without re-collection.

---

## 8. Sensitivity analysis (mandatory per scope doc p. 4)

Required tests for SI1:

1. **±10 percentage points** on each of the 3 score weights (0.40 / 0.40 / 0.20):
   - Does country ranking change if installed = 0.50, pipeline = 0.30?
   - Does country ranking change if multiplier weight = 0.30 instead of 0.20?
2. **`announced` inclusion** (per [Q2]): Does headline ranking differ between excluding `announced` vs. including with 0.5 weight?
3. **Capacity threshold** (per [Q3]): How does Singapore's score change between no-filter and ≥10 MW?
4. **Source dependency**: If DC Byte is replaced with Cushman + news only, does the ranking change?

Document all 4 sensitivities in the methodology paper.

---

## 9. Known risks & escalations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| DC Byte access denied | Medium | High | Cushman + regulator + news fallback; document as limitation |
| UAE facility data sparse | High | Medium | Higher reliance on press releases; flag in `data_gaps`; conservative `announced` policy |
| Philippines facility data near-absent | High | Medium | Same as UAE; may need to score with low-confidence flag |
| `capacity_mw` definitions inconsistent (gross MW vs. critical IT MW) | High | High | Pick "critical IT MW" as canonical; convert gross MW with documented multiplier (typically 0.6× for hyperscaler colo) |
| Hyperscaler investment_value_usd given as multi-country aggregate (e.g. "$10B in MEA") | High | Low (since this metric is diagnostic only per [Q1]) | Document and exclude from country attribution unless single-country deal |
| Status changes mid-quarter (e.g. "announced" → "under_construction") | High | Medium | Snapshot at quarter-end only; intra-quarter changes appear in next quarter |
| Currency conversion for `investment_value_usd` | Medium | Low | Convert to USD using IMF quarter-end rate; document FX assumption |

---

## 10. Open questions summary (consolidated)

| ID | Question | Recommendation | Need answer by |
|---|---|---|---|
| **Q1** | How to handle `committed_investment_usd` (in scope but not in formula)? | Diagnostic overlay only; sensitivity test as alternative | Before DDL |
| **Q2** | Does `announced` count as pipeline? | No (conservative); sensitivity-test inclusion | Before scoring |
| **Q3** | "AI-relevant" capacity threshold? | ≥10 MW; sensitivity-test no-filter | Before facility ingest |
| **Q4** | Database / schema co-location with WS1? | One shared `csi` database with per-workstream schema | Before DDL |
| **Q5** | DC Byte academic access secured? | **Critical — blocks ~80% of data plan** | Week 1 |
| **Q6** | Manual collection workflow scope? | Yes — CSV template + validation, ~60% of facility data | Week 2 |

---

## 11. Proposed deliverables (mirroring WS1 SI3 pattern)

To stay consistent with the WS1 SI3 deliverables already in the team's GitHub:

| # | Artifact | Path (suggested) | Purpose |
|---|---|---|---|
| 1 | This design doc (final) | `docs/ws2_si1_design.md` | Methodology spec |
| 2 | PostgreSQL DDL | `schema/ws2_si1.sql` | Tables, views, seed data |
| 3 | Ingest notebook | `WS2_SI1_facility_ingest.ipynb` | DC Byte / regulator / news ingestion |
| 4 | Scoring notebook | `WS2_SI1_scoring.ipynb` | Aggregation + min-max + sensitivities |
| 5 | Manual entry template | `templates/ws2_si1_facility_template.csv` | For sources without machine-readable feeds |
| 6 | Methodology paper section | `docs/ws2_methodology.md` (SI1 section) | Final write-up |

---

## 12. Suggested next-step ordering

Once Q1–Q6 are resolved:

1. **Week 1**: Resolve Q5 (DC Byte access). Lock Q1–Q4. Draft PostgreSQL DDL based on resolved decisions.
2. **Week 2**: Build manual entry template + validation script (Q6). Pilot data collection on USA (highest-coverage country) to stress-test the schema.
3. **Week 3**: Add Singapore + India (medium-coverage). Build aggregation logic.
4. **Week 4**: Add Brazil + UAE + Philippines (low-coverage). First end-to-end score computation.
5. **Week 5**: Sensitivity tests + methodology paper draft.

---

*End of design document v0.1. Next iteration after team review of Q1–Q6.*

-- =============================================================================
--  WS2 SI1 — Installed and Committed Capacity
--  Database: csi  (shared across all workstreams, per design Q4)
--  Schema:   ws2  (one schema per workstream)
--
--  Design decisions baked in (per design doc v0.2):
--    Q1: committed_investment_usd = diagnostic overlay only (not in score)
--    Q2: 'announced' status NOT counted as pipeline by default
--        (sensitivity test query provided at end of file)
--    Q3: ≥10 MW threshold for "AI-relevant" capacity (configurable)
--    Q4: Shared csi database with per-workstream schemas
--    Q5: Multi-source ingest design — no DC Byte hard dependency
--    Q6: Manual entry workflow supported via insert_method column
--
--  Architecture:
--    facilities                  ← facility master (one row per data center)
--    facility_snapshots          ← quarterly snapshots (for SI2 QoQ deltas)
--    si1_country_metrics         ← aggregated country-quarter metrics
--    si1_country_scores          ← normalized 0-100 + composite
--    Operational: collection_runs, collection_log, data_gaps
--    Views: v_si1_completeness, v_si1_latest, v_si1_recent_runs
--
--  Apply with:
--    psql -d csi -f schema/ws2_si1.sql
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0. PROJECT-WIDE BOOTSTRAP (idempotent)
-- -----------------------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- for gen_random_uuid()

-- Public schema is reused for cross-workstream dimension tables (countries).
-- Workstream-specific objects live in ws2.
CREATE SCHEMA IF NOT EXISTS ws2;

-- Shared updated_at trigger (define once, reuse everywhere)
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- =============================================================================
-- 1. SHARED DIMENSION TABLE (cross-workstream)
--    countries lives in public schema so WS1, WS2, WS3, WS4 all join to it.
--    If WS1 already created it, the IF NOT EXISTS makes this a no-op.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.csi_countries (
    id              SERIAL      PRIMARY KEY,
    country_name    CITEXT      NOT NULL UNIQUE,
    iso3            CHAR(3)     NOT NULL UNIQUE,
    m49_code        CHAR(3)     NOT NULL UNIQUE,
    archetype       TEXT,                                   -- per CSI scope doc p. 2-3
    is_target       BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS trg_csi_countries_updated ON public.csi_countries;
CREATE TRIGGER trg_csi_countries_updated
    BEFORE UPDATE ON public.csi_countries
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.csi_countries (country_name, iso3, m49_code, archetype) VALUES
    ('USA',         'USA', '842', 'AI Superpower / Benchmark'),
    ('UAE',         'ARE', '784', 'Substrate Superpower'),
    ('Brazil',      'BRA', '076', 'High Substrate, Low Governance'),
    ('India',       'IND', '356', 'Complex / Bifurcated'),
    ('Singapore',   'SGP', '702', 'Processor Under Pressure'),
    ('Philippines', 'PHL', '608', 'Structural Short')
ON CONFLICT (country_name) DO NOTHING;


-- =============================================================================
-- 2. WS2 OPERATIONAL TABLES (mirror WS1 SI1's pattern)
-- =============================================================================

-- 2.1 collection_runs ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS ws2.collection_runs (
    id              SERIAL      PRIMARY KEY,
    run_uuid        UUID        NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    pipeline_name   TEXT        NOT NULL,                   -- 'sec_edgar_capex', 'manual_csv_load', etc.
    source_name     TEXT,                                   -- 'DC Byte', 'Cushman 2026', 'manual'
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at     TIMESTAMPTZ,
    status          TEXT        NOT NULL DEFAULT 'running',
    rows_attempted  INT         NOT NULL DEFAULT 0,
    rows_succeeded  INT         NOT NULL DEFAULT 0,
    rows_failed     INT         NOT NULL DEFAULT 0,
    triggered_by    TEXT,
    notes           TEXT,
    CHECK (status IN ('running','success','partial','failed','cancelled'))
);

CREATE INDEX IF NOT EXISTS idx_ws2_runs_pipeline ON ws2.collection_runs(pipeline_name);
CREATE INDEX IF NOT EXISTS idx_ws2_runs_started  ON ws2.collection_runs(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_ws2_runs_status   ON ws2.collection_runs(status);


-- 2.2 collection_log -----------------------------------------------------------
CREATE TABLE IF NOT EXISTS ws2.collection_log (
    id              SERIAL      PRIMARY KEY,
    run_id          INT         NOT NULL REFERENCES ws2.collection_runs(id) ON DELETE CASCADE,
    country_id      INT         REFERENCES public.csi_countries(id) ON DELETE SET NULL,
    facility_id     INT,                                    -- FK added later (forward ref)
    action          TEXT        NOT NULL,                   -- 'insert','update','skip','validate_fail'
    status          TEXT        NOT NULL,
    error_message   TEXT,
    duration_ms     INT,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (status IN ('success','no_data','http_error','parse_error','validation_error','rate_limited','skipped'))
);

CREATE INDEX IF NOT EXISTS idx_ws2_log_run    ON ws2.collection_log(run_id);
CREATE INDEX IF NOT EXISTS idx_ws2_log_status ON ws2.collection_log(status);


-- 2.3 data_gaps ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ws2.data_gaps (
    id                  SERIAL      PRIMARY KEY,
    country_id          INT         NOT NULL REFERENCES public.csi_countries(id) ON DELETE CASCADE,
    quarter             DATE        NOT NULL,               -- 1st of Jan/Apr/Jul/Oct
    gap_type            TEXT        NOT NULL,
    severity            TEXT        NOT NULL DEFAULT 'medium',
    detected_in_run     INT         REFERENCES ws2.collection_runs(id) ON DELETE SET NULL,
    notes               TEXT,
    is_resolved         BOOLEAN     NOT NULL DEFAULT FALSE,
    resolved_at         TIMESTAMPTZ,
    detected_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (gap_type IN ('missing_facility','status_unknown','capacity_unknown','operator_unknown','source_conflict','low_confidence')),
    CHECK (severity IN ('low','medium','high')),
    CHECK (EXTRACT(MONTH FROM quarter) IN (1,4,7,10) AND EXTRACT(DAY FROM quarter) = 1)
);

CREATE INDEX IF NOT EXISTS idx_ws2_gaps_unresolved ON ws2.data_gaps(is_resolved) WHERE NOT is_resolved;
CREATE INDEX IF NOT EXISTS idx_ws2_gaps_quarter    ON ws2.data_gaps(quarter);


-- =============================================================================
-- 3. FACILITY MASTER TABLE
--    The heart of WS2 SI1. One row per data center facility.
--    Schema follows the CSI Scope Doc p. 7 verbatim, plus provenance fields.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ws2.facilities (
    id                      SERIAL      PRIMARY KEY,

    -- Identity (per scope doc p. 7) ----------------------------------------
    country_id              INT         NOT NULL REFERENCES public.csi_countries(id),
    facility_name           TEXT        NOT NULL,           -- "Operator Campus N" verbatim from source
    operator                TEXT,                           -- AWS, Equinix, NTT, G42, etc.
    city                    TEXT,                           -- helps disambiguate when name reused
    region                  TEXT,                           -- state / emirate / metro

    -- Capacity --------------------------------------------------------------
    capacity_mw             NUMERIC(10,3),                  -- canonical: critical IT MW
    capacity_basis          TEXT NOT NULL DEFAULT 'critical_it',  -- 'critical_it' | 'gross' | 'unknown'
    -- For sensitivity testing per Q3, also track if facility passes the AI-relevance bar.
    -- Computed deterministically by trigger below; do not write directly.
    is_ai_relevant          BOOLEAN     NOT NULL DEFAULT TRUE,

    -- Status (per scope doc p. 7) ------------------------------------------
    status                  TEXT        NOT NULL,
    date_announced          DATE,
    date_operational        DATE,                           -- NULL until operational
    expected_operational    DATE,                           -- for permitted/under_construction

    -- Diagnostic fields (Q1: not in score) ----------------------------------
    investment_value_usd    NUMERIC(18,2),
    investment_currency     CHAR(3),                        -- if not USD, store original; convert on read
    investment_fx_rate      NUMERIC(12,6),                  -- if converted, the rate used
    investment_fx_date      DATE,                           -- date of FX conversion

    -- Cross-SI fields (used by SI3, but collected here once) ----------------
    energy_source           TEXT,                           -- 'renewable'|'grid'|'natural_gas'|'mixed'|NULL
    chip_type_if_known      TEXT,                           -- 'H100'|'B200'|'MI300'|'TPU v5'|NULL

    -- Provenance (mandatory per scope doc p. 4) ----------------------------
    primary_source          TEXT        NOT NULL,           -- 'DC Byte'|'Cushman 2026'|'SEC 10-K AMZN 2025Q3'|...
    source_url              TEXT,
    source_collected_date   DATE        NOT NULL,           -- when WE pulled this datum
    source_published_date   DATE,                           -- when SOURCE published it
    insert_method           TEXT        NOT NULL DEFAULT 'manual',  -- 'manual'|'api'|'scrape'|'csv_import'
    confidence              TEXT        NOT NULL DEFAULT 'medium',  -- 'high'|'medium'|'low'
    notes                   TEXT,

    -- Audit -----------------------------------------------------------------
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by_run          INT         REFERENCES ws2.collection_runs(id) ON DELETE SET NULL,

    CHECK (status IN ('operational','under_construction','permitted','announced','cancelled','decommissioned')),
    CHECK (capacity_basis IN ('critical_it','gross','unknown')),
    CHECK (insert_method IN ('manual','api','scrape','csv_import')),
    CHECK (confidence IN ('high','medium','low')),
    CHECK (capacity_mw IS NULL OR capacity_mw > 0),
    CHECK (date_operational IS NULL OR date_announced IS NULL OR date_operational >= date_announced),
    -- One facility name per (country, operator, city) — surfaces duplicates on import
    UNIQUE (country_id, operator, facility_name, city)
);

CREATE INDEX IF NOT EXISTS idx_ws2_fac_country  ON ws2.facilities(country_id);
CREATE INDEX IF NOT EXISTS idx_ws2_fac_status   ON ws2.facilities(status);
CREATE INDEX IF NOT EXISTS idx_ws2_fac_operator ON ws2.facilities(operator);
CREATE INDEX IF NOT EXISTS idx_ws2_fac_ai_rel   ON ws2.facilities(is_ai_relevant) WHERE is_ai_relevant;

DROP TRIGGER IF EXISTS trg_ws2_fac_updated ON ws2.facilities;
CREATE TRIGGER trg_ws2_fac_updated
    BEFORE UPDATE ON ws2.facilities
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- 3.1 AI-relevance derived flag (Q3) -------------------------------------------
-- Threshold lives in a config table so sensitivity tests can adjust without DDL.
CREATE TABLE IF NOT EXISTS ws2.config (
    key             TEXT        PRIMARY KEY,
    value           TEXT        NOT NULL,
    description     TEXT,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO ws2.config (key, value, description) VALUES
    ('ai_relevance_min_mw', '10',
        'Q3 threshold: facilities below this MW are excluded from headline scoring (sensitivity-test by changing this value).'),
    ('include_announced_in_pipeline', 'false',
        'Q2: whether status=announced contributes to pipeline_capacity_mw (sensitivity-test by toggling).'),
    ('current_quarter', DATE_TRUNC('quarter', CURRENT_DATE)::TEXT,
        'Reference quarter for "latest" views (1st of current quarter).')
ON CONFLICT (key) DO NOTHING;


CREATE OR REPLACE FUNCTION ws2.recalc_ai_relevance()
RETURNS TRIGGER AS $$
DECLARE
    threshold NUMERIC;
BEGIN
    SELECT value::NUMERIC INTO threshold FROM ws2.config WHERE key = 'ai_relevance_min_mw';
    NEW.is_ai_relevant := COALESCE(NEW.capacity_mw, 0) >= threshold;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_ws2_fac_ai_relevance ON ws2.facilities;
CREATE TRIGGER trg_ws2_fac_ai_relevance
    BEFORE INSERT OR UPDATE OF capacity_mw ON ws2.facilities
    FOR EACH ROW EXECUTE FUNCTION ws2.recalc_ai_relevance();


-- =============================================================================
-- 4. FACILITY SNAPSHOTS
--    Quarterly point-in-time snapshot of capacity_mw + status + investment.
--    Enables SI2 (Growth Velocity) to compute QoQ deltas without re-collection.
--    Per scope doc p. 4: "rolling 4-quarter calculations".
-- =============================================================================

CREATE TABLE IF NOT EXISTS ws2.facility_snapshots (
    id                      SERIAL      PRIMARY KEY,
    facility_id             INT         NOT NULL REFERENCES ws2.facilities(id) ON DELETE CASCADE,
    quarter                 DATE        NOT NULL,           -- 1st of Jan/Apr/Jul/Oct

    -- Snapshotted values ---------------------------------------------------
    capacity_mw             NUMERIC(10,3),
    status                  TEXT        NOT NULL,
    investment_value_usd    NUMERIC(18,2),
    operator                TEXT,                           -- snapshot in case it changes

    -- Audit ----------------------------------------------------------------
    snapshotted_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    snapshotted_by_run      INT         REFERENCES ws2.collection_runs(id) ON DELETE SET NULL,

    UNIQUE (facility_id, quarter),
    CHECK (status IN ('operational','under_construction','permitted','announced','cancelled','decommissioned')),
    CHECK (EXTRACT(MONTH FROM quarter) IN (1,4,7,10) AND EXTRACT(DAY FROM quarter) = 1)
);

CREATE INDEX IF NOT EXISTS idx_ws2_snap_quarter ON ws2.facility_snapshots(quarter);
CREATE INDEX IF NOT EXISTS idx_ws2_snap_status  ON ws2.facility_snapshots(status);


-- Now that facilities exists, add the deferred FK on collection_log.facility_id
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.referential_constraints
        WHERE constraint_name = 'collection_log_facility_id_fkey'
    ) THEN
        ALTER TABLE ws2.collection_log
            ADD CONSTRAINT collection_log_facility_id_fkey
            FOREIGN KEY (facility_id) REFERENCES ws2.facilities(id) ON DELETE SET NULL;
    END IF;
END $$;


-- =============================================================================
-- 5. COUNTRY-QUARTER METRICS & SCORES
--    Derived: aggregated from facility_snapshots, written by the scoring job.
-- =============================================================================

CREATE TABLE IF NOT EXISTS ws2.si1_country_metrics (
    id                          SERIAL      PRIMARY KEY,
    country_id                  INT         NOT NULL REFERENCES public.csi_countries(id),
    quarter                     DATE        NOT NULL,

    -- The 3 metrics in the score (Q1: investment kept separate as diagnostic) -
    installed_capacity_mw       NUMERIC(12,3),              -- sum where status=operational
    pipeline_capacity_mw        NUMERIC(12,3),              -- sum where status in (under_construction, permitted)
    pipeline_multiplier         NUMERIC(8,4),               -- pipeline / installed

    -- Diagnostic (Q1) ------------------------------------------------------
    committed_investment_usd    NUMERIC(18,2),

    -- Counts (useful for completeness checks) -----------------------------
    n_facilities_operational    INT         NOT NULL DEFAULT 0,
    n_facilities_pipeline       INT         NOT NULL DEFAULT 0,
    n_facilities_announced      INT         NOT NULL DEFAULT 0,  -- for Q2 sensitivity

    -- Provenance / audit ---------------------------------------------------
    config_snapshot             JSONB       NOT NULL DEFAULT '{}'::jsonb,  -- frozen ws2.config at compute time
    computed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    computed_by_run             INT         REFERENCES ws2.collection_runs(id) ON DELETE SET NULL,

    UNIQUE (country_id, quarter),
    CHECK (EXTRACT(MONTH FROM quarter) IN (1,4,7,10) AND EXTRACT(DAY FROM quarter) = 1)
);

CREATE INDEX IF NOT EXISTS idx_ws2_si1_metrics_quarter ON ws2.si1_country_metrics(quarter);


CREATE TABLE IF NOT EXISTS ws2.si1_country_scores (
    id                          SERIAL      PRIMARY KEY,
    country_id                  INT         NOT NULL REFERENCES public.csi_countries(id),
    quarter                     DATE        NOT NULL,

    -- Per-metric normalized 0-100 scores -----------------------------------
    installed_score             NUMERIC(6,2),               -- min-max(installed_capacity_mw)
    pipeline_score              NUMERIC(6,2),               -- min-max(pipeline_capacity_mw)
    multiplier_score            NUMERIC(6,2),               -- min-max(pipeline_multiplier)

    -- Composite SI1 score (0-100) ------------------------------------------
    -- 0.40 × installed + 0.40 × pipeline + 0.20 × multiplier
    si1_score                   NUMERIC(6,2),
    si1_rank                    INT,                        -- 1 = highest

    -- Sensitivity outputs (rank under alternative weight schemes) ----------
    si1_score_inc_announced     NUMERIC(6,2),               -- Q2 sensitivity
    si1_score_no_threshold      NUMERIC(6,2),               -- Q3 sensitivity

    -- Audit ----------------------------------------------------------------
    weights_used                JSONB       NOT NULL DEFAULT '{"installed":0.40,"pipeline":0.40,"multiplier":0.20}'::jsonb,
    computed_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    computed_by_run             INT         REFERENCES ws2.collection_runs(id) ON DELETE SET NULL,

    UNIQUE (country_id, quarter),
    CHECK (si1_score IS NULL OR (si1_score BETWEEN 0 AND 100)),
    CHECK (EXTRACT(MONTH FROM quarter) IN (1,4,7,10) AND EXTRACT(DAY FROM quarter) = 1)
);

CREATE INDEX IF NOT EXISTS idx_ws2_si1_scores_quarter ON ws2.si1_country_scores(quarter);


-- =============================================================================
-- 6. VIEWS (mirror SI1 / WS1 SI3 pattern: v_*_completeness, v_*_latest, v_*_recent_runs)
-- =============================================================================

-- 6.1 v_si1_completeness — % of expected facility-quarters covered ------------
CREATE OR REPLACE VIEW ws2.v_si1_completeness AS
WITH expected AS (
    SELECT c.id AS country_id, c.country_name,
           gs.quarter::DATE AS quarter
    FROM public.csi_countries c
    CROSS JOIN generate_series(
        DATE_TRUNC('quarter', CURRENT_DATE - INTERVAL '1 year')::DATE,
        DATE_TRUNC('quarter', CURRENT_DATE)::DATE,
        INTERVAL '3 months'
    ) AS gs(quarter)
    WHERE c.is_target
),
filled AS (
    SELECT country_id, quarter,
           n_facilities_operational + n_facilities_pipeline AS n_facilities_in_score
    FROM ws2.si1_country_metrics
)
SELECT
    e.country_name,
    e.quarter,
    COALESCE(f.n_facilities_in_score, 0) AS n_facilities_in_score,
    CASE WHEN COALESCE(f.n_facilities_in_score, 0) > 0 THEN 1 ELSE 0 END AS has_data
FROM expected e
LEFT JOIN filled f USING (country_id, quarter)
ORDER BY e.country_name, e.quarter;


-- 6.2 v_si1_latest — most recent SI1 score per country ------------------------
CREATE OR REPLACE VIEW ws2.v_si1_latest AS
WITH latest_q AS (
    SELECT country_id, MAX(quarter) AS quarter
    FROM ws2.si1_country_scores
    GROUP BY country_id
)
SELECT
    c.country_name,
    s.quarter,
    s.installed_score,
    s.pipeline_score,
    s.multiplier_score,
    s.si1_score,
    s.si1_rank,
    m.installed_capacity_mw,
    m.pipeline_capacity_mw,
    m.pipeline_multiplier,
    m.committed_investment_usd
FROM latest_q lq
JOIN ws2.si1_country_scores  s ON s.country_id = lq.country_id AND s.quarter = lq.quarter
JOIN ws2.si1_country_metrics m ON m.country_id = lq.country_id AND m.quarter = lq.quarter
JOIN public.csi_countries    c ON c.id = lq.country_id
ORDER BY s.si1_rank NULLS LAST, c.country_name;


-- 6.3 v_si1_recent_runs — pipeline activity in last 30 days -------------------
CREATE OR REPLACE VIEW ws2.v_si1_recent_runs AS
SELECT
    r.id              AS run_id,
    r.pipeline_name,
    r.source_name,
    r.started_at,
    r.finished_at,
    r.finished_at - r.started_at AS duration,
    r.status,
    r.rows_attempted,
    r.rows_succeeded,
    r.rows_failed,
    CASE WHEN r.rows_attempted > 0
         THEN ROUND(100.0 * r.rows_succeeded / r.rows_attempted, 1)
         ELSE NULL
    END AS pct_succeeded,
    r.triggered_by,
    r.notes
FROM ws2.collection_runs r
WHERE r.started_at >= NOW() - INTERVAL '30 days'
ORDER BY r.started_at DESC;


-- 6.4 v_facility_latest — facility-level current snapshot view ----------------
CREATE OR REPLACE VIEW ws2.v_facility_latest AS
SELECT
    f.id, c.country_name, f.facility_name, f.operator, f.city, f.region,
    f.capacity_mw, f.capacity_basis, f.is_ai_relevant,
    f.status, f.date_announced, f.date_operational,
    f.investment_value_usd, f.energy_source, f.chip_type_if_known,
    f.primary_source, f.source_collected_date, f.confidence,
    f.insert_method, f.notes
FROM ws2.facilities f
JOIN public.csi_countries c ON c.id = f.country_id
WHERE f.status NOT IN ('cancelled','decommissioned')
ORDER BY c.country_name, f.facility_name;


-- =============================================================================
-- 7. SCORING / AGGREGATION FUNCTIONS
--    Encapsulate the 3-metric formula so the notebook just calls one function.
-- =============================================================================

-- 7.1 Aggregate facilities → country_metrics for a given quarter --------------
CREATE OR REPLACE FUNCTION ws2.aggregate_country_metrics(target_quarter DATE)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    rows_written INT;
    include_announced BOOLEAN;
BEGIN
    SELECT (value = 'true') INTO include_announced
    FROM ws2.config WHERE key = 'include_announced_in_pipeline';

    WITH base AS (
        SELECT
            f.country_id,
            COALESCE(SUM(s.capacity_mw) FILTER (WHERE s.status = 'operational'), 0)         AS installed,
            COALESCE(SUM(s.capacity_mw) FILTER (WHERE s.status IN ('under_construction','permitted')
                OR (include_announced AND s.status = 'announced')), 0)                      AS pipeline,
            COUNT(*) FILTER (WHERE s.status = 'operational')                                AS n_op,
            COUNT(*) FILTER (WHERE s.status IN ('under_construction','permitted'))          AS n_pipe,
            COUNT(*) FILTER (WHERE s.status = 'announced')                                  AS n_ann,
            COALESCE(SUM(s.investment_value_usd), 0)                                        AS investment_total
        FROM ws2.facility_snapshots s
        JOIN ws2.facilities f ON f.id = s.facility_id
        WHERE s.quarter = target_quarter
          AND f.is_ai_relevant
        GROUP BY f.country_id
    )
    INSERT INTO ws2.si1_country_metrics
        (country_id, quarter, installed_capacity_mw, pipeline_capacity_mw,
         pipeline_multiplier, committed_investment_usd,
         n_facilities_operational, n_facilities_pipeline, n_facilities_announced,
         config_snapshot)
    SELECT
        b.country_id, target_quarter,
        b.installed, b.pipeline,
        CASE WHEN b.installed > 0 THEN b.pipeline / b.installed ELSE NULL END,
        b.investment_total,
        b.n_op, b.n_pipe, b.n_ann,
        (SELECT jsonb_object_agg(key, value) FROM ws2.config)
    FROM base b
    ON CONFLICT (country_id, quarter) DO UPDATE SET
        installed_capacity_mw     = EXCLUDED.installed_capacity_mw,
        pipeline_capacity_mw      = EXCLUDED.pipeline_capacity_mw,
        pipeline_multiplier       = EXCLUDED.pipeline_multiplier,
        committed_investment_usd  = EXCLUDED.committed_investment_usd,
        n_facilities_operational  = EXCLUDED.n_facilities_operational,
        n_facilities_pipeline     = EXCLUDED.n_facilities_pipeline,
        n_facilities_announced    = EXCLUDED.n_facilities_announced,
        config_snapshot           = EXCLUDED.config_snapshot,
        computed_at               = NOW();

    GET DIAGNOSTICS rows_written = ROW_COUNT;
    RETURN rows_written;
END;
$$;


-- 7.2 Min-max normalize + composite for a given quarter -----------------------
CREATE OR REPLACE FUNCTION ws2.compute_si1_scores(target_quarter DATE)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    rows_written INT;
BEGIN
    WITH bounds AS (
        SELECT
            MIN(installed_capacity_mw)  AS min_inst,  MAX(installed_capacity_mw)  AS max_inst,
            MIN(pipeline_capacity_mw)   AS min_pipe,  MAX(pipeline_capacity_mw)   AS max_pipe,
            MIN(pipeline_multiplier)    AS min_mult,  MAX(pipeline_multiplier)    AS max_mult
        FROM ws2.si1_country_metrics
        WHERE quarter = target_quarter
    ),
    scored AS (
        SELECT
            m.country_id, m.quarter,
            -- min-max → 0-100; if range is zero, give all countries 0 (per p. 4 standard)
            CASE WHEN b.max_inst > b.min_inst
                 THEN 100.0 * (m.installed_capacity_mw - b.min_inst) / (b.max_inst - b.min_inst)
                 ELSE 0 END AS installed_score,
            CASE WHEN b.max_pipe > b.min_pipe
                 THEN 100.0 * (m.pipeline_capacity_mw - b.min_pipe) / (b.max_pipe - b.min_pipe)
                 ELSE 0 END AS pipeline_score,
            CASE WHEN b.max_mult > b.min_mult
                 THEN 100.0 * (COALESCE(m.pipeline_multiplier, 0) - b.min_mult) / (b.max_mult - b.min_mult)
                 ELSE 0 END AS multiplier_score
        FROM ws2.si1_country_metrics m
        CROSS JOIN bounds b
        WHERE m.quarter = target_quarter
    ),
    composite AS (
        -- Round each per-metric score to 2dp FIRST, then compute composite
        -- so that auditors can replicate si1_score from the displayed columns.
        SELECT
            country_id, quarter,
            ROUND(installed_score::numeric,  2) AS installed_score,
            ROUND(pipeline_score::numeric,   2) AS pipeline_score,
            ROUND(multiplier_score::numeric, 2) AS multiplier_score
        FROM scored
    ),
    composite2 AS (
        SELECT *,
            ROUND(0.40 * installed_score + 0.40 * pipeline_score + 0.20 * multiplier_score, 2) AS si1
        FROM composite
    ),
    ranked AS (
        SELECT *,
            RANK() OVER (ORDER BY si1 DESC NULLS LAST)::INT AS rk
        FROM composite2
    )
    INSERT INTO ws2.si1_country_scores
        (country_id, quarter, installed_score, pipeline_score, multiplier_score, si1_score, si1_rank)
    SELECT country_id, quarter, installed_score, pipeline_score, multiplier_score, si1, rk
    FROM ranked
    ON CONFLICT (country_id, quarter) DO UPDATE SET
        installed_score   = EXCLUDED.installed_score,
        pipeline_score    = EXCLUDED.pipeline_score,
        multiplier_score  = EXCLUDED.multiplier_score,
        si1_score         = EXCLUDED.si1_score,
        si1_rank          = EXCLUDED.si1_rank,
        computed_at       = NOW();

    GET DIAGNOSTICS rows_written = ROW_COUNT;
    RETURN rows_written;
END;
$$;


COMMIT;

-- =============================================================================
-- POST-INSTALL SANITY CHECKS  (run manually after applying)
-- =============================================================================
--
-- \dn                                                    -- expect public + ws2
-- \dt ws2.*                                              -- expect 7 tables
-- \dv ws2.*                                              -- expect 4 views
-- \df ws2.*                                              -- expect 3 functions
--
-- SELECT COUNT(*) FROM public.csi_countries;             -- expect 6
-- SELECT * FROM ws2.config;                              -- expect 3 rows (Q2/Q3 toggles + current_quarter)
-- SELECT * FROM ws2.v_si1_completeness LIMIT 5;          -- empty data: 0 facilities
-- SELECT * FROM ws2.v_si1_latest;                        -- empty until first ingest+score
--
-- After loading test facilities:
--   SELECT ws2.aggregate_country_metrics(DATE_TRUNC('quarter', CURRENT_DATE)::DATE);
--   SELECT ws2.compute_si1_scores(DATE_TRUNC('quarter', CURRENT_DATE)::DATE);
--   SELECT * FROM ws2.v_si1_latest;

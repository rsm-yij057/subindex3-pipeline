-- WS2 SI1 end-to-end lifecycle test with synthetic data.
-- Simulates: ingest a few facilities → snapshot → aggregate → score → verify.

\set ON_ERROR_STOP on

-- Reset (test only)
TRUNCATE ws2.facility_snapshots, ws2.si1_country_metrics, ws2.si1_country_scores,
         ws2.collection_log, ws2.data_gaps RESTART IDENTITY CASCADE;
TRUNCATE ws2.facilities RESTART IDENTITY CASCADE;
TRUNCATE ws2.collection_runs RESTART IDENTITY CASCADE;

-- Step 1: collection run
INSERT INTO ws2.collection_runs (pipeline_name, source_name, triggered_by, status)
VALUES ('manual_csv_load', 'synthetic_test', 'lifecycle_test', 'running');

-- Step 2: insert synthetic facilities (designed so each country gets a known score profile)
-- Notes:
--  USA: 3 large operational + 2 large pipeline (high installed, high pipeline)
--  UAE: 1 small operational + 3 huge pipeline (low installed, very high multiplier)
--  Brazil: 2 mid operational, 0 pipeline (moderate installed, zero multiplier)
--  India: 2 operational + 1 pipeline (moderate everything)
--  Singapore: 1 small operational + 1 small pipeline (low installed)
--  Philippines: 1 below threshold (5 MW) — should be excluded → all zeros
INSERT INTO ws2.facilities
    (country_id, facility_name, operator, capacity_mw, status,
     date_announced, date_operational, investment_value_usd,
     primary_source, source_collected_date, insert_method, confidence)
SELECT c.id, fn, op, mw, st, d_ann::date, d_op::date, inv,
       'synthetic', CURRENT_DATE, 'manual', 'high'
FROM (VALUES
    -- USA
    ('USA', 'Northern Virginia DC1', 'AWS',          120.0, 'operational',         '2022-01-01', '2023-06-01', 800000000),
    ('USA', 'Phoenix Cluster',       'Microsoft',     90.0, 'operational',         '2021-06-01', '2023-09-01', 600000000),
    ('USA', 'Atlanta DC',            'Meta',          75.0, 'operational',         '2022-03-01', '2024-03-01', 500000000),
    ('USA', 'Hyperion TX',           'Oracle',       150.0, 'under_construction',  '2024-01-01',  NULL,        1000000000),
    ('USA', 'Stargate II',           'OpenAI/Oracle',200.0, 'permitted',           '2025-06-01',  NULL,        1500000000),
    -- UAE
    ('UAE', 'Stargate UAE',          'G42',           50.0, 'operational',         '2023-09-01', '2024-12-01', 400000000),
    ('UAE', 'Stargate UAE Phase 2',  'G42',          200.0, 'under_construction',  '2024-09-01',  NULL,        1500000000),
    ('UAE', 'Khazna Hyperion',       'Khazna',       300.0, 'permitted',           '2025-01-01',  NULL,        2000000000),
    ('UAE', 'Mubadala Compute',      'Mubadala',     250.0, 'permitted',           '2025-03-01',  NULL,        1800000000),
    -- Brazil
    ('Brazil','São Paulo DC',        'Equinix',       40.0, 'operational',         '2021-01-01', '2022-06-01', 200000000),
    ('Brazil','Rio Tier3',           'Ascenty',       30.0, 'operational',         '2021-06-01', '2023-01-01', 150000000),
    -- India
    ('India','Mumbai Hyperscale',    'NTT',           60.0, 'operational',         '2022-01-01', '2024-01-01', 350000000),
    ('India','Hyderabad Campus',     'CtrlS',         45.0, 'operational',         '2022-06-01', '2024-06-01', 250000000),
    ('India','Chennai Pipeline',     'Yotta',        100.0, 'under_construction',  '2024-01-01',  NULL,         600000000),
    -- Singapore
    ('Singapore','Tuas DC',          'STT',           25.0, 'operational',         '2022-01-01', '2024-01-01', 180000000),
    ('Singapore','Changi DC2',       'Equinix',       30.0, 'permitted',           '2025-01-01',  NULL,         220000000),
    -- Philippines: below threshold
    ('Philippines','Manila Small',   'Globe',          5.0, 'operational',         '2023-01-01', '2024-06-01',  30000000),
    -- Should be excluded: 'announced' status (Q2: not in default pipeline)
    ('USA',   'Speculative Hyperscale','Anonymous',  500.0, 'announced',           '2026-01-01',  NULL,        3000000000)
) AS v(country_name, fn, op, mw, st, d_ann, d_op, inv)
JOIN public.csi_countries c ON c.country_name = v.country_name;

-- Step 3: log to collection_log (one entry per facility)
INSERT INTO ws2.collection_log (run_id, country_id, facility_id, action, status, duration_ms)
SELECT (SELECT MAX(id) FROM ws2.collection_runs), country_id, id, 'insert', 'success', 50
FROM ws2.facilities;

-- Step 4: write quarterly snapshot for current quarter
INSERT INTO ws2.facility_snapshots
    (facility_id, quarter, capacity_mw, status, investment_value_usd, operator, snapshotted_by_run)
SELECT id, DATE_TRUNC('quarter', CURRENT_DATE)::DATE,
       capacity_mw, status, investment_value_usd, operator,
       (SELECT MAX(id) FROM ws2.collection_runs)
FROM ws2.facilities;

-- Step 5: aggregate + score
SELECT 'metrics_rows', ws2.aggregate_country_metrics(DATE_TRUNC('quarter', CURRENT_DATE)::DATE);
SELECT 'score_rows',   ws2.compute_si1_scores(       DATE_TRUNC('quarter', CURRENT_DATE)::DATE);

-- Step 6: finalize run
UPDATE ws2.collection_runs
SET status = 'success', finished_at = NOW(),
    rows_attempted = (SELECT COUNT(*) FROM ws2.facilities),
    rows_succeeded = (SELECT COUNT(*) FROM ws2.facilities)
WHERE id = (SELECT MAX(id) FROM ws2.collection_runs);

\echo
\echo === Facility ingest summary ===
SELECT c.country_name, COUNT(*) AS n_total,
       COUNT(*) FILTER (WHERE f.is_ai_relevant) AS n_ai_relevant,
       COUNT(*) FILTER (WHERE NOT f.is_ai_relevant) AS n_below_threshold
FROM ws2.facilities f JOIN public.csi_countries c ON c.id = f.country_id
GROUP BY c.country_name ORDER BY c.country_name;

\echo
\echo === Country metrics ===
SELECT c.country_name,
       installed_capacity_mw AS installed_mw,
       pipeline_capacity_mw AS pipeline_mw,
       ROUND(pipeline_multiplier,3) AS multiplier,
       n_facilities_operational AS n_op,
       n_facilities_pipeline AS n_pipe,
       n_facilities_announced AS n_ann
FROM ws2.si1_country_metrics m JOIN public.csi_countries c ON c.id = m.country_id
ORDER BY c.country_name;

\echo
\echo === SI1 scores (final ranking) ===
SELECT * FROM ws2.v_si1_latest;

\echo
\echo === Sanity: composite score = 0.40*inst + 0.40*pipe + 0.20*mult? ===
SELECT
    c.country_name,
    si1_score AS reported,
    ROUND((0.40 * installed_score + 0.40 * pipeline_score + 0.20 * multiplier_score)::numeric, 2) AS recomputed,
    CASE WHEN si1_score = ROUND((0.40 * installed_score + 0.40 * pipeline_score + 0.20 * multiplier_score)::numeric, 2)
         THEN 'OK' ELSE 'MISMATCH' END AS check
FROM ws2.si1_country_scores s JOIN public.csi_countries c ON c.id = s.country_id
ORDER BY c.country_name;

\echo
\echo === Q2 SENSITIVITY: include announced as pipeline ===
UPDATE ws2.config SET value = 'true' WHERE key = 'include_announced_in_pipeline';
SELECT ws2.aggregate_country_metrics(DATE_TRUNC('quarter', CURRENT_DATE)::DATE);
SELECT ws2.compute_si1_scores(       DATE_TRUNC('quarter', CURRENT_DATE)::DATE);

SELECT c.country_name, si1_rank, si1_score
FROM ws2.si1_country_scores s JOIN public.csi_countries c ON c.id = s.country_id
WHERE s.quarter = DATE_TRUNC('quarter', CURRENT_DATE)::DATE
ORDER BY si1_rank;

-- Reset
UPDATE ws2.config SET value = 'false' WHERE key = 'include_announced_in_pipeline';
SELECT ws2.aggregate_country_metrics(DATE_TRUNC('quarter', CURRENT_DATE)::DATE);
SELECT ws2.compute_si1_scores(       DATE_TRUNC('quarter', CURRENT_DATE)::DATE);

\echo
\echo === Q3 SENSITIVITY: drop AI-relevance threshold to 0 ===
UPDATE ws2.config SET value = '0' WHERE key = 'ai_relevance_min_mw';
-- Re-trigger AI relevance recalculation by touching every row
UPDATE ws2.facilities SET capacity_mw = capacity_mw;

\echo  Should now include Philippines 5 MW facility:
SELECT c.country_name, COUNT(*) AS ai_rel
FROM ws2.facilities f JOIN public.csi_countries c ON c.id = f.country_id
WHERE f.is_ai_relevant
GROUP BY c.country_name
ORDER BY c.country_name;

-- Reset
UPDATE ws2.config SET value = '10' WHERE key = 'ai_relevance_min_mw';
UPDATE ws2.facilities SET capacity_mw = capacity_mw;

\echo
\echo === Operational views ===
SELECT * FROM ws2.v_si1_completeness WHERE has_data > 0;
SELECT * FROM ws2.v_si1_recent_runs;

\echo
\echo === Constraint test: cancelled status should not appear in v_facility_latest ===
INSERT INTO ws2.facilities
    (country_id, facility_name, operator, capacity_mw, status,
     primary_source, source_collected_date)
VALUES ((SELECT id FROM public.csi_countries WHERE country_name='USA'),
        'Cancelled Project', 'TestOp', 50, 'cancelled',
        'test', CURRENT_DATE);

SELECT COUNT(*) AS visible_in_v_facility_latest
FROM ws2.v_facility_latest WHERE facility_name = 'Cancelled Project';

\echo
\echo === All lifecycle checks complete ===

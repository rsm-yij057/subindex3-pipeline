-- =============================================================================
-- Subindex 3 – API Pipeline Schema
-- =============================================================================
-- Covers:
--   1. api_source_config  – configuration table for external API sources
--   2. si3_raw_metrics    – add raw_payload JSONB column if not already present
--   3. Supporting indexes
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. API Source Configuration Table
-- -----------------------------------------------------------------------------
-- Stores everything needed to construct and authenticate an API call.
-- API keys are never stored here; the api_key_env_var column holds the name
-- of the OS environment variable that contains the actual key at runtime.

CREATE TABLE IF NOT EXISTS api_source_config (
    id                  SERIAL          PRIMARY KEY,
    source_id           INT             NOT NULL REFERENCES si3_sources(source_id),

    -- Human-readable label (e.g. "USGS Mineral Resources Monthly")
    source_name         TEXT            NOT NULL,

    -- Request construction
    base_url            TEXT            NOT NULL,          -- e.g. https://minerals.usgs.gov
    endpoint            TEXT            NOT NULL,          -- e.g. /minerals/pubs/mcs/
    http_method         TEXT            NOT NULL DEFAULT 'GET'
                            CHECK (http_method IN ('GET', 'POST')),

    -- Authentication
    auth_type           TEXT            NOT NULL DEFAULT 'none'
                            CHECK (auth_type IN ('none', 'api_key', 'bearer')),
    -- Name of the environment variable that holds the key (e.g. "USGS_API_KEY").
    -- NULL when auth_type = 'none'.
    api_key_env_var     TEXT,

    -- Query / body parameters sent with every request.
    -- Additional per-run params (e.g. year, month) are merged in at runtime.
    default_params      JSONB           NOT NULL DEFAULT '{}',

    -- Expected top-level shape so the ingestion script knows where the rows live.
    -- e.g. {"type": "json_array", "data_key": "results"}
    response_schema     JSONB           NOT NULL DEFAULT '{}',

    -- How often this source is expected to be refreshed.
    refresh_frequency   TEXT            NOT NULL DEFAULT 'monthly'
                            CHECK (refresh_frequency IN ('daily', 'weekly', 'monthly', 'quarterly')),

    -- Soft-disable without deleting the row.
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  api_source_config IS
    'Configuration for external API data sources. One row per distinct endpoint.';
COMMENT ON COLUMN api_source_config.api_key_env_var IS
    'Name of the OS environment variable that contains the API key. Never store the key itself here.';
COMMENT ON COLUMN api_source_config.default_params IS
    'Static query parameters merged into every request (e.g. {"format": "json", "commodity": "copper"}).';
COMMENT ON COLUMN api_source_config.response_schema IS
    'Describes the expected JSON shape so the ingestion script can navigate the response.';


-- Keep updated_at current automatically
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_api_source_config_updated_at
    BEFORE UPDATE ON api_source_config
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- 2. si3_raw_metrics – add raw_payload JSONB column (idempotent)
-- -----------------------------------------------------------------------------
-- Store the verbatim API response alongside whatever columns already exist.
-- The DO block makes the migration safe to run multiple times.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM   information_schema.columns
        WHERE  table_name  = 'si3_raw_metrics'
        AND    column_name = 'raw_payload'
    ) THEN
        ALTER TABLE si3_raw_metrics
            ADD COLUMN raw_payload      JSONB,
            ADD COLUMN api_source_id    INT  REFERENCES api_source_config(id),
            ADD COLUMN ingested_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            ADD COLUMN ingestion_status TEXT NOT NULL DEFAULT 'pending'
                CHECK (ingestion_status IN ('pending', 'transformed', 'error'));
    END IF;
END;
$$;

COMMENT ON COLUMN si3_raw_metrics.raw_payload IS
    'Verbatim JSON response body returned by the external API.';
COMMENT ON COLUMN si3_raw_metrics.ingestion_status IS
    'Lifecycle flag: pending → transformed once loaded into si3_monthly_metrics, error on failure.';


-- -----------------------------------------------------------------------------
-- 3. Indexes
-- -----------------------------------------------------------------------------

-- Fast lookup of active sources
CREATE INDEX IF NOT EXISTS idx_api_source_config_active
    ON api_source_config (is_active)
    WHERE is_active = TRUE;

-- Look up raw rows waiting to be transformed
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_status
    ON si3_raw_metrics (ingestion_status)
    WHERE ingestion_status = 'pending';

-- Look up raw rows by source
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_source
    ON si3_raw_metrics (api_source_id);

-- Look up raw rows by ingest time (useful for debugging recent runs)
CREATE INDEX IF NOT EXISTS idx_si3_raw_metrics_ingested_at
    ON si3_raw_metrics (ingested_at DESC);


-- -----------------------------------------------------------------------------
-- 4. Seed row – USGS Mineral Commodity Summaries (example)
-- -----------------------------------------------------------------------------
-- Run only once; uses ON CONFLICT DO NOTHING so it is idempotent.
-- Adjust source_id to match the real row in si3_sources.

INSERT INTO api_source_config (
    source_id,
    source_name,
    base_url,
    endpoint,
    http_method,
    auth_type,
    api_key_env_var,
    default_params,
    response_schema,
    refresh_frequency,
    is_active
)
VALUES (
    1,                                          -- replace with actual source_id
    'USGS National Minerals Information Center',
    'https://minerals.usgs.gov',
    '/minerals/pubs/mcs/',
    'GET',
    'none',
    NULL,                                       -- no API key required
    '{"format": "json"}',
    '{"type": "json_object", "data_key": "MineralResources"}',
    'monthly',
    TRUE
)
ON CONFLICT DO NOTHING;

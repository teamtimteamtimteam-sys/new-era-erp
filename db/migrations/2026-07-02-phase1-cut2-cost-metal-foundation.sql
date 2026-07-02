-- ============================================================
-- Phase 1 / Cut 2 — cost (COGS) + metal-content foundation
-- Date: 2026-07-02
-- Precondition: fresh verified pg_dump backup exists.
--
-- Adds: processing_cost_entries, inbound_batch_metals, output_batch_metals,
--       metal_prices; allocation-result columns on processing_runs /
--       processing_outputs; allocate_processing_costs(); and the
--       processing_metal_recovery view. Does NOT touch the existing
--       commit/rollback functions or any app TypeScript.
-- ============================================================
BEGIN;

-- 1) Cost entries per run (raw material cost is NOT entered here;
--    it is computed from input legs × inbound unit_price)
CREATE TABLE processing_cost_entries (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id      uuid        NOT NULL REFERENCES processing_runs(id) ON DELETE RESTRICT,
    cost_type   text        NOT NULL CHECK (cost_type IN
        ('labour','electricity','gas','depreciation','consumables','waste_treatment','other')),
    amount_usd  numeric     NOT NULL,  -- deliberately no sign check: by-product/disposal offsets may be negative
    is_estimate boolean     NOT NULL DEFAULT false,
    notes       text,
    deleted_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid
);
CREATE INDEX idx_processing_cost_entries_run ON processing_cost_entries(run_id);

-- 2) Metal content (assay results), both sides of processing.
--    Shared metal set; when adding a metal later, widen ALL these CHECKs together.
CREATE TABLE inbound_batch_metals (
    inbound_batch_id uuid    NOT NULL REFERENCES inbound_batches(id) ON DELETE CASCADE,
    metal            text    NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    content_pct      numeric NOT NULL CHECK (content_pct >= 0 AND content_pct <= 100),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    PRIMARY KEY (inbound_batch_id, metal)
);
CREATE TABLE output_batch_metals (
    output_batch_id uuid    NOT NULL REFERENCES output_batches(id) ON DELETE CASCADE,
    metal           text    NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    content_pct     numeric NOT NULL CHECK (content_pct >= 0 AND content_pct <= 100),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    PRIMARY KEY (output_batch_id, metal)
);
-- (Attribute rows: hard delete allowed, unlike audit legs. Batch soft-delete covers history.)

-- 3) Metal prices, USD per tonne. Manual now; an LME feed later only changes the data source.
CREATE TABLE metal_prices (
    id                  uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
    metal               text    NOT NULL CHECK (metal IN ('ni','co','li','mn','cu','al','fe')),
    price_usd_per_tonne numeric NOT NULL CHECK (price_usd_per_tonne > 0),
    price_date          date    NOT NULL,
    source              text    NOT NULL DEFAULT 'manual',
    notes               text,
    deleted_at          timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid,
    UNIQUE (metal, price_date)
);

-- 4) Allocation result columns
ALTER TABLE processing_runs
  ADD COLUMN allocation_basis    text NOT NULL DEFAULT 'metal_value'
      CHECK (allocation_basis IN ('weight','metal_value')),  -- 'market_value' reserved for Phase 4
  ADD COLUMN material_cost_usd   numeric,
  ADD COLUMN process_cost_usd    numeric,
  ADD COLUMN total_cost_usd      numeric,
  ADD COLUMN allocation_snapshot jsonb,
  ADD COLUMN allocated_at        timestamptz,
  ADD COLUMN allocated_by        uuid;

ALTER TABLE processing_outputs
  ADD COLUMN allocated_cost_usd numeric,
  ADD COLUMN unit_cost_usd      numeric;

-- 5) Attach the shared updated_at trigger (public.update_updated_at) to the four new tables.
CREATE TRIGGER trg_processing_cost_entries_updated_at
    BEFORE UPDATE ON processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_inbound_batch_metals_updated_at
    BEFORE UPDATE ON inbound_batch_metals
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_output_batch_metals_updated_at
    BEFORE UPDATE ON output_batch_metals
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_metal_prices_updated_at
    BEFORE UPDATE ON metal_prices
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 6) RLS: authenticated-only full access, cloning processing_runs' existing policy exactly.
ALTER TABLE processing_cost_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on processing_cost_entries"
    ON processing_cost_entries AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

ALTER TABLE inbound_batch_metals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on inbound_batch_metals"
    ON inbound_batch_metals AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

ALTER TABLE output_batch_metals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on output_batch_metals"
    ON output_batch_metals AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

ALTER TABLE metal_prices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on metal_prices"
    ON metal_prices AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- 7a) Allocation engine.
--     Re-running is allowed and overwrites (costs arrive late and get corrected).
--     NOTE: re-allocation after an output batch is partially sold changes its unit
--     cost; COGS-at-sale handling is a Phase 3 concern. All math assumes kg; metal
--     prices are USD per tonne (kg/1000).
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
BEGIN
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost = Σ input legs quantity_consumed × inbound.unit_price (NULL price = 0).
    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(ib.unit_price, 0)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_usd), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- 7. Basis totals + metal-price guards.
    IF v_basis = 'metal_value' THEN
        -- any metal present (content > 0) with no usable price row => error
        SELECT obm.metal INTO v_bad_metal
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        WHERE po.run_id = p_run_id AND obm.content_pct > 0
          AND NOT EXISTS (
              SELECT 1 FROM metal_prices mp
              WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                AND mp.price_date <= v_process_date
          )
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'MISSING_METAL_PRICE|%', v_bad_metal;
        END IF;

        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * pr.price_usd_per_tonne
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
    END IF;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * pr.price_usd_per_tonne)
                        FROM output_batch_metals obm
                        JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_usd = f.allocated,
            unit_cost_usd = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_usd
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_usd', allocated,
                   'unit_cost_usd', unit_cost_usd)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    v_snapshot := jsonb_build_object(
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used
    );

    UPDATE processing_runs
    SET material_cost_usd   = round(v_material, 2),
        process_cost_usd    = round(v_process, 2),
        total_cost_usd      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_usd', round(v_material, 2),
        'process_cost_usd', round(v_process, 2),
        'total_cost_usd', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

-- 7b) Recovery view: one row per committed, live run × metal (full-join across the
--     input/output metal aggregates). Assumes kg. security_invoker so the caller's RLS
--     on the underlying tables applies (consistent with the RLS-everywhere posture).
CREATE VIEW processing_metal_recovery
WITH (security_invoker = true) AS
WITH ins AS (
    SELECT pi.run_id, ibm.metal,
           SUM(pi.quantity_consumed * ibm.content_pct / 100.0) AS input_metal_kg
    FROM processing_inputs pi
    JOIN inbound_batch_metals ibm ON ibm.inbound_batch_id = pi.inbound_batch_id
    GROUP BY pi.run_id, ibm.metal
),
outs AS (
    SELECT po.run_id, obm.metal,
           SUM(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg
    FROM processing_outputs po
    JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
    GROUP BY po.run_id, obm.metal
)
SELECT r.id            AS run_id,
       r.code          AS run_code,
       r.process_date,
       COALESCE(i.metal, o.metal) AS metal,
       COALESCE(i.input_metal_kg, 0)  AS input_metal_kg,
       COALESCE(o.output_metal_kg, 0) AS output_metal_kg,
       CASE WHEN COALESCE(i.input_metal_kg, 0) = 0 THEN NULL
            ELSE round(COALESCE(o.output_metal_kg, 0) / i.input_metal_kg * 100, 2)
       END AS recovery_pct
FROM ins i
FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
JOIN processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
WHERE r.status = 'committed' AND r.deleted_at IS NULL;

COMMIT;

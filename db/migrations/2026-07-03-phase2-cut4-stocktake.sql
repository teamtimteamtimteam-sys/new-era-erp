-- ============================================================
-- Phase 2 / Cut 4 — stocktake foundation (tables + posting)
-- Date: 2026-07-03
-- Precondition: fresh verified pg_dump backup exists.
--
-- A stocktake collects counted quantities per batch; posting reconciles each batch
-- to its count by writing a single 'adjustment' inventory_movement for the delta and
-- setting remaining_qty := counted_qty. Posting recomputes delta against the CURRENT
-- remaining_qty (not the book snapshot), so any sale/processing between counting and
-- posting is respected — the physical count wins for counted batches.
-- ============================================================
BEGIN;

-- B1. stocktakes ----------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS public.stocktake_code_seq;

CREATE OR REPLACE FUNCTION public.generate_stocktake_code()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'ST-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('stocktake_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TABLE public.stocktakes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL,
    status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open','posted','cancelled')),
    notes       text,
    started_at  timestamptz NOT NULL DEFAULT now(),
    posted_at   timestamptz,
    deleted_at  timestamptz,
    created_by  uuid DEFAULT auth.uid(),
    updated_by  uuid DEFAULT auth.uid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_generate_stocktake_code
    BEFORE INSERT ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION public.generate_stocktake_code();

CREATE TRIGGER trg_stocktakes_updated_at
    BEFORE UPDATE ON public.stocktakes
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.stocktakes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on stocktakes"
    ON public.stocktakes AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- B2. stocktake_lines -----------------------------------------------------------
-- No updated_at: a re-count replaces the line via upsert on the (stocktake, batch) key.
-- The two UNIQUE constraints use the default NULLS DISTINCT: because each line has
-- exactly one batch FK (XOR CHECK), the null side never collides, giving partial-unique
-- semantics (unique per stocktake+inbound_batch, and per stocktake+output_batch) cleanly.
CREATE TABLE public.stocktake_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    stocktake_id     uuid NOT NULL REFERENCES public.stocktakes (id) ON DELETE RESTRICT,
    inbound_batch_id uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id  uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    book_qty         numeric NOT NULL,  -- remaining_qty snapshot at count time
    counted_qty      numeric NOT NULL CHECK (counted_qty >= 0),
    notes            text,
    counted_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT stocktake_lines_one_batch CHECK ((inbound_batch_id IS NULL) <> (output_batch_id IS NULL)),
    UNIQUE (stocktake_id, inbound_batch_id),
    UNIQUE (stocktake_id, output_batch_id)
);

CREATE INDEX idx_stocktake_lines_stocktake ON public.stocktake_lines (stocktake_id);

ALTER TABLE public.stocktake_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on stocktake_lines"
    ON public.stocktake_lines AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- B3. post_stocktake ------------------------------------------------------------
-- Recomputes delta against CURRENT remaining_qty at post time (count wins). Writes one
-- 'adjustment' movement per changed batch and reconciles remaining_qty; the deferred
-- ledger invariant then validates each touched batch at commit.
CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
BEGIN
    SELECT id, code, status, deleted_at INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at INTO v_code, v_current, v_deleted
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            IF v_deleted IS NOT NULL THEN
                RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
            END IF;
            v_delta := v_line.counted_qty - v_current;
            IF v_delta <> 0 THEN
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
                v_lines_adjusted := v_lines_adjusted + 1;
                v_total_delta := v_total_delta + v_delta;
            END IF;
        ELSE
            SELECT code, remaining_qty, deleted_at INTO v_code, v_current, v_deleted
            FROM output_batches WHERE id = v_line.output_batch_id FOR UPDATE;
            IF v_deleted IS NOT NULL THEN
                RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
            END IF;
            v_delta := v_line.counted_qty - v_current;
            IF v_delta <> 0 THEN
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
                v_lines_adjusted := v_lines_adjusted + 1;
                v_total_delta := v_total_delta + v_delta;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$;

-- B4. cancel_stocktake ----------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_stocktake(p_stocktake_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_status  text;
    v_deleted timestamptz;
BEGIN
    SELECT status, deleted_at INTO v_status, v_deleted
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_status;
    END IF;

    UPDATE stocktakes
    SET status = 'cancelled', updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;
END;
$function$;

COMMIT;

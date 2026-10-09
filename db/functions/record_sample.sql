-- db/functions/record_sample.sql
-- MES-6a-1(2026-10-09,MES-0 Q61;MES-6a Step 0 Q7–Q10,Tim):【取一份样品】—— module.quality.edit。
--   恰好一批(进料或产出);种类 ours · counterparty · umpire · retained · contamination;取样日必填、不许晚于今天(新加坡日历),
--   没有默认值(AGENTS.md:决定一件事的日期必填);可选:克数、库位(第一行保管记录 taken 带着它)、销售单(只对产出批)、
--   交叉污染抽检(只对 contamination,同一批产出批上取过样的那一条)。
--   【留到哪一天】在这里抄下,以后不改(Q8):指了销售单、而那张单的合同副本要求留样并写了天数 → 取样日 + 合同天数(contract);
--   否则 → 取样日 + V16(quality_settings.internal_retention_days,internal);V16 也是空的 → 不写日子(not_set,屏幕上 Not yet set)。
--   第一行保管记录 taken 发生在取样日的新加坡零点(之后每一行都不许早于它)。返回 {sample_id, code, retain_until, retain_until_source}。
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
CREATE OR REPLACE FUNCTION public.record_sample(p_kind text, p_taken_on date, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_mass_g numeric DEFAULT NULL::numeric, p_sales_order_id uuid DEFAULT NULL::uuid, p_contamination_check_id bigint DEFAULT NULL::bigint, p_storage_location_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_id      uuid := gen_random_uuid();
    v_code    text;
    v_st      jsonb;
    v_days    integer;
    v_source  text := 'not_set';
    v_until   date;
    v_check   record;
BEGIN
    PERFORM require_permission('module.quality.edit');
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'SAMPLE_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_output_batch_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF p_kind IS NULL OR p_kind NOT IN ('ours', 'counterparty', 'umpire', 'retained', 'contamination') THEN
        RAISE EXCEPTION 'SAMPLE_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;
    IF p_taken_on IS NULL THEN
        RAISE EXCEPTION 'SAMPLE_DATE_REQUIRED';
    END IF;
    IF p_taken_on > (now() AT TIME ZONE 'Asia/Singapore')::date THEN
        RAISE EXCEPTION 'SAMPLE_DATE_IN_FUTURE|%', p_taken_on;
    END IF;
    IF p_mass_g IS NOT NULL AND p_mass_g <= 0 THEN
        RAISE EXCEPTION 'SAMPLE_MASS_INVALID|%', p_mass_g;
    END IF;
    IF p_storage_location_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_storage_location_id AND is_active) THEN
        RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', p_storage_location_id;
    END IF;

    -- 交叉污染抽检(Q10):只对 contamination;同一批产出批上、取过样的那一条
    IF p_contamination_check_id IS NOT NULL THEN
        IF p_kind <> 'contamination' THEN
            RAISE EXCEPTION 'SAMPLE_CHECK_ONLY_FOR_CONTAMINATION|%', p_kind;
        END IF;
        SELECT c.id, c.kind, c.output_batch_id INTO v_check FROM contamination_checks c WHERE c.id = p_contamination_check_id;
        IF NOT FOUND OR v_check.kind <> 'sampled' OR v_check.output_batch_id IS DISTINCT FROM p_output_batch_id THEN
            RAISE EXCEPTION 'SAMPLE_CHECK_NOT_FOR_BATCH|%', p_contamination_check_id;
        END IF;
    END IF;

    -- 留到哪一天(Q8):合同天数 → V16 → Not yet set。抄下来,以后不改。
    IF p_sales_order_id IS NOT NULL THEN
        IF p_output_batch_id IS NULL THEN
            RAISE EXCEPTION 'SAMPLE_SALES_ORDER_NEEDS_OUTPUT_BATCH';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SO_NOT_FOUND|%', p_sales_order_id;
        END IF;
        SELECT t.settlement_terms INTO v_st FROM contract_document_terms t WHERE t.sales_order_id = p_sales_order_id;
        IF COALESCE((v_st ->> 'sample_retention_required')::boolean, false)
           AND (v_st ->> 'sample_retention_days') IS NOT NULL THEN
            v_days := (v_st ->> 'sample_retention_days')::integer;
            v_source := 'contract';
        END IF;
    END IF;
    IF v_days IS NULL THEN
        SELECT q.internal_retention_days INTO v_days FROM quality_settings q WHERE q.id;
        IF v_days IS NOT NULL THEN
            v_source := 'internal';
        END IF;
    END IF;
    IF v_days IS NOT NULL THEN
        v_until := p_taken_on + v_days;
    END IF;

    v_code := next_sample_code(p_taken_on);
    INSERT INTO samples (id, code, inbound_batch_id, output_batch_id, kind, taken_on, mass_g, sales_order_id,
                         contamination_check_id, retain_until, retain_until_source, retention_days_at, notes, created_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_kind, p_taken_on, p_mass_g, p_sales_order_id,
            p_contamination_check_id, v_until, v_source, v_days, NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user);
    INSERT INTO sample_events (sample_id, event_kind, occurred_at, storage_location_id, created_by)
    VALUES (v_id, 'taken', (p_taken_on::timestamp) AT TIME ZONE 'Asia/Singapore', p_storage_location_id, v_user);

    RETURN jsonb_build_object('sample_id', v_id, 'code', v_code, 'retain_until', v_until, 'retain_until_source', v_source);
END;
$function$

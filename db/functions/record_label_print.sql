-- db/functions/record_label_print.sql
-- MES-3b(2026-10-07,MES-0 Q40;MES-3b Step 0 Q6–Q8,Tim):【印一张标签】—— 打印页按下"打印"时调,【先写这一行,再 window.print()】。
--   判断全在 label_print_context(与预览同一支):种类、查看码、找得到、模板。这里只加三件:
--   ① 份数:不给 = 1;给了要 ≥ 1 → 否则 LABEL_COPIES_INVALID|<份数>(没有上限 —— 那不是这里能定的数)。
--   ② 补印:这样东西以前印过(不论哪个模板)→ 这一次是补印,理由必填 → LABEL_REPRINT_REASON_REQUIRED|<编号>。
--      Q40:能印的人就能补印。第一次给了理由也不记(那不是一次补印,理由列为空 —— 表上的 CHECK 也这么说)。
--      "以前印过"在一把每样东西一把的咨询锁里判:两个人同时按,第二个看得见第一个,于是只有一个"第一次"。
--   ③ 记下:模板与纸、份数、补印与理由、二维码路径、印上去的字段快照(label_object_data 的那一份 + 模板)、谁、何时。
--   返回:这一行的 id、第几次、是不是补印,以及页面画标签要的全部数据(与预览同形)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.record_label_print(p_kind text, p_id uuid, p_template text DEFAULT NULL::text, p_copies integer DEFAULT NULL::integer, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx     jsonb;
    v_copies  integer := COALESCE(p_copies, 1);
    v_reprint boolean;
    v_id      uuid;
    v_n       integer;
BEGIN
    IF NOT (has_permission('module.inbound.view') OR has_permission('module.output.view')
            OR has_permission('module.inventory.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.inventory.view';
    END IF;
    IF v_copies < 1 THEN
        RAISE EXCEPTION 'LABEL_COPIES_INVALID|%', v_copies;
    END IF;

    -- 先问种类与查看码(不告诉一个看不见的人那样东西在不在),再上锁、再数以前印过几次
    v_ctx := label_print_context(p_kind, p_id, p_template);
    PERFORM pg_advisory_xact_lock(hashtext('label_print_' || p_kind || '_' || p_id::text)::bigint);
    SELECT count(*) INTO v_n FROM label_prints lp
     WHERE (p_kind = 'inbound_batch' AND lp.inbound_batch_id = p_id)
        OR (p_kind = 'output_batch' AND lp.output_batch_id = p_id)
        OR (p_kind = 'storage_location' AND lp.storage_location_id = p_id);
    v_reprint := v_n > 0;
    IF v_reprint AND NULLIF(btrim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'LABEL_REPRINT_REASON_REQUIRED|%', v_ctx -> 'data' ->> 'code';
    END IF;

    INSERT INTO label_prints (object_kind, inbound_batch_id, output_batch_id, storage_location_id, template_code, page_size,
                              copies, is_reprint, reprint_reason, qr_payload, printed_fields, printed_by)
    VALUES (p_kind,
            CASE WHEN p_kind = 'inbound_batch' THEN p_id END,
            CASE WHEN p_kind = 'output_batch' THEN p_id END,
            CASE WHEN p_kind = 'storage_location' THEN p_id END,
            v_ctx -> 'template' ->> 'code', v_ctx -> 'template' ->> 'page_size',
            v_copies, v_reprint, CASE WHEN v_reprint THEN btrim(p_reason) END,
            v_ctx ->> 'qr_path',
            (v_ctx -> 'data') || jsonb_build_object('template', v_ctx -> 'template'),
            auth.uid())
    RETURNING id INTO v_id;

    RETURN v_ctx || jsonb_build_object('print_id', v_id, 'print_no', v_n + 1, 'is_reprint', v_reprint, 'copies', v_copies,
                                       'prints_so_far', v_n + 1, 'next_is_reprint', true,
                                       'last_printed_at', now(), 'last_printed_by', auth.uid());
END;
$function$;

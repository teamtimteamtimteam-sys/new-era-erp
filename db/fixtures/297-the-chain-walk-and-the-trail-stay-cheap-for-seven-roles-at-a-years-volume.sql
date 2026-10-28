-- fixture 297 —— 一年体量上,单据链条与变更记录对【七个角色】都便宜(CHAIN-WALK-COST,v1.4.80)
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 2026-10-28 scope E:"A gate fixture that times the walk and the trail for all seven roles on the seeded rebuild and fails over
--   budget, with a fault injection (one deliberately slow arm) proving it bites." · Q3:目标 ≤ 100 ms,fixture 在 300 ms【硬红】· Q4:三次取最好的一次。
--
-- 【数据】db/seeds/chain-walk-year.sql —— 一年的量(Tim Q2),按线上今天的链接形状造;七个角色的读码是线上快照
--   db/seeds/seven-roles-2026-10-28.sql(db/live-fixtures/297 对着线上核对它仍然一字不差)。灌进来约 10 秒,整支回滚。
-- 【量什么】每一张有链条的详情页(21 张)各取一张单据 —— 月结对账单取最重的那一张(BS-2025-0005,走出一千多行);
--   以【七个角色各自的账号】(SET LOCAL ROLE authenticated + 那个账号的 claims)在库里计时:
--   document_chain_walk(页面原样调的那一句)· record_trail(那一页底部的变更记录,20 条)。三次取最好的一次(机器忙时的抖动不该让门红)。
--   读者打不开那一页的变更记录时 record_trail 按名拒(TRAIL_NOT_PERMITTED)—— 那是设计,不计时;任何别的错误一律红。
-- 【A 臂】七个角色 × 22 次走链 + 20 段变更记录,每一个都 ≤ 300 ms;最慢的那一个印出来(与 100 ms 的目标并排)。
-- 【N 臂 —— 体量是真的】种子读回的行数达到一年的量(否则"快"只是因为表是空的)。
-- 【F 臂 —— 故障注入:一条故意变慢的声明边】把 document_relation_arm_pairs 换成先睡 350 ms 再干活的那一支(子事务里,回滚还原),
--   从对账单再走一次:同一支计时必须量出 > 300 ms —— 否则这支 fixture 的判据看不见慢,它的绿就不作数。
-- ★ 造数据走 session_replication_role = replica(与 fixture 296 同一个先例:只在 db/gate.py 的一次性本地库上跑,线上从来不跑)。
BEGIN;
\ir ../seeds/seven-roles-2026-10-28.sql
\ir ../seeds/chain-walk-year.sql

-- 一次走链 / 一段变更记录的库内时间(毫秒,三次取最好的一次);拒绝原样返回成文字
CREATE FUNCTION pg_temp.cwc_walk_ms(p_def jsonb, p_step integer, p_key text, p_id uuid, OUT ms numeric, OUT n integer) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; k integer; v numeric; BEGIN
    ms := NULL;
    FOR k IN 1 .. 3 LOOP
        t0 := clock_timestamp();
        SELECT count(*) INTO n FROM public.document_chain_walk(p_def, p_step, p_key, p_id);
        v := extract(epoch FROM clock_timestamp() - t0) * 1000;
        ms := least(coalesce(ms, v), v);
    END LOOP;
    ms := round(ms, 1);
END $$;
CREATE FUNCTION pg_temp.cwc_trail_ms(p_subject text, p_id uuid, OUT ms numeric, OUT n integer, OUT refused text) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz; k integer; v numeric; BEGIN
    ms := NULL;
    FOR k IN 1 .. 3 LOOP
        t0 := clock_timestamp();
        BEGIN
            SELECT count(*) INTO n FROM public.record_trail(p_subject, p_id::text, 20);
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM LIKE 'TRAIL_NOT_PERMITTED|%' THEN refused := 'TRAIL_NOT_PERMITTED'; ms := NULL; RETURN; END IF;
            RAISE;
        END;
        v := extract(epoch FROM clock_timestamp() - t0) * 1000;
        ms := least(coalesce(ms, v), v);
    END LOOP;
    ms := round(ms, 1);
END $$;

DO $f297$
DECLARE
    c_purchasing constant jsonb := '{"steps":[{"keys":["purchase_order"],"filter":null},{"keys":["inbound_batch"],"filter":null},{"keys":["assay_result"],"filter":null},{"keys":["inbound_batch"],"filter":null},{"keys":["inbound_batch"],"filter":"payable"},{"keys":["payment_request"],"filter":null},{"keys":["payment_out"],"filter":null},{"keys":["bank_statement"],"filter":null}],"edges":[[0,1],[1,2],[1,3],[2,3],[3,4],[4,5],[5,6],[4,6],[6,7]]}';  -- CHAIN purchasing
    c_processing constant jsonb := '{"steps":[{"keys":["work_order"],"filter":null},{"keys":["processing_run"],"filter":null},{"keys":["inbound_batch"],"filter":null},{"keys":["output_batch","output_aluminium_foil","output_anode_powder","output_anode_sheet","output_casing","output_cathode_powder","output_cathode_sheet","output_cell","output_collected_dust","output_copper_foil","output_harness_bms_busbar","output_separator","output_structural_parts"],"filter":null},{"keys":["processing_run"],"filter":"cost_allocation"}],"edges":[[0,1],[1,2],[1,3],[1,4]]}';  -- CHAIN processing
    c_sales      constant jsonb := '{"steps":[{"keys":["quote"],"filter":null},{"keys":["sales_order"],"filter":null},{"keys":["sales_order"],"filter":"reservation"},{"keys":["shipment"],"filter":null},{"keys":["container"],"filter":null},{"keys":["invoice"],"filter":null},{"keys":["payment_receipt"],"filter":null},{"keys":["credit_note"],"filter":null}],"edges":[[0,1],[1,2],[1,3],[2,3],[3,4],[1,5],[5,6],[5,7]]}';  -- CHAIN sales
    c_people     constant jsonb := '{"steps":[{"keys":["attendance_period"],"filter":null},{"keys":["overtime_batch"],"filter":null},{"keys":["leave_request"],"filter":null},{"keys":["payroll_period"],"filter":null},{"keys":["journal_entry"],"filter":"payroll_payment"}],"edges":[[0,3],[1,3],[2,3],[3,4]]}';  -- CHAIN people
    c_limit constant numeric := 300;     -- Q3:硬红的线(目标是 100)
    c_aim   constant numeric := 100;
    -- 每一张有链条的详情页:(页面, 链, 步骤序号, 种类, 单据号, 表, 变更记录主语)
    pages constant jsonb := '[
      ["/purchasing/orders/[id]", "purchasing", 0, "purchase_order", "PO-2025-0001", "purchase_orders", "purchase_order"],
      ["/inbound/[id]/edit", "purchasing", 1, "inbound_batch", "IN-2025-0001", "inbound_batches", "inbound_batch"],
      ["/inbound/[id]/edit (processing)", "processing", 2, "inbound_batch", "IN-2025-0001", "inbound_batches", null],
      ["/inbound/[id]/assays/[assayId]", "purchasing", 2, "assay_result", "ASY-2025-0001", "assay_results", null],
      ["/finance/payables/[batchId]", "purchasing", 4, "inbound_batch", "IN-2025-0001", "inbound_batches", "payable"],
      ["/finance/payment-requests/[id]", "purchasing", 5, "payment_request", "PREQ-2025-0001", "payment_requests", "payment_request"],
      ["/finance/payments/[id]", "purchasing", 6, "payment_out", "PMT-2025-0001", "payments", "payment"],
      ["/finance/payments/[id] (receipt)", "sales", 6, "payment_receipt", "RCPT-2025-0001", "payments", "payment"],
      ["/finance/bank/statements/[id]", "purchasing", 7, "bank_statement", "BS-2025-0005", "bank_statements", "bank_statement"],
      ["/operation/orders/[id]", "processing", 0, "work_order", "WO-2025-0001", "work_orders", "work_order"],
      ["/operation/processing/[id]", "processing", 1, "processing_run", "PROC-2025-0001", "processing_runs", "processing_run"],
      ["/output/[id]/edit", "processing", 3, "output_cathode_powder", "CPW-2025-00001", "output_batches", "output_batch"],
      ["/sales/quotes/[id]", "sales", 0, "quote", "QT-2025-0001", "quotes", "quote"],
      ["/sales/orders/[id]", "sales", 1, "sales_order", "SO-2025-0001", "sales_orders", "sales_order"],
      ["/sales/shipments/[id]", "sales", 3, "shipment", "SHP-2025-0001", "shipments", "shipment"],
      ["/logistics/containers/[id]", "sales", 4, "container", "CTR-2025-0001", "containers", "container"],
      ["/finance/invoices/[id]", "sales", 5, "invoice", "INV-2025-0001", "invoices", "invoice"],
      ["/finance/credit-notes/[id]", "sales", 7, "credit_note", "CN-2025-0001", "credit_notes", "credit_note"],
      ["/hr/attendance/[id]", "people", 0, "attendance_period", "ATT-2025-01", "attendance_periods", "attendance_period"],
      ["/hr/overtime/[id]", "people", 1, "overtime_batch", "OT-2025-01", "overtime_batches", "overtime_batch"],
      ["/hr/leave/[id]", "people", 2, "leave_request", "LV-2025-0001", "leave_requests", "leave_request"],
      ["/hr/payroll/[id]", "people", 3, "payroll_period", "PAY-2025-0001", "payroll_periods", "payroll_period"],
      ["/finance/journal/[id]", "people", 4, "journal_entry", "JE-2025-Wpay01", "journal_entries", "journal_entry"]
    ]';
    rd   record;
    pg   jsonb;
    v_def jsonb;
    v_id  uuid;
    v_ids jsonb := '{}';
    w    record;
    tr   record;
    v_walks integer := 0;
    v_trails integer := 0;
    v_refused integer := 0;
    v_fail text[] := '{}';
    v_worst_walk numeric := 0;  v_worst_walk_at text;
    v_worst_trail numeric := 0; v_worst_trail_at text;
    v_over_aim integer := 0;
    v_n bigint;
    v_bs uuid;
    v_slow numeric;
    v_msg text;
BEGIN
    -- ══ N 臂:体量是真的 ═════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM inbound_batches;   IF v_n < 7300 THEN RAISE EXCEPTION 'FIXTURE 297N 失败:进料批 % 行,一年的量是 7,300', v_n; END IF;
    SELECT count(*) INTO v_n FROM output_batches;    IF v_n < 15000 THEN RAISE EXCEPTION 'FIXTURE 297N 失败:产出批 % 行,一年的量是 15,000', v_n; END IF;
    SELECT count(*) INTO v_n FROM inventory_movements; IF v_n < 60000 THEN RAISE EXCEPTION 'FIXTURE 297N 失败:库存移动 % 行,一年的量是 60,000', v_n; END IF;
    SELECT count(*) INTO v_n FROM journal_entries;   IF v_n < 30000 THEN RAISE EXCEPTION 'FIXTURE 297N 失败:分录 % 张,一年的量约 30,000', v_n; END IF;
    SELECT count(*) INTO v_n FROM change_log;        IF v_n < 600000 THEN RAISE EXCEPTION 'FIXTURE 297N 失败:变更记录 % 行,一年的量约 600,000', v_n; END IF;
    SELECT count(*) INTO v_n FROM cwc_readers;       IF v_n <> 7 THEN RAISE EXCEPTION 'FIXTURE 297N 失败:读者 % 个,应当是七个角色', v_n; END IF;

    -- 每一页那一张单据的 id(以 postgres 读基表 —— 读者看不见的那一张,它的走链照样要量:页面照样会调)
    FOR pg IN SELECT jsonb_array_elements(pages) LOOP
        EXECUTE format('SELECT id FROM public.%I WHERE code = $1', pg->>5) INTO v_id USING pg->>4;
        IF v_id IS NULL THEN RAISE EXCEPTION 'FIXTURE 297A 前提失败:种子里没有 % (%)', pg->>4, pg->>0; END IF;
        v_ids := v_ids || jsonb_build_object(pg->>4, v_id);
    END LOOP;

    -- ══ A 臂:七个角色 × 每一张链条页 ══════════════════════════════════════════
    FOR rd IN SELECT * FROM cwc_readers ORDER BY role_code LOOP
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', rd.user_id), true);
        FOR pg IN SELECT jsonb_array_elements(pages) LOOP
            v_def := CASE pg->>1 WHEN 'purchasing' THEN c_purchasing WHEN 'processing' THEN c_processing
                                 WHEN 'sales' THEN c_sales ELSE c_people END;
            v_id := (v_ids ->> (pg->>4))::uuid;   -- 以 fixture 自己的身份(postgres)在开跑前查好:读者看不见的那一张照样要量
            BEGIN
                SELECT * INTO w FROM pg_temp.cwc_walk_ms(v_def, (pg->>2)::integer, pg->>3, v_id);
            EXCEPTION WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
                v_fail := v_fail || format('%s · %s 走链出错:%s', rd.role_code, pg->>0, left(v_msg, 120));
                CONTINUE;
            END;
            v_walks := v_walks + 1;
            IF w.ms > c_limit THEN v_fail := v_fail || format('%s · %s 走链 %s ms(> %s)', rd.role_code, pg->>0, w.ms, c_limit); END IF;
            IF w.ms > c_aim THEN v_over_aim := v_over_aim + 1; END IF;
            IF w.ms > v_worst_walk THEN v_worst_walk := w.ms; v_worst_walk_at := rd.role_code || ' · ' || (pg->>0); END IF;
            CONTINUE WHEN pg->>6 IS NULL;
            BEGIN
                SELECT * INTO tr FROM pg_temp.cwc_trail_ms(pg->>6, v_id);
            EXCEPTION WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
                v_fail := v_fail || format('%s · %s 变更记录出错:%s', rd.role_code, pg->>0, left(v_msg, 120));
                CONTINUE;
            END;
            IF tr.refused IS NOT NULL THEN v_refused := v_refused + 1; CONTINUE; END IF;
            v_trails := v_trails + 1;
            IF tr.ms > c_limit THEN v_fail := v_fail || format('%s · %s 变更记录 %s ms(> %s)', rd.role_code, pg->>0, tr.ms, c_limit); END IF;
            IF tr.ms > c_aim THEN v_over_aim := v_over_aim + 1; END IF;
            IF tr.ms > v_worst_trail THEN v_worst_trail := tr.ms; v_worst_trail_at := rd.role_code || ' · ' || (pg->>0); END IF;
        END LOOP;
        EXECUTE 'RESET ROLE';
    END LOOP;
    IF v_walks <> 7 * jsonb_array_length(pages) THEN
        RAISE EXCEPTION 'FIXTURE 297A 失败:只量了 % 次走链,应当 % 次 —— %', v_walks, 7 * jsonb_array_length(pages), array_to_string(v_fail, ' | ');
    END IF;
    IF v_trails + v_refused <> 7 * (SELECT count(*) FROM jsonb_array_elements(pages) x WHERE x->>6 IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 297A 失败:变更记录量了 % 段、按名拒 % 段,合计应当 % —— %', v_trails, v_refused,
            7 * (SELECT count(*) FROM jsonb_array_elements(pages) x WHERE x->>6 IS NOT NULL), array_to_string(v_fail, ' | ');
    END IF;
    IF cardinality(v_fail) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 297A 失败:% 处超过 % ms 或出错:%', cardinality(v_fail), c_limit, array_to_string(v_fail, ' | ');
    END IF;

    -- ══ F 臂:一条故意变慢的声明边,同一支计时必须量出来 ══════════════════════════
    SELECT id INTO v_bs FROM bank_statements WHERE code = 'BS-2025-0005';
    BEGIN
        ALTER FUNCTION public.document_relation_arm_pairs(text, uuid[]) RENAME TO document_relation_arm_pairs_f297;
        CREATE FUNCTION public.document_relation_arm_pairs(p_arm text, p_ids uuid[]) RETURNS TABLE(src uuid, id uuid)
          LANGUAGE plpgsql STABLE AS $slow$
          BEGIN PERFORM pg_sleep(0.35); RETURN QUERY SELECT * FROM public.document_relation_arm_pairs_f297(p_arm, p_ids); END $slow$;
        GRANT EXECUTE ON FUNCTION public.document_relation_arm_pairs(text, uuid[]) TO authenticated;
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', (SELECT user_id FROM cwc_readers WHERE role_code = 'cfo')), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT ms INTO v_slow FROM pg_temp.cwc_walk_ms(c_purchasing, 7, 'bank_statement', v_bs);
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE297F_ROLLBACK|%', v_slow;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'FIXTURE297F_ROLLBACK|%' THEN RAISE EXCEPTION 'FIXTURE 297F 失败:注入那一格自己坏了:%', v_msg; END IF;
        v_slow := split_part(v_msg, '|', 2)::numeric;
    END;
    IF v_slow IS NULL OR v_slow <= c_limit THEN
        RAISE EXCEPTION 'FIXTURE 297F 失败:一条每次睡 350 ms 的声明边,计时只量出 % ms(≤ %)—— 这支 fixture 看不见慢', v_slow, c_limit;
    END IF;
    IF to_regprocedure('public.document_relation_arm_pairs_f297(text, uuid[])') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 297F 失败:注入没有还原';
    END IF;

    RAISE NOTICE 'FIXTURE 297 全部通过:A 七个角色 × % 张链条页:走链 % 次、最慢 % ms(%)· 变更记录 % 段、最慢 % ms(%),按名拒 % 段;'
                 '超过 100 ms 目标的 % 个,超过 300 ms 的 0 个 · N 一年的量 · F 一条睡 350 ms 的声明边量出 % ms(> 300,红)',
                 jsonb_array_length(pages), v_walks, v_worst_walk, v_worst_walk_at, v_trails, v_worst_trail, v_worst_trail_at, v_refused,
                 v_over_aim, v_slow;
END;
$f297$;
ROLLBACK;

-- db/scripts/2026-09-30-at1b2-live-proof.sql
-- AUDIT-TRAIL-1b-2 · 活库上的证明 —— 整支是【一笔回滚的事务】,文件以 ROLLBACK 收尾。
--   A 只读:线上【每一张】报价与销售订单,以 tim@(cfo,634c00f9)的身份读 record_trail,与它们原来那两段"历史"的来源表
--     (quote_history / sales_order_history)逐行对照:每一行历史都在新的记录里吗?缺的逐行点名。
--     整份记录也吐出来(\o 那一段,一行一条记录),交回报告用 lib/trail/render.ts 造成句子,再逐行对着旧的那一段看。
--   B 在这一笔事务里:以 admin@(321f1819,持全部码)建一张报价、一张销售订单,各改一次(报价:备注 · 明细数量 · 签发;
--     订单:确认 · 改明细);以 sandra@(cco,持 module.suppliers.edit)建一家供应商并改一次(备注 · 合规证书 · 送审),
--     再由 tim@ 批准它。★ 为什么供应商由 sandra@ 建:持 action.supplier_approve 的只有 Tim 的两个账号(admin@ 与 tim@ 是
--     同一个人,forbid_self_approval 按人认 —— 第一次跑就是在这里被 SELF_APPROVAL_FORBIDDEN|raiser 拦下的,整笔回滚)。
--     然后以 tim@ 读这三条记录,吐出来,ROLLBACK。审批开着:这一笔里没有一张单据留成在途 —— 整笔都不在了。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -v out=<目录> -f db/scripts/2026-09-30-at1b2-live-proof.sql
BEGIN;
SET LOCAL statement_timeout = '600s';

-- ── A · 只读:每一张报价与订单,旧"历史"的每一行都在新的记录里 ─────────────────────────────
DO $a$
DECLARE
    d record; v_j jsonb; v_old int; v_found int; t_old int := 0; t_found int := 0; t_docs int := 0; v_miss text; t_miss text := '';
BEGIN
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    FOR d IN SELECT 'quote' AS s, id, code FROM quotes UNION ALL SELECT 'sales_order', id, code FROM sales_orders WHERE deleted_at IS NULL ORDER BY 1, 3 LOOP
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT jsonb_agg(to_jsonb(r)) INTO v_j FROM record_trail(d.s, d.id::text, 500) r;
        EXECUTE 'RESET ROLE';
        IF d.s = 'quote' THEN
            SELECT count(*), count(*) FILTER (WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                      WHERE e ->> 'table_name' = 'quote_history' AND e -> 'row_key' ->> 'id' = h.id::text AND NOT (e ->> 'row_hidden')::boolean)),
                   string_agg(h.change_type, ',') FILTER (WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                      WHERE e ->> 'table_name' = 'quote_history' AND e -> 'row_key' ->> 'id' = h.id::text))
              INTO v_old, v_found, v_miss FROM quote_history h WHERE h.quote_id = d.id;
        ELSE
            SELECT count(*), count(*) FILTER (WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                      WHERE e ->> 'table_name' = 'sales_order_history' AND e -> 'row_key' ->> 'id' = h.id::text AND NOT (e ->> 'row_hidden')::boolean)),
                   string_agg(h.change_type, ',') FILTER (WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                      WHERE e ->> 'table_name' = 'sales_order_history' AND e -> 'row_key' ->> 'id' = h.id::text))
              INTO v_old, v_found, v_miss FROM sales_order_history h WHERE h.sales_order_id = d.id;
        END IF;
        RAISE NOTICE 'LIVE_A % %: old history rows % · found in the trail % · trail rows %', d.s, d.code, v_old, v_found, jsonb_array_length(COALESCE(v_j, '[]'));
        IF v_miss IS NOT NULL THEN t_miss := t_miss || d.code || ' (' || v_miss || ') '; END IF;
        t_old := t_old + v_old; t_found := t_found + v_found; t_docs := t_docs + 1;
    END LOOP;
    RAISE NOTICE 'LIVE_A total: % records · % old history rows · % found · missing: %', t_docs, t_old, t_found, COALESCE(NULLIF(t_miss, ''), 'none');
END;
$a$;

-- A 的整份记录(一行一条),给 lib/trail/render.ts 造句
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SET LOCAL ROLE authenticated;
\pset tuples_only on
\pset format unaligned
\o :out/live-a.jsonl
SELECT jsonb_build_object('s', x.s, 'id', x.id, 'l', x.code, 'rows', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at)
         FROM record_trail(x.s, x.id::text, 500) r), '[]'::jsonb))
  FROM (SELECT 'quote' AS s, id, code FROM quotes UNION ALL SELECT 'sales_order', id, code FROM sales_orders WHERE deleted_at IS NULL) x ORDER BY x.s, x.code;
\o
RESET ROLE;

-- ── B · 在这一笔里建、改、读(随后整笔回滚)─────────────────────────────────────────────
DO $b$
DECLARE
    k_admin constant uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';
    k_tim   constant uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';
    k_sandra constant uuid := '01ae00e4-306f-4527-8537-10291e4750c7';
    v_ccy text; v_cus uuid; v_mat uuid; v_ct text; v_qt uuid; v_ql uuid; v_so uuid; v_sol uuid; v_sup uuid; v_r jsonb;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT id INTO v_cus FROM customers WHERE code = 'CUS-2026-0003';          -- Test Customer
    SELECT id INTO v_mat FROM materials WHERE name = 'NMC Cathode Foil' AND deleted_at IS NULL ORDER BY code LIMIT 1;
    SELECT code INTO v_ct FROM certificate_types WHERE is_active ORDER BY sort_order, code LIMIT 1;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', k_admin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- 报价:建(带一行明细)· 改备注 · 改数量 · 签发
    -- 单号由触发器填(与报价表单同一条路;next_quote_code 对 authenticated 收权)
    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES (v_cus, CURRENT_DATE, CURRENT_DATE + 30, v_ccy, 1) RETURNING id INTO v_qt;
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price) VALUES (v_qt, 1, v_mat, 10, 28) RETURNING id INTO v_ql;
    UPDATE quotes SET notes = 'AT-1b-2 live proof — rolled back' WHERE id = v_qt;
    UPDATE quote_lines SET quantity = 12 WHERE id = v_ql;
    PERFORM record_qt_issue(v_qt, 'quotes/at1b2-proof/v1.pdf', repeat('b', 64));
    -- 销售订单:建 · 确认 · 改明细(带理由)
    v_r := create_sales_order(v_cus, CURRENT_DATE, v_ccy, 1, jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10, 'unit_price', 34.5)),
                              'AT-1b-2 live proof — rolled back');
    v_so := (v_r ->> 'id')::uuid;
    SELECT id INTO v_sol FROM sales_order_lines WHERE sales_order_id = v_so;
    PERFORM set_sales_order_status(v_so, 'confirmed');
    PERFORM amend_sales_order(v_so, 'Customer takes 8 kg', NULL, jsonb_build_array(jsonb_build_object('id', v_sol, 'quantity', 8, 'unit_price', 34.5)));
    -- 供应商:sandra@ 建 · 改备注 · 加合规证书 · 送审;tim@ 批准(建档人不能批自己建的,按人认)
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', k_sandra), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('draft', 'ZZ-AT1B2-PROOF', 'AT-1b-2 proof supplier (rolled back)', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    UPDATE suppliers SET notes = 'AT-1b-2 live proof — rolled back' WHERE id = v_sup;
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    VALUES (v_sup, v_ct, 'PROOF-001', CURRENT_DATE, CURRENT_DATE + 365);
    PERFORM set_supplier_status(v_sup, 'pending_review', 'Ready for review');
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', k_tim), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_supplier_status(v_sup, 'approved', 'Licence checked');
    EXECUTE 'RESET ROLE';
    CREATE TEMP TABLE at1b2_proof_ids ON COMMIT DROP AS SELECT 'quote'::text AS s, v_qt AS id UNION ALL SELECT 'sales_order', v_so UNION ALL SELECT 'supplier', v_sup;
    GRANT SELECT ON at1b2_proof_ids TO authenticated;   -- 下面以登录账号的身份读它(随事务一起消失)
    RAISE NOTICE 'LIVE_B created quote %, sales order %, supplier ZZ-AT1B2-PROOF inside the transaction',
        (SELECT code FROM quotes WHERE id = v_qt), (SELECT code FROM sales_orders WHERE id = v_so);
END;
$b$;

-- B 的三条记录,以 tim@ 读(一个登录的账号)
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) \g /dev/null
SET LOCAL ROLE authenticated;
\o :out/live-b.jsonl
SELECT jsonb_build_object('s', p.s, 'id', p.id, 'l', p.s || ' (proof)', 'rows', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at)
         FROM record_trail(p.s, p.id::text, 50) r), '[]'::jsonb))
  FROM at1b2_proof_ids p ORDER BY p.s;
\o
RESET ROLE;

ROLLBACK;

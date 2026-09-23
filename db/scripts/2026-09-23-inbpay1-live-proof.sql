-- INB-PAY-1 线上证明 —— 整支跑在一笔【必然回滚】的事务里,线上什么都不留。
--
-- 为什么不在 db/fixtures/:fixture 208 已经在重建库上钉了同样的主张;这一支问的是
-- 【线上这个库、线上这支函数、以一个真人的会话】是不是也这样。身份:authenticated +
-- 一个 admin 账号的 JWT(current_user 与 auth.uid() 都当场读出来印在结果里)。
-- 断言一律 RAISE —— 屏幕上的一段字不是判词,退出码才是。
--
-- 跑法:psql "$DSN" -X -v ON_ERROR_STOP=1 -f db/scripts/2026-09-23-inbpay1-live-proof.sql
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',
    '{"sub":"321f1819-8449-48f7-9ae0-78b2c4b50f35","role":"authenticated"}', true);
DO $$
DECLARE
    v_sup  uuid := '6fd51aec-177d-4912-9973-7c195a3fc87a';   -- SUP-2026-0002(goods_supplier)
    v_mat  uuid := '5d4c059f-ff78-4e0d-b117-6be775a05f7e';
    v_base text;
    v_res jsonb; b_a uuid; b_b uuid;
    la text; lb text; pa text; pb text;
    v_net numeric; v_doc numeric; v_msg text;
BEGIN
    RAISE NOTICE 'PROOF identity: current_user=% auth.uid()=%', current_user, auth.uid();
    IF current_user <> 'authenticated' THEN
        RAISE EXCEPTION 'PROOF 前提失败:应当以 authenticated 跑,实得 %', current_user;
    END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- A 建单带价(本位币)
    v_res := create_inbound_batch(v_mat, v_sup, 14, 'kg', CURRENT_DATE, '待加工', 150,
        'INB-PAY-1 proof A', p_source_reason_code => 'other',
        p_source_reason_note => 'INB-PAY-1 live proof (rolled back)', p_currency => v_base);
    b_a := (v_res->>'batch_id')::uuid;
    RAISE NOTICE 'PROOF A: journal %', v_res->'pricing'->>'journal_code';

    -- B 先建不带价,再经定价那一步定同一个价
    v_res := create_inbound_batch(v_mat, v_sup, 14, 'kg', CURRENT_DATE, '待加工', NULL,
        'INB-PAY-1 proof B', p_source_reason_code => 'other',
        p_source_reason_note => 'INB-PAY-1 live proof (rolled back)', p_currency => v_base);
    b_b := (v_res->>'batch_id')::uuid;
    PERFORM set_inbound_unit_price(b_b, 150, v_base);

    RESET ROLE;   -- 读分录与价格史的原列(price_history 有列级遮蔽)用 postgres
    SELECT string_agg(a.code||':'||jl.debit||':'||jl.credit, ',' ORDER BY a.code) INTO la
    FROM journal_lines jl JOIN journal_entries e ON e.id=jl.entry_id JOIN accounts a ON a.id=jl.account_id
    WHERE e.source_type='purchase' AND e.source_id=b_a;
    SELECT string_agg(a.code||':'||jl.debit||':'||jl.credit, ',' ORDER BY a.code) INTO lb
    FROM journal_lines jl JOIN journal_entries e ON e.id=jl.entry_id JOIN accounts a ON a.id=jl.account_id
    WHERE e.source_type='purchase' AND e.source_id=b_b;
    SELECT string_agg(concat_ws(':',old_unit_price,new_unit_price,currency,original_price,fx_rate,rate_type),',') INTO pa
    FROM price_history WHERE inbound_batch_id=b_a;
    SELECT string_agg(concat_ws(':',old_unit_price,new_unit_price,currency,original_price,fx_rate,rate_type),',') INTO pb
    FROM price_history WHERE inbound_batch_id=b_b;
    RAISE NOTICE 'PROOF lines  A=[%]  B=[%]', la, lb;
    RAISE NOTICE 'PROOF prices A=[%]  B=[%]', pa, pb;
    IF la IS NULL OR la IS DISTINCT FROM lb OR pa IS NULL OR pa IS DISTINCT FROM pb THEN
        RAISE EXCEPTION 'PROOF 失败:建单带价与之后再定价没有过同一条账';
    END IF;

    -- C 对 A 再定价 150 → 160:总账 2000 净额 = 数量 × 单价
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_inbound_unit_price(b_a, 160, v_base);
    RESET ROLE;
    SELECT COALESCE(sum(jl.credit-jl.debit),0) INTO v_net
    FROM journal_lines jl JOIN journal_entries e ON e.id=jl.entry_id JOIN accounts a ON a.id=jl.account_id
    WHERE a.code='2000' AND e.source_type='purchase' AND e.source_id=b_a;
    SELECT round(quantity*unit_price,2) INTO v_doc FROM inbound_batches WHERE id=b_a;
    RAISE NOTICE 'PROOF C: 2000 net % / document value %', v_net, v_doc;
    IF v_net <> v_doc OR v_doc <> 2240.00 THEN
        RAISE EXCEPTION 'PROOF 失败:再定价之后总账 % ≠ 单据 %', v_net, v_doc;
    END IF;

    -- E 拒绝按名(价格 0)
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        PERFORM create_inbound_batch(v_mat, v_sup, 5, 'kg', CURRENT_DATE, '待加工', 0, NULL,
            p_source_reason_code => 'other', p_source_reason_note => 'INB-PAY-1 live proof', p_currency => v_base);
        RAISE EXCEPTION 'PROOF 失败:价格 0 建成了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PRICE_INVALID%' THEN RAISE EXCEPTION 'PROOF 失败:价格 0 应拒 PRICE_INVALID,实得 %', v_msg; END IF;
        RAISE NOTICE 'PROOF E: price 0 refused by name: %', v_msg;
    END;
    RESET ROLE;
    -- 借贷平衡是 DEFERRABLE 的约束触发器:放在【最后】强制校验一次(放在开头会在
    -- 第一条分录行就判不平 —— 本脚本第一次跑就这么红过,fixture 104 注释里写着同一条)
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'PROOF PASSED (inside the transaction; ROLLBACK follows)';
END;
$$;

ROLLBACK;

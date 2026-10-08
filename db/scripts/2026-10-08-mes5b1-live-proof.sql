-- db/scripts/2026-10-08-mes5b1-live-proof.sql
-- MES-5b-1 · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关。
--   由 db/scripts/2026-10-08-mes5b1-live-proof.mjs 驱动:它先用 mintThrowaway 造一次性账号(前缀 mes5b1probe),
--   再以 psql 跑本文件,把那些邮箱经 -v 传进来;跑完按 ephemeral 计划收走账号、授权、一次性角色。
--   【每一步都以一次性账号跑】(Tim:证明里动手的是一次性账号,不是七个真账号):
--     rcv  = 进料查看 / 编辑 + action.receive_goods                         —— 收两家供应商的货、一批模组
--     ops  = 加工查看 / 编辑 + 提交 + 提交之后的记录 + 采集确认 + 进料查看 + 产出查看 / 编辑 + 库存查看(拆分把子批转进隔离库位)—— 炉次、产出批的安全状态、损耗、结平、放电结果、拆分、V37、读三张页面
--     mgr  = action.manage_permissions                                       —— 存一个违反新规矩的角色,被按名拒
--     pv   = 只持 module.processing.view                                     —— 七个真角色都持 module.inbound.view,所以供应商名字的「受限」由它来读
--     c_<角色> = 七个真角色【此刻的码】的一次性克隆(cloneOf)—— 逐角色读数表(只读,不动手)
--   设置用的行(两家供应商、五种物料、一个隔离库位、一个一次性角色)以属主身份插进来;全部以 ZZ-PROBE-MES5B1 起名。
--   在册的单据、批次、炉次、设备、安全状态一张都不碰、不决定、不改。
--   ① rcv 收 A(P1 · S1 · 200 kg)、B(P2 · S2 · 100 kg)、C(模组 · S1 · 300 kg · 3 个模组 · 带电未放电)。
--   ② ops 提交 R1(battery_powder_line:A 200 + B 100 → 黑粉 170 + 粉尘 80,扫地料 20,余数 30)与 R2(O1 的 100 → 黑粉 90,水分 4,余数 6),
--      两张都结平(容差没给 → 带说明)。
--   ③ ops 对 C 记一炉深度放电 RD(300 穿过去)、三个模组的结果(两过一败 · 隔离)、拆出 M03 的 90 kg 进隔离库位 → RS + 子批 Q;RS 自己结平。
--   ④ 读:每一批的树(每一层精确相加;放电是事件、拆分是一次搬运)、这个月的月度平衡(恒等式;穿过去的另列)、得率(每炉 · 工序 × 月 · 分组)。
--   ⑤ V37:ops 给 battery_powder_line × black_mass 70 % → R1 与这个月被标出来、R2 不标;给之前 V37 列着这道工序的每一种形态。
--   ⑥ mgr 存一个只持 action.manage_devices 的角色 → ACTION_REQUIRES_VIEW|action.manage_devices|module.processing.view;加上查看码就存得下。
--   ⑦ 逐角色读数表:七个克隆各自读月度平衡、得率页(含供应商名字是否受限)与一个批次的平衡面板。
-- 打印的每一行都是 STEP|… 或 ROLE|… ;任何一处与预期不符就 RAISE,整笔回滚。
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SELECT set_config('mes5b1.rcv', :'rcv', true), set_config('mes5b1.ops', :'ops', true), set_config('mes5b1.mgr', :'mgr', true),
       set_config('mes5b1.pv', :'pv', true),
       set_config('mes5b1.c_admin', :'c_admin', true), set_config('mes5b1.c_finance', :'c_finance', true),
       set_config('mes5b1.c_warehouse', :'c_warehouse', true), set_config('mes5b1.c_cto', :'c_cto', true),
       set_config('mes5b1.c_cco', :'c_cco', true), set_config('mes5b1.c_cfo', :'c_cfo', true), set_config('mes5b1.c_gm', :'c_gm', true) \g /dev/null

CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid; e text := current_setting('mes5b1.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = e;
    IF v IS NULL OR e NOT LIKE 'mes5b1probe-%@test.local' THEN RAISE EXCEPTION 'MES5B1_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.me_() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
END $f$;
CREATE FUNCTION pg_temp.try_(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END $f$;
-- 一棵树(根 = p_root)里违反恒等式的结点 —— 与 fixture 257 的 f257_tree_bad 同一个判据(有理数比较)
CREATE FUNCTION pg_temp.tree_bad_(p_root uuid) RETURNS text LANGUAGE sql AS $f$
    WITH t AS (SELECT * FROM batch_balance_tree WHERE root_id = p_root),
    runs AS (
        SELECT p.node_key, p.x, p.share_num, p.share_den,
               (SELECT count(DISTINCT (c.share_num, c.share_den)) FROM t c WHERE c.parent_key = p.node_key) AS shares,
               (SELECT sum(c.x) FROM t c WHERE c.parent_key = p.node_key) AS sx,
               (SELECT min(c.share_num) FROM t c WHERE c.parent_key = p.node_key) AS cn,
               (SELECT min(c.share_den) FROM t c WHERE c.parent_key = p.node_key) AS cd
          FROM t p WHERE p.node_type = 'run'),
    bats AS (
        SELECT p.node_key, p.x,
               (SELECT sum(c.x) FROM t c WHERE c.parent_key = p.node_key AND c.node_type = 'fate' AND c.line_key <> 'unexplained') AS fates,
               (SELECT c.x FROM t c WHERE c.parent_key = p.node_key AND c.line_key = 'unexplained') AS unexpl,
               (SELECT c.x FROM t c WHERE c.parent_key = p.node_key AND c.node_type = 'fate' AND c.line_key = 'consumed') AS consumed,
               (SELECT COALESCE(sum(c.x), 0) FROM t c WHERE c.parent_key = p.node_key AND c.node_type = 'run' AND c.line_key = 'consumption') AS cons_runs,
               (SELECT c.x FROM t c WHERE c.parent_key = p.node_key AND c.node_type = 'fate' AND c.line_key = 'split') AS split,
               (SELECT COALESCE(sum(c.x), 0) FROM t c WHERE c.parent_key = p.node_key AND c.node_type = 'run' AND c.line_key = 'transfer') AS split_runs
          FROM t p WHERE p.node_type IN ('batch', 'run_output'))
    SELECT string_agg(k, '; ') FROM (
        SELECT 'run ' || node_key AS k FROM runs WHERE sx IS NOT NULL AND (shares <> 1 OR sx * cn * share_den <> x * share_num * cd)
        UNION ALL
        SELECT 'batch ' || node_key FROM bats WHERE fates <> x OR unexpl <> 0 OR consumed <> cons_runs OR split <> split_runs) z
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_(), pg_temp.try_(text), pg_temp.tree_bad_(uuid) TO authenticated;

DO $proof$
DECLARE
    d    date := (now() AT TIME ZONE 'Asia/Singapore')::date - 1;
    mon  date;
    t9 timestamptz; t11 timestamptz; t10 timestamptz; t1030 timestamptz;
    s1 uuid; s2 uuid; m_p1 uuid; m_p2 uuid; m_bm uuid; m_dust uuid; m_mod uuid; lq uuid; r_probe uuid;
    ba uuid; bb uuid; bc uuid; o1 uuid; q uuid; r1 uuid; r2 uuid; rd uuid; rs uuid;
    v_j jsonb; v_msg text; v_bad text; v_n bigint; v_num numeric; v_txt text;
    runs_before text; batches_before text; mv_before text; c text;
BEGIN
    mon := date_trunc('month', d)::date;
    t9 := (d::timestamp + interval '9 hours') AT TIME ZONE 'Asia/Singapore';
    t10 := (d::timestamp + interval '10 hours') AT TIME ZONE 'Asia/Singapore';
    t1030 := (d::timestamp + interval '10 hours 30 minutes') AT TIME ZONE 'Asia/Singapore';
    t11 := (d::timestamp + interval '11 hours') AT TIME ZONE 'Asia/Singapore';
    -- 在册行的指纹(证明结束时再比 —— 一张都不许动)
    SELECT md5(COALESCE(string_agg(to_jsonb(r)::text, '|' ORDER BY r.id), '')) INTO runs_before FROM processing_runs r;
    SELECT md5(COALESCE(string_agg(to_jsonb(b)::text, '|' ORDER BY b.id), '')) INTO batches_before
      FROM (SELECT id, code, remaining_qty, deleted_at FROM inbound_batches UNION ALL SELECT id, code, remaining_qty, deleted_at FROM output_batches) b;
    SELECT md5(COALESCE(string_agg(to_jsonb(m)::text, '|' ORDER BY m.id), '')) INTO mv_before FROM inventory_movements m;
    IF EXISTS (SELECT 1 FROM processing_balance_monthly_all WHERE month = mon) THEN
        RAISE EXCEPTION 'MES5B1_LIVE|the proof month % already has runs on live — pick another day', mon;
    END IF;

    -- ── 设置(属主):两家供应商、五种物料、一个隔离库位、一个一次性角色 ──
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES5B1-S1', 'ZZ-PROBE-MES5B1 supplier one', 'SG', 'active', 'goods_supplier') RETURNING id INTO s1;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES5B1-S2', 'ZZ-PROBE-MES5B1 supplier two', 'SG', 'active', 'goods_supplier') RETURNING id INTO s2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code, chemistry)
    VALUES ('ZZ-PROBE-MES5B1-P1', 'ZZ-PROBE-MES5B1 packs NMC', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction', 'NMC') RETURNING id INTO m_p1;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ-PROBE-MES5B1-P2', 'ZZ-PROBE-MES5B1 packs', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction') RETURNING id INTO m_p2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-PROBE-MES5B1-BM', 'ZZ-PROBE-MES5B1 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-PROBE-MES5B1-DUST', 'ZZ-PROBE-MES5B1 dust', 'battery_material', true, 'collected_dust', 'end_of_life') RETURNING id INTO m_dust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ-PROBE-MES5B1-MOD', 'ZZ-PROBE-MES5B1 modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO storage_locations (code, name, is_active, is_quarantine) VALUES ('ZZ-PROBE-MES5B1-Q', 'ZZ-PROBE-MES5B1 quarantine', true, true) RETURNING id INTO lq;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('probe-mes5b1-x', 'ZZ-PROBE-MES5B1 role', 'ZZ-PROBE-MES5B1 角色', true) RETURNING id INTO r_probe;

    -- ── ① 收货(rcv)──
    PERFORM pg_temp.as_('rcv');
    v_j := create_inbound_batch(p_material_id => m_p1, p_supplier_id => s1, p_quantity => 200, p_arrival_date => d - 1,
                                p_safety_states => ARRAY['charged_not_discharged'], p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES5B1');
    ba := (v_j ->> 'batch_id')::uuid;
    v_j := create_inbound_batch(p_material_id => m_p2, p_supplier_id => s2, p_quantity => 100, p_arrival_date => d - 1,
                                p_safety_states => ARRAY['charged_not_discharged'], p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES5B1');
    bb := (v_j ->> 'batch_id')::uuid;
    v_j := create_inbound_batch(p_material_id => m_mod, p_supplier_id => s1, p_quantity => 300, p_arrival_date => d - 1,
                                p_safety_states => ARRAY['charged_not_discharged'], p_source_reason_code => 'other', p_source_reason_note => 'ZZ-PROBE-MES5B1',
                                p_module_count => 3);
    bc := (v_j ->> 'batch_id')::uuid;
    PERFORM pg_temp.me_();
    RAISE NOTICE 'STEP|receive|A % (S1, 200) · B % (S2, 100) · C % (S1, 300, 3 modules)',
        (SELECT code FROM inbound_batches WHERE id = ba), (SELECT code FROM inbound_batches WHERE id = bb), (SELECT code FROM inbound_batches WHERE id = bc);

    -- ── ② 两炉消耗 + 损耗 + 结平(ops)──
    PERFORM pg_temp.as_('ops');
    r1 := commit_processing_run(d, 'ZZ-PROBE-MES5B1 R1', NULL,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', ba, 'quantity_consumed', 200), jsonb_build_object('inbound_batch_id', bb, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', m_bm, 'weight_kg', 170), jsonb_build_object('material_id', m_dust, 'weight_kg', 80)),
            'weight', NULL, NULL, 'battery_powder_line', p_started_at => t9, p_ended_at => t11, p_shift_code => 'day');
    PERFORM record_run_loss(r1, 'sweepings', 20);
    SELECT po.output_batch_id INTO o1 FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = r1 AND ob.material_id = m_bm;
    -- 一批新产出的黑粉要先记下它的安全状态才能再喂(PRODUCED_SAFETY_STATE_NOT_RECORDED)—— 产出批的状态归 module.output.edit
    PERFORM set_output_safety_states(o1, ARRAY['discharged_verified']);
    r2 := commit_processing_run(d, 'ZZ-PROBE-MES5B1 R2', NULL,
            jsonb_build_array(jsonb_build_object('output_batch_id', o1, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', m_bm, 'weight_kg', 90)),
            'weight', NULL, NULL, 'battery_powder_line', p_started_at => t9, p_ended_at => t11, p_shift_code => 'day');
    PERFORM record_run_loss(r2, 'moisture', 4);
    PERFORM close_run_balance(r1, 'ZZ-PROBE-MES5B1: 30 kg not yet accounted for (test run)');
    PERFORM close_run_balance(r2, 'ZZ-PROBE-MES5B1: 6 kg not yet accounted for (test run)');
    PERFORM pg_temp.me_();
    RAISE NOTICE 'STEP|runs|R1 % (A 200 + B 100 → black mass 170 + dust 80, sweepings 20, remainder 30) · R2 % (O1 % 100 → 90, moisture 4, remainder 6) · both closed: %',
        (SELECT code FROM processing_runs WHERE id = r1), (SELECT code FROM processing_runs WHERE id = r2), (SELECT code FROM output_batches WHERE id = o1),
        (SELECT string_agg(remainder_state, ',') FROM processing_run_flow_all WHERE run_id IN (r1, r2));

    -- ── ③ 深度放电 + 拆去隔离(ops)──
    PERFORM pg_temp.as_('ops');
    rd := commit_processing_run(d, 'ZZ-PROBE-MES5B1 RD', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', bc, 'quantity_consumed', 300)), '[]'::jsonb,
            'weight', NULL, NULL, 'deep_discharge', p_started_at => t9, p_ended_at => t11, p_shift_code => 'day');
    PERFORM record_discharge_module_result(rd, 'inbound', bc, 'M01', 0.4, 'pass', t10);
    PERFORM record_discharge_module_result(rd, 'inbound', bc, 'M02', 0.4, 'pass', t10);
    PERFORM record_discharge_module_result(rd, 'inbound', bc, 'M03', 9.0, 'fail', t10, 'quarantine');
    v_j := split_failed_modules_to_quarantine(rd, 'inbound', bc, ARRAY['M03'], d, t10, t1030, 'day', lq, 90);
    rs := (v_j ->> 'split_run_id')::uuid;
    q := (v_j ->> 'batch_id')::uuid;
    PERFORM pg_temp.me_();
    IF (SELECT remainder_state FROM processing_run_flow_all WHERE run_id = rs) <> 'closed_within' OR (v_j ->> 'balance_closure_id') IS NULL THEN
        RAISE EXCEPTION 'MES5B1_LIVE|the split should close its own balance in the same step';
    END IF;
    RAISE NOTICE 'STEP|discharge+split|RD % (C 300 passed through) · split % (M03 90 kg → % in quarantine) · split balance %',
        (SELECT code FROM processing_runs WHERE id = rd), (SELECT code FROM processing_runs WHERE id = rs), (SELECT code FROM output_batches WHERE id = q),
        (SELECT remainder_state FROM processing_run_flow_all WHERE run_id = rs);

    -- ── ④ 读(ops 的会话,经带门的外壳)──
    PERFORM pg_temp.as_('ops');
    FOR c IN SELECT unnest(ARRAY['A', 'B', 'C', 'O1', 'Q']) LOOP
        v_bad := pg_temp.tree_bad_(CASE c WHEN 'A' THEN ba WHEN 'B' THEN bb WHEN 'C' THEN bc WHEN 'O1' THEN o1 ELSE q END);
        IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_LIVE|batch % does not add up exactly: %', c, v_bad; END IF;
    END LOOP;
    SELECT string_agg(line_key || '=' || x, ' · ' ORDER BY line_key) INTO v_txt FROM batch_balance_tree WHERE root_id = ba AND parent_key = 'r' AND node_type = 'fate' AND x <> 0;
    RAISE NOTICE 'STEP|tree A|received % · %; R1 children share %/%', (SELECT x FROM batch_balance_tree WHERE root_id = ba AND node_type = 'batch'), v_txt,
        (SELECT min(share_num) FROM batch_balance_tree WHERE root_id = ba AND run_id = r1 AND node_type = 'run_loss'),
        (SELECT min(share_den) FROM batch_balance_tree WHERE root_id = ba AND run_id = r1 AND node_type = 'run_loss');
    -- A 在 R1 里那一份 200/300:黑粉 113.333…、粉尘 53.333…、扫地料 13.333…、余数 20;R2 经 O1:200·100 / 300·100
    IF (SELECT count(*) FROM batch_balance_tree WHERE root_id = ba AND depth = 2 AND share_num = 200 AND share_den = 300) <> 4
       OR (SELECT count(*) FROM batch_balance_tree WHERE root_id = ba AND run_id = r2 AND node_type IN ('run_output', 'run_loss', 'run_remainder')
             AND share_num = 20000 AND share_den = 30000) <> 3 THEN
        RAISE EXCEPTION 'MES5B1_LIVE|A''s share should be 200/300 in R1 and carry into R2 through O1';
    END IF;
    IF (SELECT sum(x * share_num) FROM batch_balance_tree WHERE node_type = 'run' AND run_id = r2 AND root_id IN (ba, bb)) <> 100 * 300 THEN
        RAISE EXCEPTION 'MES5B1_LIVE|R2 attributed to A and B should total exactly 100';
    END IF;
    SELECT string_agg(line_key || '=' || x, ' · ' ORDER BY line_key) INTO v_txt FROM batch_balance_tree WHERE root_id = bc AND parent_key = 'r' AND node_type = 'fate' AND x <> 0;
    IF (SELECT x FROM batch_balance_tree WHERE root_id = bc AND parent_key = 'r' AND line_key = 'split') <> 90
       OR (SELECT x FROM batch_balance_tree WHERE root_id = bc AND parent_key = 'r' AND line_key = 'on_hand') <> 210
       OR (SELECT x FROM batch_balance_tree WHERE root_id = bc AND node_type = 'event' AND line_key = 'pass_through' AND run_id = rd) <> 300
       OR EXISTS (SELECT 1 FROM batch_balance_tree WHERE root_id = bc AND run_id = rs AND node_type IN ('run_loss', 'run_remainder'))
       OR (SELECT x FROM batch_balance_tree WHERE root_id = bc AND node_type = 'run_output' AND batch_id = q) <> 90 THEN
        RAISE EXCEPTION 'MES5B1_LIVE|C should read 300 = 210 on hand + 90 split out (a transfer: no loss, no remainder), discharge 300 passed through';
    END IF;
    RAISE NOTICE 'STEP|tree C|received 300 · % · discharge %: pass-through 300 (event, not consumed) · split %: transfer → % 90, no loss, no remainder',
        v_txt, (SELECT code FROM processing_runs WHERE id = rd), (SELECT code FROM processing_runs WHERE id = rs), (SELECT code FROM output_batches WHERE id = q);
    RAISE NOTICE 'STEP|tree O1|received % · % · Q received % on hand %',
        (SELECT x FROM batch_balance_tree WHERE root_id = o1 AND node_type = 'batch'),
        (SELECT string_agg(line_key || '=' || x, ' · ' ORDER BY line_key) FROM batch_balance_tree WHERE root_id = o1 AND parent_key = 'r' AND node_type = 'fate' AND x <> 0),
        (SELECT x FROM batch_balance_tree WHERE root_id = q AND node_type = 'batch'),
        (SELECT x FROM batch_balance_tree WHERE root_id = q AND parent_key = 'r' AND line_key = 'on_hand');
    -- 月度平衡(这个月只有本证明的单)
    SELECT jsonb_object_agg(line || COALESCE(':' || line_key, '') || COALESCE(':' || basis, ''), qty) INTO v_j
      FROM processing_balance_monthly WHERE month = mon AND scope = 'plant';
    IF (v_j ->> 'input')::numeric <> 400 OR (v_j ->> 'output:black_mass')::numeric <> 260 OR (v_j ->> 'output:collected_dust')::numeric <> 80
       OR (v_j ->> 'loss:sweepings:measured')::numeric <> 20 OR (v_j ->> 'loss:moisture:measured')::numeric <> 4
       OR (v_j ->> 'remainder:closed_explained')::numeric <> 36 OR (v_j ->> 'pass_through:discharge')::numeric <> 300
       OR (v_j ->> 'pass_through:split')::numeric <> 90 THEN
        RAISE EXCEPTION 'MES5B1_LIVE|monthly plant lines %', v_j;
    END IF;
    RAISE NOTICE 'STEP|monthly %|%  ⇒ input 400 = outputs 340 + named losses 24 + remainder 36', to_char(mon, 'YYYY-MM'), v_j;
    -- 得率
    RAISE NOTICE 'STEP|yield per run|%', (SELECT string_agg(run_code || ' ' || line_kind || COALESCE(':' || line_key, '') || '=' || round(yield_pct, 2) || '%', ' · ' ORDER BY run_code, line_kind, line_key)
                                        FROM processing_run_yield WHERE run_id IN (r1, r2) AND line_kind IN ('output', 'total_output'));
    IF EXISTS (SELECT 1 FROM processing_run_yield WHERE run_id IN (rd, rs)) THEN RAISE EXCEPTION 'MES5B1_LIVE|discharge and split must have no yield'; END IF;
    IF (SELECT round(yield_pct, 4) FROM processing_yield_summary WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon
          AND line_kind = 'output' AND line_key = 'black_mass') <> 65 THEN
        RAISE EXCEPTION 'MES5B1_LIVE|the month''s black-mass yield should be 260 / 400 = 65 %%';
    END IF;
    RAISE NOTICE 'STEP|yield by supplier|%', (SELECT string_agg(COALESCE(group_label, '(restricted)') || ' input=' || round(input_qty, 3) || ' black mass=' || round(yield_pct, 2) || '%', ' · ' ORDER BY group_label)
                                            FROM processing_yield_summary WHERE group_kind = 'supplier' AND month = mon AND operation_type_code = 'battery_powder_line'
                                             AND line_kind = 'output' AND line_key = 'black_mass');
    RAISE NOTICE 'STEP|yield by chemistry|%', (SELECT string_agg(COALESCE(group_key, 'chemistry not recorded') || ' input=' || round(input_qty, 3), ' · ' ORDER BY group_key)
                                             FROM processing_yield_summary WHERE group_kind = 'chemistry' AND month = mon AND operation_type_code = 'battery_powder_line'
                                              AND line_kind = 'total_output');

    -- ── ⑤ V37 ──
    v_n := (SELECT count(*) FROM pending_values WHERE value_code = 'V37' AND item_code LIKE 'battery_powder_line/%');
    v_msg := pg_temp.try_($q$UPDATE operation_type_output_forms SET expected_yield_pct = 70 WHERE operation_type_code = 'battery_powder_line' AND form_code = 'black_mass'$q$);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'MES5B1_LIVE|ops could not set V37: %', v_msg; END IF;
    IF v_n <> (SELECT count(*) FROM operation_type_output_forms WHERE operation_type_code = 'battery_powder_line')
       OR (SELECT count(*) FROM pending_values WHERE value_code = 'V37' AND item_code = 'battery_powder_line/black_mass') <> 0
       OR (SELECT below_expected FROM processing_run_yield WHERE run_id = r1 AND line_kind = 'output' AND line_key = 'black_mass') IS NOT TRUE
       OR (SELECT below_expected FROM processing_run_yield WHERE run_id = r2 AND line_kind = 'output' AND line_key = 'black_mass') IS NOT FALSE
       OR (SELECT below_expected FROM processing_yield_summary WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon
             AND line_kind = 'output' AND line_key = 'black_mass') IS NOT TRUE THEN
        RAISE EXCEPTION 'MES5B1_LIVE|V37 70 %% should flag R1 (56.67) and the month (65), not R2 (90); pending rows before % ', v_n;
    END IF;
    PERFORM pg_temp.me_();
    RAISE NOTICE 'STEP|V37|before: % pending rows for battery_powder_line (one per output form) · set black_mass = 70 %% → R1 56.67 %% below · R2 90 %% not · month 65 %% below · nothing refused', v_n;

    -- ── ⑥ 角色保存的新规矩(mgr)──
    PERFORM pg_temp.as_('mgr');
    v_msg := pg_temp.try_(format($q$SELECT set_role_permissions(%L, ARRAY['action.manage_devices'])$q$, r_probe));
    IF v_msg <> 'ACTION_REQUIRES_VIEW|action.manage_devices|module.processing.view' THEN
        RAISE EXCEPTION 'MES5B1_LIVE|the role save should be refused by name, got %', v_msg;
    END IF;
    RAISE NOTICE 'STEP|role save refused|%', v_msg;
    v_msg := pg_temp.try_(format($q$SELECT set_role_permissions(%L, ARRAY['action.manage_devices', 'module.processing.view'])$q$, r_probe));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'MES5B1_LIVE|with the view code the role should save, got %', v_msg; END IF;
    PERFORM pg_temp.me_();
    RAISE NOTICE 'STEP|role save accepted|with module.processing.view as well';

    -- ── ⑦ 逐角色读数表(七个克隆,只读)──
    FOR c IN SELECT unnest(ARRAY['admin', 'finance', 'warehouse', 'cto', 'cco', 'cfo', 'gm', 'pv']) LOOP
        PERFORM pg_temp.as_(CASE WHEN c = 'pv' THEN 'pv' ELSE 'c_' || c END);
        RAISE NOTICE 'ROLE|%|balance page % · monthly rows % (this month input %) · roll-forward rows % · yield page % · yield rows % · supplier label % · inbound panel (page %) rows % · output panel (page %) rows % · inventory page % lifetime input %',
            c,
            CASE WHEN has_permission('module.processing.view') THEN 'open' ELSE 'refused' END,
            (SELECT count(*) FROM processing_balance_monthly),
            COALESCE((SELECT qty::text FROM processing_balance_monthly WHERE month = mon AND scope = 'plant' AND line = 'input'), '—'),
            (SELECT count(*) FROM stock_rollforward_monthly),
            CASE WHEN has_permission('module.processing.view') THEN 'open' ELSE 'refused' END,
            (SELECT count(*) FROM processing_yield_summary),
            COALESCE((SELECT CASE WHEN group_label_restricted THEN 'RESTRICTED' ELSE group_label END FROM processing_yield_summary
                       WHERE group_kind = 'supplier' AND group_key = s1::text AND month = mon AND line_kind = 'total_output' LIMIT 1), '— (no rows)'),
            CASE WHEN has_permission('module.inbound.view') THEN 'open' ELSE 'refused' END,
            (SELECT count(*) FROM batch_balance_tree WHERE root_id = ba),
            CASE WHEN has_permission('module.output.view') THEN 'open' ELSE 'refused' END,
            (SELECT count(*) FROM batch_balance_tree WHERE root_id = o1),
            CASE WHEN has_permission('module.inventory.view') THEN 'open' ELSE 'refused' END,
            COALESCE((SELECT sum(qty)::text FROM processing_balance_monthly WHERE scope = 'plant' AND line = 'input'), '—');
    END LOOP;
    PERFORM pg_temp.me_();
    PERFORM pg_temp.as_('pv');
    IF (SELECT group_label FROM processing_yield_summary WHERE group_kind = 'supplier' AND group_key = s1::text AND month = mon AND line_kind = 'total_output' LIMIT 1) IS NOT NULL
       OR (SELECT group_label_restricted FROM processing_yield_summary WHERE group_kind = 'supplier' AND group_key = s1::text AND month = mon AND line_kind = 'total_output' LIMIT 1) IS NOT TRUE THEN
        RAISE EXCEPTION 'MES5B1_LIVE|without module.inbound.view the supplier name must read restricted';
    END IF;
    PERFORM pg_temp.me_();

    -- ── 在册的一行都没动 ──
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(r)::text, '|' ORDER BY r.id), '')) FROM processing_runs r WHERE r.id NOT IN (r1, r2, rd, rs)) IS DISTINCT FROM runs_before
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(b)::text, '|' ORDER BY b.id), '')) FROM (
             SELECT id, code, remaining_qty, deleted_at FROM inbound_batches WHERE id NOT IN (ba, bb, bc)
             UNION ALL SELECT id, code, remaining_qty, deleted_at FROM output_batches WHERE material_id NOT IN (m_bm, m_dust, m_mod)) b) IS DISTINCT FROM batches_before
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(m)::text, '|' ORDER BY m.id), '')) FROM inventory_movements m
            WHERE COALESCE(m.inbound_batch_id, '00000000-0000-0000-0000-000000000000') NOT IN (ba, bb, bc)
              AND NOT EXISTS (SELECT 1 FROM output_batches ob WHERE ob.id = m.output_batch_id AND ob.material_id IN (m_bm, m_dust, m_mod))) IS DISTINCT FROM mv_before THEN
        RAISE EXCEPTION 'MES5B1_LIVE|a pre-existing run, batch or movement changed inside the proof';
    END IF;
    RAISE NOTICE 'STEP|untouched|pre-existing runs, batches and movements identical inside the transaction';
    RAISE NOTICE 'STEP|done|';
END
$proof$;

ROLLBACK;

-- 回滚之后:本证明的东西一行都不剩
SELECT 'AFTER|probe suppliers ' || (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES5B1%')
    || ' · materials ' || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES5B1%')
    || ' · locations ' || (SELECT count(*) FROM storage_locations WHERE code LIKE 'ZZ-PROBE-MES5B1%')
    || ' · probe roles ' || (SELECT count(*) FROM roles WHERE code = 'probe-mes5b1-x')
    || ' · V37 set ' || (SELECT count(*) FROM operation_type_output_forms WHERE expected_yield_pct IS NOT NULL)
    || ' · split tolerance ' || COALESCE((SELECT balance_tolerance_pct::text FROM operation_types WHERE code = 'discharge_quarantine_split'), 'NULL')
    || ' · require_calibrated_since ' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL')
    || ' · runs ' || (SELECT count(*) FROM processing_runs);

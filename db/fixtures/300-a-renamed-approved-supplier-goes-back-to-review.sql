-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 300 —— 一家已批准的供应商改了身份,它就回到待审(GOLIVE-1 第 4 行,Tim 2026-10-20 d2 #14 · 2026-10-29 Q7)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【钉的事】走的是【人真的走的那条路】:一个持 module.suppliers.view + edit 的会话,在 SET LOCAL ROLE authenticated 下直连 UPDATE
--   (就是 /suppliers/[id]/edit 的 updateSupplier 那一句)——
--   A  approved 改 legal_name → pending_review,approved_by / approved_at 清空,supplier_status_history 记一行 approved → pending_review
--   B  active 改 tax_id → pending_review(并清戳);suspended 改 counterparty_type → pending_review
--   C  已批准的改别的(notes、短名、地址)→ 状态与戳原样;只改空白(规整之后同一个名字)→ 原样
--   D  不是已批准的(draft · rejected)改法定名 → 状态不动(只有带批准戳的三种状态回待审)
--   E  回到待审的那一家:既有的守卫照常挡新采购单(PO_SUPPLIER_NOT_APPROVED|…|pending_review)
--   F  ★ 故障注入(每次都跑):子事务里拿掉 trg_suppliers_zz_requeue_on_identity_change,A 的判据必须读出"仍是 approved";子事务回滚
-- 自带数据:角色、授予、供应商全部本支自造;批准戳的批准人是一个本支自造的 auth.users 行。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
SET LOCAL statement_timeout = '120s';

-- 以编辑者的身份改一家供应商(直连写,RLS 在判),回读它此刻的状态与戳
CREATE FUNCTION pg_temp.f300_edit(p_user uuid, p_id uuid, p_set text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE format('UPDATE suppliers SET %s WHERE id = %L', p_set, p_id);
    EXECUTE 'RESET ROLE';
    SELECT jsonb_build_object('status', s.status, 'approved_by', s.approved_by, 'approved_at', s.approved_at) INTO v FROM suppliers s WHERE s.id = p_id;
    RETURN v;
END;
$f$;

DO $f300$
DECLARE
    u_ed   uuid := '00000000-0000-4000-8000-0000030000e1';
    u_ok   uuid := '00000000-0000-4000-8000-0000030000a1';
    s_app  uuid; s_act uuid; s_sus uuid; s_note uuid; s_ws uuid; s_draft uuid; s_rej uuid;
    v      jsonb;
    n      int;
BEGIN
    INSERT INTO auth.users (id) VALUES (u_ok);
    INSERT INTO roles (code, name_en, name_zh) VALUES ('zz-fx300-editor', 'ZZ fixture 300', 'ZZ fixture 300');
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT id, c FROM roles, unnest(ARRAY['module.suppliers.view', 'module.suppliers.edit']) c WHERE code = 'zz-fx300-editor';
    INSERT INTO user_roles (user_id, role_id) SELECT u_ed, id FROM roles WHERE code = 'zz-fx300-editor';

    -- 属主路径直接生成已批准 / 启用 / 暂停的供应商,戳由本支给(直连 INSERT 必须是 draft 那条只管客户端会话)
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, tax_id, approved_by, approved_at) VALUES
        ('approved',  'ZZ-F300-APP', 'ZZ F300 Approved Pte Ltd',  'SG', 'goods_supplier', 'ZZF300APP', u_ok, now()) RETURNING id INTO s_app;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, tax_id, approved_by, approved_at) VALUES
        ('active',    'ZZ-F300-ACT', 'ZZ F300 Active Pte Ltd',    'SG', 'goods_supplier', 'ZZF300ACT', u_ok, now()) RETURNING id INTO s_act;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, tax_id, approved_by, approved_at) VALUES
        ('suspended', 'ZZ-F300-SUS', 'ZZ F300 Suspended Pte Ltd', 'SG', 'goods_supplier', 'ZZF300SUS', u_ok, now()) RETURNING id INTO s_sus;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, tax_id, approved_by, approved_at) VALUES
        ('approved',  'ZZ-F300-NOT', 'ZZ F300 Notes Pte Ltd',     'SG', 'goods_supplier', 'ZZF300NOT', u_ok, now()) RETURNING id INTO s_note;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, tax_id, approved_by, approved_at) VALUES
        ('approved',  'ZZ-F300-WS',  'ZZ F300 Spaces Pte Ltd',    'SG', 'goods_supplier', 'ZZF300WS',  u_ok, now()) RETURNING id INTO s_ws;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type) VALUES
        ('draft',     'ZZ-F300-DRF', 'ZZ F300 Draft Pte Ltd',     'SG', 'goods_supplier') RETURNING id INTO s_draft;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type) VALUES
        ('rejected',  'ZZ-F300-REJ', 'ZZ F300 Rejected Pte Ltd',  'SG', 'goods_supplier') RETURNING id INTO s_rej;

    -- A
    v := pg_temp.f300_edit(u_ed, s_app, 'legal_name = ''ZZ F300 Renamed Pte Ltd''');
    IF v ->> 'status' <> 'pending_review' OR v -> 'approved_by' <> 'null'::jsonb OR v -> 'approved_at' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 300 A: an approved supplier renamed should be pending_review with no stamp — got %', v;
    END IF;
    SELECT count(*) INTO n FROM supplier_status_history WHERE supplier_id = s_app AND from_status = 'approved' AND to_status = 'pending_review';
    IF n <> 1 THEN RAISE EXCEPTION 'FIXTURE 300 A: % status-history row(s) for approved → pending_review (want 1)', n; END IF;
    IF (SELECT legal_name FROM suppliers WHERE id = s_app) <> 'ZZ F300 Renamed Pte Ltd' THEN
        RAISE EXCEPTION 'FIXTURE 300 A: the rename itself was not kept — the rule is "back to review", not "refuse the change"';
    END IF;
    -- B
    v := pg_temp.f300_edit(u_ed, s_act, 'tax_id = ''ZZF300ACT2''');
    IF v ->> 'status' <> 'pending_review' OR v -> 'approved_at' <> 'null'::jsonb THEN RAISE EXCEPTION 'FIXTURE 300 B: active + tax number → %', v; END IF;
    v := pg_temp.f300_edit(u_ed, s_sus, 'counterparty_type = ''service_vendor''');
    IF v ->> 'status' <> 'pending_review' OR v -> 'approved_at' <> 'null'::jsonb THEN RAISE EXCEPTION 'FIXTURE 300 B: suspended + type → %', v; END IF;
    -- C
    v := pg_temp.f300_edit(u_ed, s_note, 'notes = ''a note'', short_name = ''ZZ'', address = ''1 Street''');
    IF v ->> 'status' <> 'approved' OR v -> 'approved_at' = 'null'::jsonb THEN RAISE EXCEPTION 'FIXTURE 300 C: other fields changed the approval — %', v; END IF;
    v := pg_temp.f300_edit(u_ed, s_ws, 'legal_name = ''  ZZ F300   Spaces Pte Ltd '', tax_id = '' zzf300ws''');
    IF v ->> 'status' <> 'approved' OR v -> 'approved_at' = 'null'::jsonb THEN RAISE EXCEPTION 'FIXTURE 300 C: whitespace / case only (same after normalising) changed the approval — %', v; END IF;
    -- D
    v := pg_temp.f300_edit(u_ed, s_draft, 'legal_name = ''ZZ F300 Draft Renamed''');
    IF v ->> 'status' <> 'draft' THEN RAISE EXCEPTION 'FIXTURE 300 D: draft → %', v; END IF;
    v := pg_temp.f300_edit(u_ed, s_rej, 'legal_name = ''ZZ F300 Rejected Renamed''');
    IF v ->> 'status' <> 'rejected' THEN RAISE EXCEPTION 'FIXTURE 300 D: rejected → %', v; END IF;
    -- E
    BEGIN
        INSERT INTO purchase_orders (code, supplier_id, order_date, status, currency, fx_rate, category)
            VALUES ('ZZ-F300-PO', s_app, CURRENT_DATE, 'confirmed', 'SGD', 1, 'equipment_goods');
        RAISE EXCEPTION 'FIXTURE 300 E: a purchase order was accepted for a supplier back in review';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'PO_SUPPLIER_NOT_APPROVED|ZZ-F300-APP|pending_review%' THEN RAISE; END IF;
    END;
    -- F · 故障注入
    BEGIN
        DROP TRIGGER trg_suppliers_zz_requeue_on_identity_change ON suppliers;
        v := pg_temp.f300_edit(u_ed, s_note, 'legal_name = ''ZZ F300 Notes Renamed''');
        IF v ->> 'status' <> 'approved' THEN
            RAISE EXCEPTION 'FIXTURE 300 F: without the trigger the supplier still went to % — arm A does not measure the trigger', v ->> 'status';
        END IF;
        RAISE EXCEPTION 'f300 injection ok';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'f300 injection ok' THEN RAISE; END IF;
    END;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.suppliers'::regclass AND tgname = 'trg_suppliers_zz_requeue_on_identity_change') THEN
        RAISE EXCEPTION 'FIXTURE 300 F: the injection did not roll back';
    END IF;
    RAISE NOTICE 'FIXTURE 300 全部通过: 改名回待审、清戳、记历史、改动照存(A);启用改税号、暂停改类型同样(B);改别的、只改空白不动(C);草稿与驳回不动(D);回待审的不能开新采购单(E);拿掉触发器 A 的判据读出仍是 approved(F)';
END
$f300$;
ROLLBACK;

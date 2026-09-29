#!/usr/bin/env python3
"""AUDIT-TRAIL-1b-1:从镜像拼出迁移文件(形状照 build_at1a_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数从 db/functions/ 原样抽出,视图从 db/views/ 原样抽出,warehouse_requests 的读策略与列授权从 db/tables/ 原样抽出,
所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_at1b1_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-29-at1b1-trails-batches-and-operation.sql"

# 返回形状变了(多了列)—— 先 DROP 再 CREATE(同一笔事务;调它们的 record_trail / trail_row_record 是 plpgsql,
# 不记依赖,DROP 不连带它们)
RESHAPED = {"trail_subjects": "()", "trail_subject_members": "()", "trail_prelog_sources": "()"}
# 同一签名,原地替换
REPLACED = {"trail_actor": "(text, uuid, uuid)", "trail_ref_label": "(text, text, text)",
            "trail_row_record": "(text, jsonb, jsonb, jsonb)", "record_trail": "(text, text, integer)",
            "change_log_mask_rules": "()"}


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def table_security():
    """warehouse_requests 的读策略与列授权,原样取自镜像(Q12)。"""
    t = (ROOT / "db/tables/warehouse_requests.sql").read_text()
    pol = t[t.index('CREATE POLICY "warehouse_requests select by permission"'):]
    pol = pol[:pol.index(";") + 1]
    rev = t[t.index("REVOKE SELECT ON public.warehouse_requests FROM authenticated;"):]
    rev = rev[:rev.index("TO authenticated;") + len("TO authenticated;")]
    return ('DROP POLICY "warehouse_requests select by permission" ON public.warehouse_requests;\n'
            + pol + "\n" + rev + "\n")


def view():
    v = (ROOT / "db/views/warehouse_requests_masked.sql").read_text()
    return v[v.index("CREATE VIEW public.warehouse_requests_masked"):]


def grants_block():
    out = []
    for name, sig in RESHAPED.items():
        out.append(f"REVOKE EXECUTE ON FUNCTION public.{name}{sig} FROM PUBLIC, anon;")
        out.append(f"GRANT EXECUTE ON FUNCTION public.{name}{sig} TO authenticated, service_role;")
    g = (ROOT / "db/views/zzz_function_grants.sql").read_text()
    seg = g[g.index("-- AUDIT-TRAIL-1a(2026-09-29)"):]
    seg = seg[:seg.index("\n\n")] if "\n\n" in seg else seg
    out += [l for l in seg.splitlines() if l.startswith("REVOKE ")]
    return "\n".join(out) + "\n"


HEADER = """-- db/migrations/2026-09-29-at1b1-trails-batches-and-operation.sql
-- AUDIT-TRAIL-1b-1 —— 批次、工单、盘点、设备、交接班、仓库申请的审计记录;登记表的六个扩展;三条折入(v1.4.33 的一部分)。
-- 由 db/scripts/build_at1b1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1b Step 0 的 Q1–Q14 与 M1–M6,Tim 2026-09-29 全部照建议裁定)
--   ① 换形状:trail_subjects(M1 任一码 · M3 根行规则 · M6 只取几列)、trail_subject_members(M4 往上一跳 · 垫脚石 · 家)、
--      trail_prelog_sources(M2 人记成账号还是员工)—— 多了列,所以先 DROP 再 CREATE。登记表多了七个主语:
--      inbound_batch · output_batch · work_order · stocktake · equipment · shift_handover · warehouse_request;
--      processing_run 多了回滚申请与它的审批。
--   ② 原地替换:record_trail(M1–M6)、trail_actor(折入 1:不持 module.hr.view 的读者只认得出他自己,别人 Restricted)、
--      trail_row_record(只沿"家"的那一条往上走)、trail_ref_label(加工单带 ended;交接班与停机有了名字)。
--   ③ 仓库申请(Q12):读规则与 /inventory 已经给人看的对齐(module.inventory.view 或 module.finance.view);
--      amount_base 收回列权限,只经新建的 warehouse_requests_masked 按 data.view_prices 给;change_log_mask_rules 加一条。
--      ★ approval_log 的 warehouse_request 那一支【不动】(仍是财务)—— 那几行审批留痕带着申请的金额,而 approval_log 的
--        金额列对 authenticated 是整列授权的;放宽它就是把金额给了仓库。申请自己那一行记着谁批、何时、为什么。
--
-- 【不做什么】不改任何表的列、不重绑触发器、不写任何业务行、不加新权限码、不碰审批开关与名册、不碰 user_roles /
--   role_permissions。批次页的两张旧视图(batch_audit_trail / _all)原样留着、不再有人读(Q32)。
--
-- 【破窗】什么都不坏:旧应用调 record_trail 只用三个旧主语,参数不变;旧批次页读的两张旧视图没动;change_log_rows 没动。
--   仓库申请的列授权收紧只影响直接 SELECT amount_base 的人 —— 应用里没有(库存页走 warehouse_requests_visible())。
--   一处【提前】到的改变:折入 1 在新应用之前就生效 —— 仓库的账号在三张 AT-1a 页面的审计记录里看到的人名变成 Restricted。
--   那正是终态,只是早到。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;形状对;遮蔽名单与遮蔽视图没有缺口;
--   并以 tim@(cfo)与仓库的账号真的读几次。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"   # tim@evoltrya.test(cfo)—— memory 里量过的 auth.users id

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1B1_PRE|approvals are expected ON';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
                    WHERE p.proname = 'trail_subjects' AND 'view_code' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION 'AT1B1_PRE|trail_subjects does not have the AT-1a shape';
    END IF;
    IF to_regclass('public.warehouse_requests_masked') IS NOT NULL THEN
        RAISE EXCEPTION 'AT1B1_PRE|warehouse_requests_masked already exists';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1b1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1b1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
""")

parts.append("\n-- ── 1 · 换形状的三张登记表:先 DROP 旧形状,再按镜像建 ─────────────────────────────\n")
for name, sig in RESHAPED.items():
    parts.append(f"\nDROP FUNCTION public.{name}{sig};\n")
    parts.append(fn(name))
parts.append("\n-- ── 2 · 原地替换(同一签名,镜像原样)──────────────────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))
parts.append("\n-- ── 3 · 仓库申请(Q12):读规则对齐 /inventory;金额收回列权限、只经遮蔽视图给 ────────────\n")
parts.append(table_security())
parts.append("\n" + view())
parts.append("\n-- ── 4 · 收权(与 db/views/zzz_function_grants.sql 同一段;apply_migration.sh 之后还会整份重放)──\n")
parts.append(grants_block())

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1b1_pending_decider_check")
parts.append("\n-- ── 5 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1b1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    v_id   uuid;
    v_wh   uuid;
    v_j    jsonb;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1b1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1b1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1B1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1B1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1b1_pending_before b EXCEPT SELECT a.k, a.id FROM at1b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1b1_pending_after a EXCEPT SELECT b.k, b.id FROM at1b1_pending_before b)) THEN
        RAISE EXCEPTION 'AT1B1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1b1_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1B1_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1b1_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:十个主语;每一个 shown 成员表都在 change_log 的覆盖里;遮蔽名单与遮蔽视图没有缺口;
    --    仓库申请的金额列 authenticated 读不到(只经遮蔽视图);registry 三支 authenticated 调得到,内层调不到
    IF (SELECT count(*) FROM trail_subjects()) <> 10 THEN
        RAISE EXCEPTION 'AT1B1_PROOF|expected 10 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF (SELECT change_log_mask_gaps() -> 'gaps') <> '[]'::jsonb THEN
        RAISE EXCEPTION 'AT1B1_PROOF|mask gaps: %', change_log_mask_gaps();
    END IF;
    IF has_column_privilege('authenticated', 'public.warehouse_requests', 'amount_base', 'SELECT') THEN
        RAISE EXCEPTION 'AT1B1_PROOF|authenticated can still read warehouse_requests.amount_base directly';
    END IF;
    IF NOT has_column_privilege('authenticated', 'public.warehouse_requests', 'status', 'SELECT') THEN
        RAISE EXCEPTION 'AT1B1_PROOF|authenticated lost the non-sensitive columns of warehouse_requests';
    END IF;
    IF has_table_privilege('anon', 'public.warehouse_requests_masked', 'SELECT') THEN
        RAISE EXCEPTION 'AT1B1_PROOF|anon can read warehouse_requests_masked';
    END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B1_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B1_PROOF|anon can execute %', f;
        END IF;
    END LOOP;
    FOREACH f IN ARRAY ARRAY['public.trail_ref_label(text, text, text)', 'public.trail_row_record(text, jsonb, jsonb, jsonb)',
                             'public.trail_actor(text, uuid, uuid)'] LOOP
        IF has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1B1_PROOF|authenticated can execute the inner function %', f;
        END IF;
    END LOOP;

    -- ⑤ 真的读几次:tim@(cfo)读一张进料批次 —— 读得到、带着"记录开始之前"的那一段;
    --    仓库的账号(持加工、不持财务)读一台设备 —— 不被拒(M3);读仓库申请的遮蔽视图不报错
    SELECT id INTO v_id FROM inbound_batches WHERE code = 'IN-2026-0001';
    PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT jsonb_agg(to_jsonb(r)) INTO v_j FROM record_trail('inbound_batch', v_id::text, 200) r;
    EXECUTE 'RESET ROLE';
    IF v_j IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean) THEN
        RAISE EXCEPTION 'AT1B1_PROOF|tim@ should read IN-2026-0001''s trail with its pre-log history, got %', v_j;
    END IF;
    RAISE NOTICE 'AT1B1 IN-2026-0001 trail rows for tim@: % (pre-log: %, hidden: %)', jsonb_array_length(v_j),
        (SELECT count(*) FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean),
        (SELECT count(*) FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean);

    SELECT ur.user_id INTO v_wh FROM user_roles ur JOIN roles r ON r.id = ur.role_id
     WHERE r.code = 'warehouse' AND ur.revoked_at IS NULL ORDER BY ur.user_id LIMIT 1;
    SELECT id INTO v_id FROM fixed_assets ORDER BY code LIMIT 1;
    IF v_wh IS NOT NULL AND v_id IS NOT NULL THEN
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_wh, 'role', 'authenticated')::text, true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM record_trail('equipment', v_id::text, 20);
        PERFORM count(*) FROM warehouse_requests_masked;
        EXECUTE 'RESET ROLE';
        RAISE NOTICE 'AT1B1 the warehouse account reads equipment % trail: % rows', v_id, v_n;
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1B1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1b1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1b1_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

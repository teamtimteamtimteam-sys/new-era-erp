#!/usr/bin/env python3
"""AUDIT-TRAIL-1a:从镜像拼出迁移文件(形状照 build_terms_edit1_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数从 db/functions/ 原样抽出,两条索引从 db/tables/change_log.sql 原样抽出,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_at1a_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-29-at1a-record-trail.sql"
OUT_IDX = ROOT / "db/migrations/2026-09-29-at1a-record-trail-indexes.sql"

NEW_FUNCTIONS = [
    "change_log_began_at", "change_log_mask_row", "trail_pk_columns", "trail_fk_targets",
    "trail_subjects", "trail_subject_members", "trail_prelog_sources", "trail_current_image",
    "trail_row_visible", "trail_actor", "trail_ref_label", "trail_refs", "trail_row_record",
    "record_trail", "change_log_find_records",
]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


SIGNATURES = {
    "change_log_began_at": "()", "change_log_mask_row": "(text, jsonb, jsonb, jsonb)", "trail_pk_columns": "(text)",
    "trail_fk_targets": "(text)", "trail_subjects": "()", "trail_subject_members": "()", "trail_prelog_sources": "()",
    "trail_current_image": "(text, jsonb)", "trail_row_visible": "(text, jsonb, jsonb)", "trail_actor": "(text, uuid, uuid)",
    "trail_ref_label": "(text, text, text)", "trail_refs": "(text, jsonb, jsonb, jsonb)",
    "trail_row_record": "(text, jsonb, jsonb, jsonb)", "record_trail": "(text, text, integer)",
    "change_log_find_records": "(text)",
    "change_log_rows": "(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[])",
}


def grants_block():
    """与 zzz_function_grants.sql 同一个顺序,只作用在本刀新建 / 重建的函数上:先从 PUBLIC 与 anon 收回(默认授权给的是
    PUBLIC,authenticated 从它继承 —— 只收 authenticated 没有用),再授回 authenticated 与 service_role,最后把
    AUDIT-TRAIL-1a 那一段的内层函数从 authenticated 收回(原样抄自授权文件)。
    apply_migration.sh 会在迁移体【之后】再重放整份授权文件;文末的自证要在那之前就看得见收权,所以体内先做一次。"""
    out = []
    for name, sig in SIGNATURES.items():
        out.append(f"REVOKE EXECUTE ON FUNCTION public.{name}{sig} FROM PUBLIC, anon;")
        out.append(f"GRANT EXECUTE ON FUNCTION public.{name}{sig} TO authenticated, service_role;")
    g = (ROOT / "db/views/zzz_function_grants.sql").read_text()
    seg = g[g.index("-- AUDIT-TRAIL-1a(2026-09-29)"):]
    out += [l for l in seg.splitlines() if l.startswith("REVOKE ")]
    return "\n".join(out) + "\n"


def indexes():
    """两条索引,原样取自镜像,改写成 CREATE INDEX CONCURRENTLY IF NOT EXISTS(见第二个文件的抬头)。"""
    t = (ROOT / "db/tables/change_log.sql").read_text()
    lines = [l for l in t.splitlines() if l.startswith("CREATE INDEX idx_change_log_image")
             or l.startswith("CREATE INDEX idx_change_log_update_old")]
    assert len(lines) == 2, lines
    return "\n".join(l.replace("CREATE INDEX ", "CREATE INDEX CONCURRENTLY IF NOT EXISTS ", 1) for l in lines) + "\n"


HEADER = """-- db/migrations/2026-09-29-at1a-record-trail.sql
-- AUDIT-TRAIL-1a —— 每一页底部的审计记录:读法、登记表、逐行读规则、名字解析、"记录开始之前"的那一段(v1.4.33)。
-- 由 db/scripts/build_at1a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AUDIT-TRAIL-0 Q1–Q43,Tim 2026-09-29 全部照建议裁定)
--   ① 新:record_trail(主语, id, 条数) —— 一页一条记录的审计记录。页面只说主语,不说表名;拒绝一律 RAISE
--      (TRAIL_SUBJECT_UNKNOWN / TRAIL_NOT_PERMITTED),绝不返回空列表。
--   ② 新:登记表 trail_subjects / trail_subject_members / trail_prelog_sources(三个主语:采购单、加工单、角色);
--      逐行读规则 trail_row_visible;名字解析 trail_actor / trail_ref_label / trail_refs / trail_row_record;
--      目录助手 trail_pk_columns / trail_fk_targets / trail_current_image;分界 change_log_began_at。
--   ③ 新:change_log_mask_row —— 从 change_log_rows 的循环体抽出来的【唯一】遮蔽步骤,两个读法共用(Q5)。
--   ④ 替换:change_log_rows —— 同一道门(data.view_change_log),加了按事务分页、按区域 / 记录类型 / 单据号筛选,
--      每一行带回人名、所属单据与引用值的名字;遮蔽改走 ③。★ 签名多了四个带默认值的参数、返回多了四列,
--      所以先 DROP 旧签名再 CREATE(同一笔事务);旧页面用具名参数调它,破窗期间照常工作。
--   ⑤ 替换:change_log_filters —— 同一签名,返回的 jsonb 多了 people / has_system / has_removed 三个键。
--   ⑥ 新:change_log_find_records —— 汇总页按单据号或名字找记录(data.view_change_log)。
--   ⑦ change_log 上两条 GIN 部分索引(Q6)【不在本文件里】—— 在第二个文件 2026-09-29-at1a-record-trail-indexes.sql,
--      用 CREATE INDEX CONCURRENTLY 建,见那个文件的抬头。本文件因此不锁任何一张表。
--
-- 【不做什么】(Q42:只增不改)不重绑任何触发器、不改 change_log 的列、不改 17 张历史表、不写任何业务行、
--   不加新权限码、不碰审批开关与名册、不碰 user_roles / role_permissions。批次页的两张旧视图原样留着(Q32)。
--
-- 【破窗】什么都不坏:旧应用读的表、视图、函数签名都还在;change_log_rows 旧的具名参数照收,多出来的列旧页面不读。
--   本文件只建 / 换函数,不锁表 —— 业务写入在事务期间照常(DROP FUNCTION 只挡住同一时刻调 change_log_rows 的
--   汇总页,那一页等到提交)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;
--   change_log 的行数没变(本迁移一行业务数据都不写);每一张在途单据都还有一个【不是它自己当事人】的决定人;
--   新函数的形状对(DEFINER / 收权);并以 tim@(cfo)的身份真的读一次 PO-2026-0010 的审计记录。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = """SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'"""

TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"   # tim@evoltrya.test(cfo)—— memory 里量过的 auth.users id

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1A_PRE|approvals are expected ON';
    END IF;
    IF to_regproc('public.record_trail') IS NOT NULL THEN
        RAISE EXCEPTION 'AT1A_PRE|record_trail already exists';
    END IF;
    IF to_regprocedure('public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer)') IS NULL THEN
        RAISE EXCEPTION 'AT1A_PRE|change_log_rows has not the HISTORY-1 signature';
    END IF;
    IF (SELECT min(occurred_at) FROM change_log) IS DISTINCT FROM '2026-09-28 23:58:11.294246+08'::timestamptz THEN
        RAISE EXCEPTION 'AT1A_PRE|the change log began at % — change_log_began_at() would be wrong', (SELECT min(occurred_at) FROM change_log);
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
""")

parts.append("\n-- ── 1 · 新函数(镜像原样)────────────────────────────────────────────────────\n")
assert set(NEW_FUNCTIONS) | {"change_log_rows"} == set(SIGNATURES), "SIGNATURES 与 NEW_FUNCTIONS 不一致"
for n in NEW_FUNCTIONS:
    parts.append(fn(n))
parts.append("\n-- ── 2 · 替换:汇总页的两支读法(镜像原样)。change_log_rows 换签名 —— 先 DROP 旧的 ───────\n")
parts.append("\nDROP FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer);\n")
parts.append(fn("change_log_rows"))
parts.append(fn("change_log_filters"))
parts.append("\n-- ── 3 · 内层函数收权(与 db/views/zzz_function_grants.sql 同一段;apply_migration.sh 之后还会整份重放)──\n")
parts.append(grants_block())

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1a_pending_decider_check")
parts.append("\n-- ── 4 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1a_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    v_po   uuid;
    v_j    jsonb;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1a_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1a_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1A_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1A_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1a_pending_before b EXCEPT SELECT a.k, a.id FROM at1a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1a_pending_after a EXCEPT SELECT b.k, b.id FROM at1a_pending_before b)) THEN
        RAISE EXCEPTION 'AT1A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1a_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1A_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1a_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:两支读法是 DEFINER、authenticated 调得到;内层函数调不到(索引在第二个文件里,不在这里断言)
    FOREACH f IN ARRAY ARRAY['public.record_trail(text, text, integer)',
                             'public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[])',
                             'public.change_log_find_records(text)', 'public.change_log_filters()'] LOOP
        IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure) THEN
            RAISE EXCEPTION 'AT1A_PROOF|% must be SECURITY DEFINER', f;
        END IF;
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1A_PROOF|authenticated cannot execute %', f;
        END IF;
    END LOOP;
    FOREACH f IN ARRAY ARRAY['public.change_log_mask_row(text, jsonb, jsonb, jsonb)', 'public.trail_current_image(text, jsonb)',
                             'public.trail_ref_label(text, text, text)', 'public.trail_refs(text, jsonb, jsonb, jsonb)',
                             'public.trail_row_record(text, jsonb, jsonb, jsonb)', 'public.trail_row_visible(text, jsonb, jsonb)',
                             'public.trail_actor(text, uuid, uuid)'] LOOP
        IF has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1A_PROOF|authenticated can execute the inner function %', f;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
         WHERE p.proname = 'change_log_rows') <> 1 THEN
        RAISE EXCEPTION 'AT1A_PROOF|change_log_rows has more than one signature';
    END IF;

    -- ⑤ 真的读一次:以 tim@(cfo)的身份读 PO-2026-0010 —— 读得到、带着"记录开始之前"的那一段;不认识的主语按名拒
    SELECT id INTO v_po FROM purchase_orders WHERE code = 'PO-2026-0010';
    PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT jsonb_agg(to_jsonb(r)) INTO v_j FROM record_trail('purchase_order', v_po::text, 50) r;
    BEGIN
        PERFORM * FROM record_trail('purchase_orders', v_po::text);
        v_bad := 'no error';
    EXCEPTION WHEN OTHERS THEN
        v_bad := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF v_j IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean) THEN
        RAISE EXCEPTION 'AT1A_PROOF|tim@ should read PO-2026-0010''s trail with its pre-log history, got %', v_j;
    END IF;
    IF v_bad NOT LIKE 'TRAIL_SUBJECT_UNKNOWN|%' THEN
        RAISE EXCEPTION 'AT1A_PROOF|an unknown subject should raise TRAIL_SUBJECT_UNKNOWN, got %', v_bad;
    END IF;
    RAISE NOTICE 'AT1A PO-2026-0010 trail rows for tim@: % (pre-log rows: %)', jsonb_array_length(v_j),
        (SELECT count(*) FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1a_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

IDX = """-- db/migrations/2026-09-29-at1a-record-trail-indexes.sql
-- AUDIT-TRAIL-1a(Tim 的 Q6):change_log 上两条 GIN 部分索引 —— 每一页底部的审计记录在【读的时候】找一条记录的子行。
-- 由 db/scripts/build_at1a_migration.py 从镜像(db/tables/change_log.sql)拼出。
--
-- 【为什么它是第二个文件,而且【没有】BEGIN / COMMIT】
--   一句普通的 CREATE INDEX 在 change_log 上拿 SHARE 锁,一直拿到事务提交;而每一次业务写入都要往 change_log 插一行
--   (238 张表的触发器)。放进主迁移,锁会一直拿到 apply_migration.sh 重放完整份授权文件(133 句)再提交 ——
--   2026-09-29 演练实测每句往返 1.5–2 秒,授权那一段约 100 秒,整支 185 秒:业务写入要排队一分多钟,而 authenticated
--   的语句超时是 8 秒,排队的保存会直接报错。
--   CREATE INDEX CONCURRENTLY 不挡写入,但它【不能】在事务块里跑 —— 所以它不走 apply_migration.sh(那支脚本要求
--   BEGIN / COMMIT),而是在主迁移提交之后用 psql 直接跑本文件(自动提交,ON_ERROR_STOP)。
--   两句都是 IF NOT EXISTS,重跑无害。建好之前 record_trail 照样对,只是找子行时少一条索引。
--   跑法:psql "$DSN" -X -v ON_ERROR_STOP=1 -f db/migrations/2026-09-29-at1a-record-trail-indexes.sql
"""
OUT_IDX.write_text(IDX + "\n" + indexes())
print(f"wrote {OUT_IDX}")

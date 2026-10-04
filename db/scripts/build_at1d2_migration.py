#!/usr/bin/env python3
"""AUDIT-TRAIL-1d-2:从镜像拼出迁移文件(形状照 build_at1d2_migration.py)。镜像是真源,迁移是它的一次投影 ——
五支登记函数原样从 db/functions 抽出(同一签名,原地替换);document_types 两行的 link_mode 与镜像同改。
跑法:python3 db/scripts/build_at1d2_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-04-at1d2-trails-leave-and-time.sql"

REPLACED = ["trail_subjects", "trail_subject_members", "trail_prelog_sources", "trail_ref_label", "trail_row_record"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


HEADER = """-- db/migrations/2026-10-04-at1d2-trails-leave-and-time.sql
-- AUDIT-TRAIL-1d-2 —— 请假与考勤的审计记录(v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1d2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1d Step 0 的 Q1–Q38,Tim 2026-10-04 全部照建议裁定;这是 1d-2 那一刀)
--   ① trail_subjects:九个主语 —— leave_request · my_leave_request(M8)· leave_grant · leave_types(M11)· public_holidays(M11)·
--      medical_claim · my_medical_claim(M8)· overtime_batch(M1:hr.view · overtime_enter · overtime_approve)· attendance_period。
--   ② trail_subject_members:它们的成员;费用多一个成员 medical_claims(Q37,家仍在报销单)。
--   ③ trail_prelog_sources:Q12 的那几个戳(请假的决定 · 加班的冲销与丢弃 · 考勤的完成与重开 · 医疗报销的撤回)与几张表的建立。
--   ④ trail_ref_label:假期发放的名字;加班批的链接。trail_row_record:加班批那几行的 Record 一栏落在 /hr/overtime(Q36)。
--   ⑤ document_types:medical_claim 与 attendance_period 的 link_mode 改成 detail(Q36)。加班批【不】进 document_types(没有 code 列)。
--
-- 【不做什么】不改任何表结构、策略、表上的授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册;不建、不停、不删任何账号。
--
-- 【破窗】写的路一条都不坏:五支函数同签名原地替换,record_trail 不动;旧应用不叫九个新主语。提前看得见、而且是有意的:
--   费用页的旧应用读到报销单那几行(新成员),旧的造句器把它们说成通用的 "Medical claim …";汇总页上加班那几行的 Record 一栏
--   多了链接;全站搜索里医疗报销与考勤期间点进详情页(两页早就有)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;七十七个主语;并以 admin@ 把新主语在线上的每一条记录读一遍
--   (一条被拒 = 坏了)。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

ADMIN = "321f1819-8449-48f7-9ae0-78b2c4b50f35"   # admin@swm-os.test(admin —— 唯一持 action.manage_permissions)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(1d-1 的形状,六十八个主语)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1D2_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 68 THEN
        RAISE EXCEPTION 'AT1D2_PRE|expected the 68 subjects of 1d-1, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = 'public.record_trail(text, text, integer)'::regprocedure
                      AND 'op_key' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION 'AT1D2_PRE|record_trail does not return op_key';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1d2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1d2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1d2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
""")
parts.append("\n-- ── 1 · 登记表与读法的内层:原地替换(同一签名,镜像原样)──────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))
parts.append("""
-- ── 2 · document_types(Q36):医疗报销与考勤期间链到它们的详情页(两页早就在)──────────────────────────
UPDATE document_types SET link_mode = 'detail' WHERE key IN ('medical_claim', 'attendance_period') AND link_mode = 'list';
""")
a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1d2_pending_decider_check")
parts.append("\n-- ── 3 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1d2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    v_m    int;
    v_rows int;
    t      record;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1d2_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1d2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1D2_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1D2_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 只多 document_types 那两行(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1d2_pending_before b EXCEPT SELECT a.k, a.id FROM at1d2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1d2_pending_after a EXCEPT SELECT b.k, b.id FROM at1d2_pending_before b)) THEN
        RAISE EXCEPTION 'AT1D2_PROOF|a pending document changed state';
    END IF;
    -- 唯一的新行是 document_types 那两行改动(Q36:种子表也有变更记录)—— 恰好两行,别的一行都不许多
    IF (SELECT count(*) FROM change_log WHERE seq > (SELECT mx FROM at1d2_log_before)) <> 2
       OR EXISTS (SELECT 1 FROM change_log WHERE seq > (SELECT mx FROM at1d2_log_before) AND (table_name <> 'document_types' OR op <> 'UPDATE'))
       OR (SELECT n FROM at1d2_log_before) + 2 <> (SELECT count(*) FROM change_log) THEN
        RAISE EXCEPTION 'AT1D2_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1d2_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:七十七个主语;每一个 shown 成员表与根表都在 change_log 的覆盖里;执行权
    IF (SELECT count(*) FROM trail_subjects()) <> 77 THEN
        RAISE EXCEPTION 'AT1D2_PROOF|expected 77 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT x.t, ', ') INTO v_bad FROM (
        SELECT m.table_name AS t FROM trail_subject_members() m WHERE m.shown
        UNION SELECT s.root_table FROM trail_subjects() s) x
     -- M9:只在变更记录里出现的表没有触发器(它的事件由 record_account_event 写)
     WHERE x.t NOT IN (SELECT l.table_name FROM trail_log_only_tables() l)
       AND
           NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                        WHERE tr.event_object_table = x.t AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1D2_PROOF|member or root tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1D2_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1D2_PROOF|anon can execute %', f;
        END IF;
    END LOOP;
    -- 七个账号一个都没有被停(本刀不碰账号)
    IF (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now()) <> 0 THEN
        RAISE EXCEPTION 'AT1D2_PROOF|an account is disabled';
    END IF;

    -- ⑤ 真的读:以 admin@ 把新主语在线上的每一条记录读一遍(被拒 = 坏了);费用(Q37 多了成员)、员工、采购单各读几条,证登记表换过之后照旧。
    PERFORM set_config('request.jwt.claims', '{{"sub":"{ADMIN}","role":"authenticated"}}', true);
    v_n := 0;
    FOR t IN SELECT 'leave_request' AS s, id::text AS id FROM leave_requests
             UNION ALL SELECT 'leave_grant', id::text FROM leave_grants
             UNION ALL SELECT 'leave_types', 'all'
             UNION ALL SELECT 'public_holidays', 'all'
             UNION ALL SELECT 'medical_claim', id::text FROM medical_claims
             UNION ALL SELECT 'overtime_batch', id::text FROM overtime_batches
             UNION ALL SELECT 'attendance_period', id::text FROM attendance_periods
             UNION ALL (SELECT 'expense', id::text FROM expenses ORDER BY created_at LIMIT 3)
             UNION ALL (SELECT 'employee', id::text FROM employees ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'purchase_order', id::text FROM purchase_orders ORDER BY created_at LIMIT 1) LOOP
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1D2_PROOF|% % refused for admin@: %', t.s, t.id, SQLERRM;
        END;
        -- 每一条有它的建立(记录开始之前的那一行,或之后的 INSERT);假别与公共假期两本集合都有建立的时刻,不会是空的
        IF v_rows = 0 THEN
            RAISE EXCEPTION 'AT1D2_PROOF|% % has an empty trail for admin@', t.s, t.id;
        END IF;
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'AT1D2 read % records as admin@, none refused', v_n;
    -- M8:本人读得到自己的请假与医疗报销(/me 那两块),以本人的身份
    v_m := 0;
    FOR t IN SELECT 'my_leave_request' AS s, l.id::text AS id, e.user_id AS u FROM leave_requests l JOIN employees e ON e.id = l.employee_id WHERE e.user_id IS NOT NULL
             UNION ALL SELECT 'my_medical_claim', m.id::text, e.user_id FROM medical_claims m JOIN employees e ON e.id = m.employee_id WHERE e.user_id IS NOT NULL LOOP
        PERFORM set_config('request.jwt.claims', format('{{"sub":"%s","role":"authenticated"}}', t.u), true);
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1D2_PROOF|% % refused for its own employee: %', t.s, t.id, SQLERRM;
        END;
        v_m := v_m + 1;
    END LOOP;
    RAISE NOTICE 'AT1D2 read % own records as their employee, none refused', v_m;
    PERFORM set_config('request.jwt.claims', '', true);

    -- Q36:两行登记改成了详情页
    IF (SELECT count(*) FROM document_types WHERE key IN ('medical_claim', 'attendance_period') AND link_mode = 'detail') <> 2 THEN
        RAISE EXCEPTION 'AT1D2_PROOF|document_types not pointing at the detail pages';
    END IF;

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1d2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1D2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1d2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1D2_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1d2_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1d2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

#!/usr/bin/env python3
"""AUDIT-TRAIL-1d-3:从镜像拼出迁移文件(形状照 build_at1d3_migration.py)。镜像是真源,迁移是它的一次投影 ——
五支登记函数原样从 db/functions 抽出(同一签名,原地替换);一支新函数 my_period_labels(Q19)原样从镜像抽出。
跑法:python3 db/scripts/build_at1d3_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-05-at1d3-trails-pay-and-performance.sql"

REPLACED = ["trail_subjects", "trail_subject_members", "trail_prelog_sources", "trail_ref_label", "trail_row_record"]
NEW = ["my_period_labels"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


HEADER = """-- db/migrations/2026-10-05-at1d3-trails-pay-and-performance.sql
-- AUDIT-TRAIL-1d-3 —— 工资与评审的审计记录 + Q19 的修复(v1.4.33 的最后一部分;发布那一行在交回报告里)。
-- 由 db/scripts/build_at1d3_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1d Step 0 的 Q1–Q38,Tim 2026-10-04 全部照建议裁定;这是 1d-3 那一刀)
--   ① trail_subjects:六个主语 —— payroll_period · performance_review · my_review(M8 + M12:只给审核人,Q5)·
--      review_cycle(清单块,Q6)· review_rating_scale(M11)· kpi_entry(清单块)。
--   ② trail_subject_members:工资期的工资行 · 申请与审批 · 这一期的分录(按 source_id,不按会被撤销置空的 journal_entry_id)与它们的冲销;
--      评审的目标与审批(HR 那一页与审核人那一页)。
--   ③ trail_prelog_sources:Q12 的戳 —— 工资申请的撤回 · 评审的作废;本刀自己多登记的 KPI 打分;几张表的建立。
--   ④ trail_ref_label:评审的名字与链接 · 工资申请的名字(不带原样的种类,Q10)· KPI 条目的名字;trail_row_record:评审的链接。
--   ⑤ 新函数 my_period_labels()(Tim 的折入:修 Q19):调用者自己的考勤行与工资单所在的期间 —— 只给编号与月份。
--
-- 【不做什么】不改任何表结构、策略、表上的授权、触发器、种子行;不写任何业务行;不加新权限码;不碰审批开关与名册;
--   不建、不停、不删任何账号。
--
-- 【破窗】写的路一条都不坏:五支函数同签名原地替换,record_trail 不动,新函数是新加的;旧应用不叫六个新主语,也不叫新函数。
--   提前看得见、而且是有意的:汇总页上工资申请与评审那几行的 Record 一栏换成新的名字(工资申请不再带 "· post #1")、评审行多了链接;
--   旧的 /me 仍按旧的读法读期间(不持 hr.view 的人照旧是 "—",直到部署)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   一行没动;每一张在途单据都还有一个【不是它自己当事人】的决定人;八十三个主语;并以 admin@ 把新主语在线上的每一条记录读一遍
--   (一条被拒 = 坏了),以每一个绑着员工档案的账号调一次 my_period_labels()(被拒 = 坏了)。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

ADMIN = "321f1819-8449-48f7-9ae0-78b2c4b50f35"   # admin@swm-os.test(admin —— 唯一持 action.manage_permissions)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(1d-2 的形状,七十七个主语)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1D3_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 77 THEN
        RAISE EXCEPTION 'AT1D3_PRE|expected the 77 subjects of 1d-2, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF to_regprocedure('public.my_period_labels()') IS NOT NULL THEN
        RAISE EXCEPTION 'AT1D3_PRE|my_period_labels() already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = 'public.record_trail(text, text, integer)'::regprocedure
                      AND 'op_key' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION 'AT1D3_PRE|record_trail does not return op_key';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1d3_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1d3_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1d3_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
""")
parts.append("\n-- ── 1 · 登记表与读法的内层:原地替换(同一签名,镜像原样)──────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))
parts.append("\n-- ── 2 · Q19:本人读得到自己期间的编号与月份(新函数;镜像原样)───────────────────────────────────────\n")
for name in NEW:
    parts.append(fn(name))
parts.append("""
-- 授权写在这里,自证才问得了它(apply_migration.sh 随后还会回放 zzz_function_grants —— 同一个结果,幂等)
REVOKE EXECUTE ON FUNCTION public.my_period_labels() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_period_labels() TO authenticated, service_role;
""")
a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1d3_pending_decider_check")
parts.append("\n-- ── 3 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1d3_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM at1d3_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1d3_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1D3_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1D3_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 只多 document_types 那两行(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1d3_pending_before b EXCEPT SELECT a.k, a.id FROM at1d3_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1d3_pending_after a EXCEPT SELECT b.k, b.id FROM at1d3_pending_before b)) THEN
        RAISE EXCEPTION 'AT1D3_PROOF|a pending document changed state';
    END IF;
    -- 本刀一行数据都不写(没有种子行要改)—— change_log 一行都不许多
    IF (SELECT count(*) FROM change_log WHERE seq > (SELECT mx FROM at1d3_log_before)) <> 0
       OR (SELECT n FROM at1d3_log_before) <> (SELECT count(*) FROM change_log) THEN
        RAISE EXCEPTION 'AT1D3_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1d3_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:八十三个主语;每一个 shown 成员表与根表都在 change_log 的覆盖里;执行权
    IF (SELECT count(*) FROM trail_subjects()) <> 83 THEN
        RAISE EXCEPTION 'AT1D3_PROOF|expected 83 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT x.t, ', ') INTO v_bad FROM (
        SELECT m.table_name AS t FROM trail_subject_members() m WHERE m.shown
        UNION SELECT s.root_table FROM trail_subjects() s) x
     -- M9:只在变更记录里出现的表没有触发器(它的事件由 record_account_event 写)
     WHERE x.t NOT IN (SELECT l.table_name FROM trail_log_only_tables() l)
       AND
           NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                        WHERE tr.event_object_table = x.t AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1D3_PROOF|member or root tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)', 'public.my_period_labels()'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1D3_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1D3_PROOF|anon can execute %', f;
        END IF;
    END LOOP;
    -- 七个账号一个都没有被停(本刀不碰账号)
    IF (SELECT count(*) FROM auth.users WHERE banned_until IS NOT NULL AND banned_until > now()) <> 0 THEN
        RAISE EXCEPTION 'AT1D3_PROOF|an account is disabled';
    END IF;

    -- ⑤ 真的读:以 admin@ 把新主语在线上的每一条记录读一遍(被拒 = 坏了);1d-2 的请假、员工、采购单各读一条,证登记表换过之后照旧。
    PERFORM set_config('request.jwt.claims', '{{"sub":"{ADMIN}","role":"authenticated"}}', true);
    v_n := 0;
    FOR t IN SELECT 'payroll_period' AS s, id::text AS id FROM payroll_periods
             UNION ALL SELECT 'performance_review', id::text FROM performance_reviews
             UNION ALL SELECT 'review_cycle', id::text FROM review_cycles
             UNION ALL SELECT 'review_rating_scale', 'all'
             UNION ALL SELECT 'kpi_entry', id::text FROM kpi_entries
             UNION ALL (SELECT 'leave_request', id::text FROM leave_requests ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'employee', id::text FROM employees ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'purchase_order', id::text FROM purchase_orders ORDER BY created_at LIMIT 1) LOOP
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1D3_PROOF|% % refused for admin@: %', t.s, t.id, SQLERRM;
        END;
        -- 每一条有它的建立(记录开始之前的那一行,或之后的 INSERT);评分刻度那一本集合有建立的时刻,不会是空的
        IF v_rows = 0 THEN
            RAISE EXCEPTION 'AT1D3_PROOF|% % has an empty trail for admin@', t.s, t.id;
        END IF;
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'AT1D3 read % records as admin@, none refused', v_n;
    -- M12:审核人读得到他那一份(/my-reviews),以审核人的身份
    v_m := 0;
    FOR t IN SELECT 'my_review' AS s, r.id::text AS id, e.user_id AS u FROM performance_reviews r JOIN employees e ON e.id = r.reviewer_employee_id
              WHERE e.user_id IS NOT NULL LOOP
        PERFORM set_config('request.jwt.claims', format('{{"sub":"%s","role":"authenticated"}}', t.u), true);
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1D3_PROOF|% % refused for its reviewer: %', t.s, t.id, SQLERRM;
        END;
        v_m := v_m + 1;
    END LOOP;
    RAISE NOTICE 'AT1D3 read % review(s) as their reviewer, none refused', v_m;
    -- Q19:每一个绑着员工档案的账号都调得了 my_period_labels(),只拿到他自己的期间
    v_m := 0;
    FOR t IN SELECT e.user_id AS u, e.id AS emp FROM employees e WHERE e.user_id IS NOT NULL AND e.deleted_at IS NULL LOOP
        PERFORM set_config('request.jwt.claims', format('{{"sub":"%s","role":"authenticated"}}', t.u), true);
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM my_period_labels() x
             WHERE NOT EXISTS (SELECT 1 FROM attendance_lines al WHERE al.period_id = x.period_id AND al.employee_id = t.emp)
               AND NOT EXISTS (SELECT 1 FROM payroll_lines pl WHERE pl.payroll_period_id = x.period_id AND pl.employee_id = t.emp);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1D3_PROOF|my_period_labels() refused for %: %', t.u, SQLERRM;
        END;
        IF v_rows <> 0 THEN RAISE EXCEPTION 'AT1D3_PROOF|my_period_labels() returned % period(s) without a line of %', v_rows, t.u; END IF;
        v_m := v_m + 1;
    END LOOP;
    RAISE NOTICE 'AT1D3 my_period_labels() called as % linked account(s), only their own periods', v_m;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1d3_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1D3 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1d3_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1D3_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1d3_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1d3_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

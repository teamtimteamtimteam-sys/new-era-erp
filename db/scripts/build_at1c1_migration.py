#!/usr/bin/env python3
"""AUDIT-TRAIL-1c-1:从镜像拼出迁移文件(形状照 build_at1b3_migration.py)。镜像是真源,迁移是它的一次投影 ——
六支登记 / 读法函数原样从 db/ 抽出(同一签名,原地替换),record_trail 多一列返回值所以 DROP + CREATE。
跑法:python3 db/scripts/build_at1c1_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-03-at1c1-trails-ledger-documents.sql"

REPLACED = ["trail_subjects", "trail_subject_members", "trail_prelog_sources", "trail_ref_label", "trail_refs", "trail_row_record"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


HEADER = """-- db/migrations/2026-10-03-at1c1-trails-ledger-documents.sql
-- AUDIT-TRAIL-1c-1 —— 账上单据的审计记录:分录 · 发票 · 贷项通知 · 收付款 · 付款申请 · 费用 · 应付;
--   机制:M7(没有外键的表整张属于一个单行设置主语)· Q16(每一行带回它属于哪一次操作)· Q12(引用里的员工名照 ActorName)
--   (v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1c1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1c Step 0 §a 的登记表与 Q1 · Q3 · Q5 · Q9 · Q12 · Q13 · Q16 · Q33,Tim 2026-10-03 照建议裁定)
--   ① trail_subjects:加七个主语 —— journal_entry · invoice · credit_note · payment · payment_request · expense · payable
--      (payable:根表 inbound_batches,M3 页面的码是门,M6 只取应付那几列)。
--   ② trail_subject_members:它们的子行与相关行(冲销走原分录的 reversed_by,Q33;付款申请的六种结果)。
--   ③ trail_prelog_sources:"记录开始之前"的来源;Q9:发票的作废戳、付款申请的付讫戳、报销单的决定戳登记成事件。
--   ④ record_trail:M7('all' 成员)+ 返回 op_key(Q16)—— 多一列返回值,CREATE OR REPLACE 换不了 → DROP + CREATE。
--   ⑤ trail_row_record:M7 成员的"家"是那一行设置(/settings/change-history 的 Record 一栏)。
--   ⑥ trail_ref_label:员工 → trail_actor(Q12:不持 module.hr.view 的读者只认得出他自己);单据多带 href(Q33);
--      发票明细行有名字("INV-… line N")。
--   ⑦ trail_refs:付款申请的 allocations(JSONB)里的单据 id 解析成单号(Q13)。
--
-- 【不做什么】不改任何表、策略、表上的授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册。
--
-- 【破窗】什么都不坏:
--   · 旧应用调 record_trail 的参数不变;多出来的 op_key 一列它不读(它按列名取)。DROP + CREATE 在同一笔事务里,
--     提交之前旧的那一支一直在;提交之后 PostgREST 的 schema 缓存重载之前的那几秒,对 record_trail 的调用可能报
--     "找不到函数"(本迁移末尾 NOTIFY pgrst 重载)。
--   · 新主语对旧应用不存在(它不叫它们);旧的分录 / 发票 / 收付款 / 费用 / 应付页照旧,没有审计记录那一段。
--   · 提前到来、而且是本意的:引用里的员工名对不持 module.hr.view 的读者变成 Restricted(Q12)—— 线上持
--     finance.view 的每一个角色都持 hr.view,读得到的人里只有仓库那一个账号受影响,而它只读 1b 的那几页;
--     /settings/change-history 的 Record 一栏,发票明细行、分录的行、收付款的核销行归到它们的单据。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;三十六个主语;record_trail authenticated 能执行、anon 不能;
--   并以 tim@(cfo)把七个新主语在线上的【每一条】记录读一遍(一条被拒 = 坏了)。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"   # tim@evoltrya.test(cfo)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(1b-3 的形状,二十九个主语;record_trail 还没有 op_key)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1C1_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 29 THEN
        RAISE EXCEPTION 'AT1C1_PRE|expected the 29 subjects of 1b-3, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = 'public.record_trail(text, text, integer)'::regprocedure
                  AND 'op_key' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION 'AT1C1_PRE|record_trail already returns op_key';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1c1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1c1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1c1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
""")
parts.append("\n-- ── 1 · 登记表与读法的内层:原地替换(同一签名,镜像原样)──────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))
parts.append("""
-- ── 2 · record_trail:多一列返回值(op_key,Q16)—— DROP + CREATE(同一笔事务)──────────────────────────────
DROP FUNCTION public.record_trail(text, text, integer);
""")
parts.append(fn("record_trail"))
# apply_migration.sh 在本事务末尾才回放 zzz_function_grants —— 自证 ④ 要断言的正是那个终态,所以在这里先做一遍
parts.append("""
REVOKE EXECUTE ON FUNCTION public.record_trail(text, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_trail(text, text, integer) TO authenticated, service_role;
""")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1c1_pending_decider_check")
parts.append("\n-- ── 3 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1c1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    v_rows int;
    t      record;
    k      text;
    f      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM at1c1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1c1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1C1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1C1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1c1_pending_before b EXCEPT SELECT a.k, a.id FROM at1c1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1c1_pending_after a EXCEPT SELECT b.k, b.id FROM at1c1_pending_before b)) THEN
        RAISE EXCEPTION 'AT1C1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1c1_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1C1_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1c1_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:三十六个主语;每一个 shown 成员表与根表都在 change_log 的覆盖里;执行权
    IF (SELECT count(*) FROM trail_subjects()) <> 36 THEN
        RAISE EXCEPTION 'AT1C1_PROOF|expected 36 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT m.table_name, ', ') INTO v_bad FROM trail_subject_members() m
     WHERE m.shown AND NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                                    WHERE tr.event_object_table = m.table_name AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1C1_PROOF|member tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1C1_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1C1_PROOF|anon can execute %', f;
        END IF;
    END LOOP;

    -- ⑤ 真的读:以 tim@ 把七个新主语在线上的每一条记录读一遍(被拒 = 坏了);1b 的主语各读一条,证 DROP + CREATE 之后照旧
    PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    FOR t IN SELECT 'journal_entry' AS s, id::text AS id FROM journal_entries
             UNION ALL SELECT 'invoice', id::text FROM invoices
             UNION ALL SELECT 'credit_note', id::text FROM credit_notes
             UNION ALL SELECT 'payment', id::text FROM payments
             UNION ALL SELECT 'payment_request', id::text FROM payment_requests
             UNION ALL SELECT 'expense', id::text FROM expenses
             UNION ALL SELECT 'payable', id::text FROM inbound_batches
             UNION ALL (SELECT 'purchase_order', id::text FROM purchase_orders ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'inbound_batch', id::text FROM inbound_batches ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'task', id::text FROM tasks WHERE task_type = 'team' ORDER BY created_at LIMIT 1) LOOP
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1C1_PROOF|% % refused for tim@: %', t.s, t.id, SQLERRM;
        END;
        IF v_rows = 0 THEN RAISE EXCEPTION 'AT1C1_PROOF|% % has an empty trail for tim@ (every live record has at least its creation)', t.s, t.id; END IF;
        v_n := COALESCE(v_n, 0) + 1;
    END LOOP;
    RAISE NOTICE 'AT1C1 read % records as tim@, none refused, none empty', v_n;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1c1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1C1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1c1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1C1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1c1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1c1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

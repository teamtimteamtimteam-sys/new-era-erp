#!/usr/bin/env python3
"""AUDIT-TRAIL-1c-3:从镜像拼出迁移文件(形状照 build_at1c3_migration.py)。镜像是真源,迁移是它的一次投影 ——
五支登记 / 读法函数原样从 db/functions 抽出(同一签名,原地替换)。
跑法:python3 db/scripts/build_at1c3_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-04-at1c3-trails-period-end-settings-and-lists.sql"

REPLACED = ["trail_subjects", "trail_subject_members", "trail_prelog_sources", "trail_ref_label", "record_trail"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


HEADER = """-- db/migrations/2026-10-04-at1c3-trails-period-end-settings-and-lists.sql
-- AUDIT-TRAIL-1c-3 —— 期末、设置与清单页上的审计记录(v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1c3_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1c Step 0 §a 的登记表与 Q3 · Q4 · Q16 · Q17 · Q18 · Q19 · Q20 · Q25 · Q29 · Q30,Tim 2026-10-03 照建议裁定)
--   ① trail_subjects:加十二个主语 —— finance_lock · finance_gst(同一行设置,M5 · M6:各看各的列)· company_profile · year_close ·
--      journal_request · expense_claim · my_expense_claim(M8:没有页面码,根行的读规则是门 —— /me 上的报销人)· bank_transfer ·
--      wht_remittance · cash_forecast · cash_forecast_line · bank_import_profile。
--   ② trail_subject_members:它们的成员;锁期经 M7 整张 period_closes;分录多一张 fixed_asset_depreciation(折旧批次);
--      人工分录申请与它的审批的家改成申请自己(它是根了 —— 一张还没批的申请没有分录)。
--   ③ trail_prelog_sources:月结 / 年结 / 现金预测 / 常设行 / 导入模板"记录开始之前"的来源。
--   ④ trail_ref_label:财务设置 / 公司资料 / 月结 / 年结 / 行内转账的名字。
--   ⑤ record_trail:M8 —— view_codes 为空数组时根行的读规则是唯一的门(只许配 'table')。同一签名,原地替换。
--
-- 【不做什么】不改任何表、策略、表上的授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册。
--
-- 【破窗】什么都不坏:
--   · 五支函数同签名原地替换 —— 不锁表;record_trail 的返回列不变。
--   · 新主语对旧应用不存在(它不叫它们);旧的那几页照旧,没有审计记录那一段。
--   · 提前到来、而且是本意的:/settings/change-history 的 Record 一栏,人工分录申请与它的审批那几行从过账的分录改归到申请自己
--     (它的名字,如 "manual journal #3",没有链接 —— 它没有自己的页);行内转账那几行从它的分录改归到转账自己
--     ("Transfer DD/MM/YYYY · … → …");月结 / 年结 / 财务设置 / 公司资料的那几行有了名字。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;五十六个主语;执行权;并以 tim@(cfo)把十二个新主语在线上的
--   【每一条】记录读一遍(一条被拒 = 坏了)。M8 不对没有码的 'page' 主语敞开,由 fixture 243 证(它能改登记表,迁移不该)。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"   # tim@evoltrya.test(cfo)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(1c-2 的形状,四十四个主语;record_trail 已经有 op_key)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1C3_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 44 THEN
        RAISE EXCEPTION 'AT1C3_PRE|expected the 44 subjects of 1c-2, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = 'public.record_trail(text, text, integer)'::regprocedure
                      AND 'op_key' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION 'AT1C3_PRE|record_trail does not return op_key';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1c3_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1c3_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1c3_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
""")
parts.append("\n-- ── 1 · 登记表与读法的内层:原地替换(同一签名,镜像原样)──────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))
a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1c3_pending_decider_check")
parts.append("\n-- ── 3 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1c3_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM at1c3_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1c3_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1C3_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1C3_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1c3_pending_before b EXCEPT SELECT a.k, a.id FROM at1c3_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1c3_pending_after a EXCEPT SELECT b.k, b.id FROM at1c3_pending_before b)) THEN
        RAISE EXCEPTION 'AT1C3_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1c3_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1C3_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1c3_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:五十六个主语;每一个 shown 成员表与根表都在 change_log 的覆盖里;执行权
    IF (SELECT count(*) FROM trail_subjects()) <> 56 THEN
        RAISE EXCEPTION 'AT1C3_PROOF|expected 56 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT x.t, ', ') INTO v_bad FROM (
        SELECT m.table_name AS t FROM trail_subject_members() m WHERE m.shown
        UNION SELECT s.root_table FROM trail_subjects() s) x
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                        WHERE tr.event_object_table = x.t AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1C3_PROOF|member or root tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1C3_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1C3_PROOF|anon can execute %', f;
        END IF;
    END LOOP;

    -- ⑤ 真的读:以 tim@ 把十二个新主语在线上的每一条记录读一遍(被拒 = 坏了);1b / 1c 的主语各读一条,证登记表换过之后照旧。
    --   GST 面板与公司资料可以是空的:那两块在记录开始之前一条记录都没有(Step 0 §c),而线上至今没有人改过它们
    PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    v_n := 0;
    FOR t IN SELECT 'finance_lock' AS s, 'true' AS id
             UNION ALL SELECT 'finance_gst', 'true'
             UNION ALL SELECT 'company_profile', 'true'
             UNION ALL SELECT 'year_close', id::text FROM year_closes
             UNION ALL SELECT 'journal_request', id::text FROM journal_requests
             UNION ALL SELECT 'expense_claim', id::text FROM expense_claims
             UNION ALL SELECT 'my_expense_claim', id::text FROM expense_claims
             UNION ALL SELECT 'bank_transfer', id::text FROM bank_transfers
             UNION ALL SELECT 'wht_remittance', id::text FROM wht_remittances
             UNION ALL SELECT 'cash_forecast', id::text FROM cash_forecasts
             UNION ALL SELECT 'cash_forecast_line', id::text FROM cash_forecast_lines
             UNION ALL SELECT 'bank_import_profile', id::text FROM bank_import_profiles
             UNION ALL (SELECT 'journal_entry', id::text FROM journal_entries WHERE source_type = 'revaluation' ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'fx_rate', id::text FROM fx_rates ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'output_batch', id::text FROM output_batches ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'payment', id::text FROM payments ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'purchase_order', id::text FROM purchase_orders ORDER BY created_at LIMIT 1) LOOP
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1C3_PROOF|% % refused for tim@: %', t.s, t.id, SQLERRM;
        END;
        IF v_rows = 0 AND t.s NOT IN ('finance_gst', 'company_profile') THEN
            RAISE EXCEPTION 'AT1C3_PROOF|% % has an empty trail for tim@ (every live record has at least its creation)', t.s, t.id;
        END IF;
        RAISE NOTICE 'AT1C3 read % % → % rows', t.s, t.id, v_rows;
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'AT1C3 read % records as tim@, none refused', v_n;
    -- 锁期面板读到了记录开始之前那一次关账(M7 + period_closes 的 created 来源):一行都没有就是 M7 没有展开
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_m FROM record_trail('finance_lock', 'true', 500) r WHERE r.table_name = 'period_closes';
    EXECUTE 'RESET ROLE';
    IF v_m < (SELECT count(*) FROM period_closes) THEN
        RAISE EXCEPTION 'AT1C3_PROOF|the lock trail reads % period-close rows, the table holds %', v_m, (SELECT count(*) FROM period_closes);
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1c3_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1C3 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1c3_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1C3_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1c3_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1c3_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

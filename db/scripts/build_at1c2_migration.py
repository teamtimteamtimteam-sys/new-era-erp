#!/usr/bin/env python3
"""AUDIT-TRAIL-1c-2:从镜像拼出迁移文件(形状照 build_at1c1_migration.py)。镜像是真源,迁移是它的一次投影 ——
六支登记 / 读法函数原样从 db/functions 抽出(同一签名,原地替换),deleted_records 原样从 db/views 抽出(列不变,原地替换)。
跑法:python3 db/scripts/build_at1c2_migration.py(在仓库根目录)。

★ 不要再跑它(2026-10-04 应用之后):仓库里那一份迁移文件就是线上【应用过的那一份】,而它是在 db/functions/trail_ref_label.sql
  加上"分录行的名字"那一支【之前】拼的 —— 那一支由 db/migrations/2026-10-04-at1c2-fu1-trail-ref-label-journal-lines.sql 补上。
  现在重拼会得到一份与应用过的不一样的文件,而迁移目录记的应当是发生过的事。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-04-at1c2-trails-documents-and-contracts.sql"

REPLACED = ["trail_subjects", "trail_subject_members", "trail_prelog_sources", "trail_ref_label", "trail_refs", "trail_row_record"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


HEADER = """-- db/migrations/2026-10-04-at1c2-trails-documents-and-contracts.sql
-- AUDIT-TRAIL-1c-2 —— 其余单据与合同的审计记录:销售 · 运费单 · 资产(财务那一页)· 对账单 · GST 期间 · 汇率 · 管理包 · 合同
--   (v1.4.33 的一部分,未发布)。
-- 由 db/scripts/build_at1c2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(AT-1c Step 0 §a 的登记表与 Q1 · Q6 · Q7 · Q9 · Q10 · Q14 · Q21 · Q22 · Q23 · Q25,Tim 2026-10-03 照建议裁定)
--   ① trail_subjects:加八个主语 —— sale · freight · fixed_asset · bank_statement · gst_period · fx_rate · management_pack · contract。
--   ② trail_subject_members:它们的子行与相关行;产出批次 ord 12(销售)的 home 改成 false —— 销售自己是根了(Q14)。
--   ③ trail_prelog_sources:"记录开始之前"的来源;Q9 余下的两个戳(运费单的冲销、对账单的对账)登记成事件。
--   ④ trail_ref_label:销售 / 汇率 / 对账单行 / 申报格 / 对账记录 / 折旧的名字;销售带 href(应收页,Q14)。
--   ⑤ trail_refs:资产修改史里成对的 old_ / new_ 列按资产卡那一列的外键解析(Q10)。
--   ⑥ trail_row_record:销售那一行的家是这一笔销售,链接落在应收页(Q14 —— 销售没有 code 列,不进 document_types:
--      全站搜索会对登记的每一张表拼一句 SELECT code,当场报错)。
--   ⑦ deleted_records:多一类 —— 对账单(Q6;"谁删的"取自变更记录,读不到就只说日期)。
--
-- 【不做什么】不改任何表、策略、表上的授权、触发器;不写任何业务行;不加新权限码;不碰审批开关与名册;
--   不碰 record_trail(本刀不需要它多做什么)。
--
-- 【破窗】什么都不坏:
--   · 六支函数同签名原地替换,视图列不变原地替换 —— 不锁表(视图替换那一刻锁着 deleted_records 本身)。
--   · 新主语对旧应用不存在(它不叫它们);旧的八页照旧,没有审计记录那一段。
--   · 提前到来、而且是本意的:/settings/change-history 的 Record 一栏,销售那几行从产出批次改归到这一笔销售("OUT-… sale DD/MM/YYYY",
--     链到应收页);运费分摊、资产成本那几行归到运费单 / 资产;旧的 /settings/deleted 会把删掉的对账单列出来,种类名一栏是原样的键名
--     (deleted.kind.bank_statement)、没有链接 —— 旧页面两样都没有(1b-3 的同一个形状)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;change_log 的行数
--   没变;每一张在途单据都还有一个【不是它自己当事人】的决定人;四十四个主语;执行权;被删记录原来那几类一行不少、对账单那一类
--   与基表逐行相等;并以 tim@(cfo)把八个新主语在线上的【每一条】记录读一遍(一条被拒 = 坏了)。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"   # tim@evoltrya.test(cfo)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(1c-1 的形状,三十六个主语;record_trail 已经有 op_key)──────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1C2_PRE|approvals are expected ON';
    END IF;
    IF (SELECT count(*) FROM trail_subjects()) <> 36 THEN
        RAISE EXCEPTION 'AT1C2_PRE|expected the 36 subjects of 1c-1, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid = 'public.record_trail(text, text, integer)'::regprocedure
                      AND 'op_key' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION 'AT1C2_PRE|record_trail does not return op_key — 1c-1 is not on live';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE at1c2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE at1c2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE at1c2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
-- deleted_records 按【调用者】的模块码过滤(has_permission 读 JWT);迁移的属主身份没有 JWT,读到的会是 0 行 ——
--   一次权限拒绝长得和一次测量一模一样(AGENTS.md「一个 0 行的读数,先问它是谁读的」)。所以以 tim@(cfo,持每一个 view 码)读
SELECT set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
CREATE TEMP TABLE at1c2_deleted_before ON COMMIT DROP AS
SELECT record_kind, record_id FROM deleted_records;
SELECT set_config('request.jwt.claims', '', true);
""")
parts.append("\n-- ── 1 · 登记表与读法的内层:原地替换(同一签名,镜像原样)──────────────────────────────\n")
for name in REPLACED:
    parts.append(fn(name))
parts.append("\n-- ── 2 · 被删的记录:多一类对账单(Q6)—— 列不变,原地替换 ──────────────────────────────\n")
parts.append("\n" + (ROOT / "db/views/deleted_records.sql").read_text().rstrip("\n") + "\n")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "at1c2_pending_decider_check")
parts.append("\n-- ── 3 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE at1c2_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM at1c2_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM at1c2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1C2_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'AT1C2_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;change_log 一行没多(本迁移不写业务数据)
    IF EXISTS ((SELECT b.k, b.id FROM at1c2_pending_before b EXCEPT SELECT a.k, a.id FROM at1c2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM at1c2_pending_after a EXCEPT SELECT b.k, b.id FROM at1c2_pending_before b)) THEN
        RAISE EXCEPTION 'AT1C2_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(n, mx)::text FROM at1c2_log_before) IS DISTINCT FROM (SELECT row(count(*), max(seq))::text FROM change_log) THEN
        RAISE EXCEPTION 'AT1C2_PROOF|change_log moved: % → %', (SELECT row(n, mx)::text FROM at1c2_log_before),
            (SELECT row(count(*), max(seq))::text FROM change_log);
    END IF;

    -- ④ 形状:四十四个主语;每一个 shown 成员表与根表都在 change_log 的覆盖里;执行权
    IF (SELECT count(*) FROM trail_subjects()) <> 44 THEN
        RAISE EXCEPTION 'AT1C2_PROOF|expected 44 subjects, got %', (SELECT count(*) FROM trail_subjects());
    END IF;
    SELECT string_agg(DISTINCT x.t, ', ') INTO v_bad FROM (
        SELECT m.table_name AS t FROM trail_subject_members() m WHERE m.shown
        UNION SELECT s.root_table FROM trail_subjects() s) x
     WHERE NOT EXISTS (SELECT 1 FROM information_schema.triggers tr
                        WHERE tr.event_object_table = x.t AND tr.trigger_name = 'zzz_change_log');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'AT1C2_PROOF|member or root tables without the change-log trigger: %', v_bad; END IF;
    FOREACH f IN ARRAY ARRAY['public.trail_subjects()', 'public.trail_subject_members()', 'public.trail_prelog_sources()',
                             'public.record_trail(text, text, integer)'] LOOP
        IF NOT has_function_privilege('authenticated', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1C2_PROOF|authenticated cannot execute %', f;
        END IF;
        IF has_function_privilege('anon', f::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'AT1C2_PROOF|anon can execute %', f;
        END IF;
    END LOOP;

    -- ⑤ 被删记录(以 tim@ 读 —— 见文首那一句):原来那几类一行不少;对账单那一类与基表里删掉的行数相等
    PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    IF (SELECT count(*) FROM at1c2_deleted_before) = 0 THEN
        RAISE EXCEPTION 'AT1C2_PROOF|the before-reading of deleted_records is empty — a refused read, not a measurement';
    END IF;
    IF EXISTS (SELECT record_kind, record_id FROM at1c2_deleted_before EXCEPT SELECT record_kind, record_id FROM deleted_records) THEN
        RAISE EXCEPTION 'AT1C2_PROOF|a deleted record that was listed before is no longer listed';
    END IF;
    SELECT count(*) INTO v_n FROM bank_statements WHERE deleted_at IS NOT NULL;
    SELECT count(*) INTO v_m FROM deleted_records WHERE record_kind = 'bank_statement';
    RAISE NOTICE 'AT1C2 deleted bank_statement: % in the table, % listed for tim@ (% with a person)', v_n, v_m,
        (SELECT count(*) FROM deleted_records WHERE record_kind = 'bank_statement' AND deleted_by IS NOT NULL);
    IF v_n <> v_m THEN RAISE EXCEPTION 'AT1C2_PROOF|deleted bank statements: % in the table but % listed', v_n, v_m; END IF;

    -- ⑥ 真的读:以 tim@ 把八个新主语在线上的每一条记录读一遍(被拒 = 坏了;删掉的对账单、撤回的汇率也读 —— 读规则不过滤它们);
    --    1b / 1c-1 的主语各读一条,证登记表换过之后照旧
    v_n := 0;
    FOR t IN SELECT 'sale' AS s, id::text AS id FROM sales_records
             UNION ALL SELECT 'freight', id::text FROM freight_documents
             UNION ALL SELECT 'fixed_asset', id::text FROM fixed_assets
             UNION ALL SELECT 'bank_statement', id::text FROM bank_statements
             UNION ALL SELECT 'gst_period', id::text FROM gst_periods
             UNION ALL SELECT 'fx_rate', id::text FROM fx_rates
             UNION ALL SELECT 'management_pack', id::text FROM management_packs
             UNION ALL SELECT 'contract', id::text FROM contracts
             UNION ALL (SELECT 'output_batch', id::text FROM output_batches ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'equipment', id::text FROM fixed_assets ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'payment', id::text FROM payments ORDER BY created_at LIMIT 1)
             UNION ALL (SELECT 'purchase_order', id::text FROM purchase_orders ORDER BY created_at LIMIT 1) LOOP
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            SELECT count(*) INTO v_rows FROM record_trail(t.s, t.id, 500);
            EXECUTE 'RESET ROLE';
        EXCEPTION WHEN OTHERS THEN
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'AT1C2_PROOF|% % refused for tim@: %', t.s, t.id, SQLERRM;
        END;
        IF v_rows = 0 THEN RAISE EXCEPTION 'AT1C2_PROOF|% % has an empty trail for tim@ (every live record has at least its creation)', t.s, t.id; END IF;
        v_n := v_n + 1;
    END LOOP;
    RAISE NOTICE 'AT1C2 read % records as tim@, none refused, none empty', v_n;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ⑦ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.at1c2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'AT1C2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.at1c2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'AT1C2_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.at1c2_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.at1c2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

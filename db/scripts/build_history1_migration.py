#!/usr/bin/env python3
"""HISTORY-1:从镜像拼出迁移文件(形状照 build_role1b4b_migration.py)。
镜像是真源,迁移是它的一次投影 —— 函数、表、触发器、视图都从镜像里【原样抽出】,
所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_history1_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-28-history1-change-log.sql"
HISTORY = ['approval_log', 'customer_credit_history', 'employee_account_history', 'employment_history',
           'finance_settings_history', 'fixed_asset_history', 'fx_rate_history', 'price_history',
           'pricing_formula_history', 'processing_cost_entry_history', 'purchase_order_history', 'quote_history',
           'sales_attribution_log', 'sales_order_history', 'supplier_status_history', 'task_history',
           'work_order_history']


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def stmt(path, head):
    """从镜像里抽出以 head 开头、到【语句真正的结尾】为止的那一句(跳过注释与字符串里的分号)。"""
    s = mirror(path)
    assert s.count(head) == 1, (path, head)
    i = s.index(head)
    k = i
    while True:
        c = s[k]
        if s.startswith("--", k):
            k = s.index("\n", k)
        elif c == "'":
            k = s.index("'", k + 1)
            while s.startswith("''", k):
                k = s.index("'", k + 2)
        elif c == ";":
            return s[i:k + 1] + "\n"
        k += 1


def lb1_decider_check():
    """LEAVE-BAL-1 的"每一张在途单据都还有一个不是它自己当事人的决定人"判据,原样借用(改个前缀)。"""
    s = mirror("db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql")
    i = s.index("CREATE FUNCTION pg_temp.lb1_pending_decider_check")
    j = s.index("$f$;", i) + 4
    return s[i:j].replace("lb1_", "h1_") + "\n"


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
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'
UNION ALL SELECT 'overtime_batch', id FROM overtime_batches WHERE status = 'submitted'"""

# 每一张表每一行的指纹 —— 迁移前后逐表比。允许变的只有 permissions(+1 行)与 role_permissions(+2 行)。
FINGERPRINT = """DO $fp$
DECLARE t text; h text;
BEGIN
    FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'change_log' ORDER BY 1 LOOP
        EXECUTE format('SELECT md5(COALESCE(string_agg(x.r, E''\\n'' ORDER BY x.r), '''')) FROM (SELECT row(t.*)::text AS r FROM public.%I t) x', t) INTO h;
        INSERT INTO h1_fp_%s (table_name, digest) VALUES (t, h);
    END LOOP;
END;
$fp$;
"""

HEADER = """-- db/migrations/2026-09-28-history1-change-log.sql
-- HISTORY-1 —— 通用变更记录、保护与变更记录页(v1.4.32)。docs/change-log.md 是这一刀的说明书。
-- 由 db/scripts/build_history1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(HISTORY-0 勘察 + HISTORY-1 Step 0,Tim 2026-09-28 全部裁定)
--   ① change_log:一张只增不改的通用记录。238 张表各两条触发器(行级 + TRUNCATE),四张豁免带理由。
--      一行记:账号 + 【写入时冻住】的员工 · 无会话 + 数据库角色 · 编辑只记改了的列(前后)· 新增/删除整行 ·
--      seq 定先后 · clock_timestamp() 定时刻 · row_key 按主键列名。
--   ② 没有任何直接授权。读只走 change_log_rows()(新码 data.view_change_log,只授 admin 与 cfo),
--      按源屏幕逐列遮蔽(change_log_mask_rules,26 张表),任务四张表按 can_view_task 整行遮。
--   ③ 保护:change_log 拒 UPDATE / DELETE / TRUNCATE(唯一放行的是匿名化涂抹的那个形状);
--      task_history 与 work_order_history 补上只增不改守卫;17 张历史表全部补上 TRUNCATE 守卫;
--      purchase_order_history 的价格列按 data.view_purchase_prices 遮(新视图 purchase_order_history_masked)。
--   ④ set_role_permissions 只动有差别的码;anonymise_employee 清 greeting_name 并涂抹记录;
--      export_my_personal_data 加 my_record_changes;record_account_event 记账号的建 / 停用 / 启用 / 回滚删除;
--      user_directory 加 disabled 一列。
--
-- 【破窗】唯一会坏的是 /purchasing/orders/[id]:旧代码直读 purchase_order_history 的价格列,
--   收回之后 42501,直到新代码部署(Tim 的 Q11 接受)。其余全部是新增。
--
-- 【审批是开着的】文末自证在同一笔事务里断言:开关仍开;在途单据一张不少一张不多;每一张在途单据都还有
--   一个【不是它自己当事人】的决定人;除 permissions(+1)与 role_permissions(+2:admin、cfo)之外,
--   【每一张表的每一行】指纹不变;覆盖与遮蔽两道检查零缺口;本迁移自己的写入已经落进记录。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提 ────────────────────────────────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'H1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.change_log') IS NOT NULL THEN
        RAISE EXCEPTION 'H1_PRE|change_log already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code = 'data.view_change_log') THEN
        RAISE EXCEPTION 'H1_PRE|data.view_change_log already exists';
    END IF;
    IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r') <> 241 THEN
        RAISE EXCEPTION 'H1_PRE|expected 241 public tables before this migration';
    END IF;
END;
$pre$;

CREATE TEMP TABLE h1_pending_before ON COMMIT DROP AS
""" + PENDING + """;
CREATE TEMP TABLE h1_fp_before (table_name text PRIMARY KEY, digest text) ON COMMIT DROP;
CREATE TEMP TABLE h1_fp_after (table_name text PRIMARY KEY, digest text) ON COMMIT DROP;
""" + FINGERPRINT.replace("h1_fp_%s", "h1_fp_before") + """
CREATE TEMP TABLE h1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
"""

parts = [HEADER]

parts.append("\n-- ── 1 · 记录表与它的守卫 ───────────────────────────────────────────────────\n")
for f in ["change_log_redactable_columns", "change_log_redaction_ok", "change_log_null_keys",
          "guard_change_log_append_only"]:
    parts.append(fn(f))
parts.append("\n" + mirror("db/tables/change_log.sql"))

parts.append("\n-- ── 2 · 写入函数与豁免名单(绑定在 §7,见那里的理由)──────────────────────────\n")
for f in ["change_log_capture", "change_log_exclusions"]:
    parts.append(fn(f))

parts.append("\n-- ── 3 · 17 张历史表:TRUNCATE 守卫;task_history / work_order_history 的只增不改守卫 ──\n")
for f in ["guard_history_no_truncate", "guard_task_history_append_only", "guard_work_order_history_append_only"]:
    parts.append(fn(f))
GUARD_TRIGGERS = (stmt("db/tables/task_history.sql", "CREATE TRIGGER trg_task_history_append_only")
                  + stmt("db/tables/work_order_history.sql", "CREATE TRIGGER trg_work_order_history_append_only")
                  + "".join(stmt(f"db/tables/{t}.sql", f"CREATE TRIGGER trg_{t}_no_truncate") for t in HISTORY))

parts.append("\n-- ── 4 · purchase_order_history 的价格列遮蔽(Q20)───────────────────────────\n")
parts.append(stmt("db/tables/purchase_order_history.sql", "REVOKE SELECT ON public.purchase_order_history"))
parts.append(stmt("db/tables/purchase_order_history.sql", "GRANT SELECT (id, purchase_order_id, purchase_order_line_id"))
parts.append("\n" + mirror("db/views/purchase_order_history_masked.sql"))

parts.append("\n-- ── 5 · 读法、遮蔽、覆盖检查、账号事件与三支改过的函数 ───────────────────────\n")
for f in ["change_log_mask_rules", "change_log_field", "change_log_rule_visible", "change_log_task_visible",
          "change_log_restrict", "change_log_rows", "change_log_filters", "change_log_mask_gaps",
          "change_log_coverage_gaps", "change_log_redact_employee", "record_account_event",
          "set_role_permissions", "anonymise_employee", "export_my_personal_data"]:
    parts.append(fn(f))

parts.append("\n-- ── 6 · user_directory 加 disabled(末列)─────────────────────────────────\n")
ud = mirror("db/views/user_directory.sql")
ud = ud[ud.index("CREATE VIEW public.user_directory"):].replace("CREATE VIEW public.user_directory",
                                                                 "CREATE OR REPLACE VIEW public.user_directory", 1)
parts.append(ud)

parts.append("""
-- ── 7 · 238 张表的绑定 + 19 条历史表守卫:【一次往返】、放在尽量晚的地方 ─────────────
-- 【为什么包在一个 DO 里】CREATE TRIGGER 在那张表上拿 SHARE ROW EXCLUSIVE 锁,挡住写(读不挡),
--   而锁一直持到 COMMIT。第一次对着线上的干跑(整笔回滚)逐句发 ~500 条,用了 626 s ——
--   几乎全是逐句的网络往返;那段时间里 238 张表的写都会排队。包成一个 DO = 一次往返。
-- 【为什么放在这么后面】锁从这里开始算:前面的函数、视图、授权都先做完,
--   后面只剩新码的三次写(要被记下来,所以必须在绑定之后)、自证与授权兜底。
-- DO 里是字面的 CREATE TRIGGER(不是 EXECUTE 拼出来的),与镜像 db/views/zzz_change_log_triggers.sql 逐字同源。
DO $bind$
BEGIN
""" + "".join("    " + l + "\n" if l.strip() else "\n" for l in (
        "\n".join(x for x in mirror("db/views/zzz_change_log_triggers.sql").splitlines() if not x.startswith("--"))
        + "\n" + GUARD_TRIGGERS).splitlines()) + """END;
$bind$;
""")
parts.append("""
-- ── 8 · 新码 data.view_change_log:只授 admin 与 cfo(Q1)────────────────────
""")
seed = mirror("db/tables/permissions.sql")
row = re.search(r"^    \('data\.view_change_log'.*\),\s*$", seed, re.M).group(0).strip().rstrip(",")
parts.append(f"""INSERT INTO permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    {row};
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_change_log' FROM roles r WHERE r.code IN ('admin', 'cfo')
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

parts.append("\n-- ── 9 · 自证 ────────────────────────────────────────────────────────────────\n")
parts.append(lb1_decider_check())
parts.append("\nCREATE TEMP TABLE h1_pending_after ON COMMIT DROP AS\n" + PENDING + ";\n")
parts.append(FINGERPRINT.replace("h1_fp_%s", "h1_fp_after"))
parts.append("""
DO $proof$
DECLARE
    v_bad text;
    v_j   jsonb;
    v_n   int;
BEGIN
    -- ① 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'H1_PROOF|approvals switched off';
    END IF;
    -- ② 在途单据一张不少、一张不多
    IF EXISTS ((SELECT b.k, b.id FROM h1_pending_before b EXCEPT SELECT a.k, a.id FROM h1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM h1_pending_after a EXCEPT SELECT b.k, b.id FROM h1_pending_before b)) THEN
        RAISE EXCEPTION 'H1_PROOF|a pending document changed state';
    END IF;
    -- ③ 每一张在途单据都还有一个不是它自己当事人的决定人
    SELECT string_agg(k || ':' || doc, ', ') INTO v_bad FROM pg_temp.h1_pending_decider_check(true) WHERE deciders = 0;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'H1_PROOF|pending document(s) with no eligible decider: %', v_bad; END IF;
    -- ④ 每一张表的每一行:只有 permissions 与 role_permissions 变了
    SELECT string_agg(b.table_name, ', ' ORDER BY b.table_name) INTO v_bad
      FROM h1_fp_before b JOIN h1_fp_after a USING (table_name)
     WHERE a.digest IS DISTINCT FROM b.digest AND b.table_name NOT IN ('permissions', 'role_permissions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'H1_PROOF|rows changed in: %', v_bad; END IF;
    IF (SELECT count(*) FROM h1_fp_before) <> 241 OR (SELECT count(*) FROM h1_fp_after) <> 241 THEN
        RAISE EXCEPTION 'H1_PROOF|fingerprint did not cover 241 tables';
    END IF;
    -- ⑤ 授权:恰好多了 admin 与 cfo 的 data.view_change_log 两行,别的一行不差
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM h1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM h1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM 'admin:data.view_change_log, cfo:data.view_change_log' THEN
        RAISE EXCEPTION 'H1_PROOF|unexpected grant change: %', v_bad;
    END IF;
    -- ⑥ 覆盖:238 张绑定,4 张豁免,零缺口
    v_j := change_log_coverage_gaps();
    IF (v_j ->> 'examined')::int <> 242 OR (v_j ->> 'bound')::int <> 238 OR (v_j ->> 'excluded')::int <> 4
       OR jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'H1_PROOF|coverage: %', v_j;
    END IF;
    -- ⑦ 遮蔽名单与目录零缺口(26 张表)
    v_j := change_log_mask_gaps();
    IF (v_j ->> 'examined_tables')::int <> 26 OR jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'H1_PROOF|mask rules: %', v_j;
    END IF;
    -- ⑧ 本迁移自己的三次写(1 个码 + 2 条授权)已经记进去了,记成无会话 + postgres
    SELECT count(*) INTO v_n FROM change_log
     WHERE actor_kind = 'no_session' AND actor_account IS NULL AND op = 'INSERT'
       AND table_name IN ('permissions', 'role_permissions');
    IF v_n <> 3 THEN RAISE EXCEPTION 'H1_PROOF|expected 3 logged migration writes, got %', v_n; END IF;
    IF (SELECT count(*) FROM change_log) <> 3 THEN
        RAISE EXCEPTION 'H1_PROOF|change_log should hold exactly the migration''s own 3 rows';
    END IF;
    -- ⑨ 没有直接授权;价格列收回;新视图在
    IF has_table_privilege('authenticated', 'public.change_log', 'SELECT')
       OR has_table_privilege('authenticated', 'public.change_log', 'UPDATE')
       OR has_table_privilege('authenticated', 'public.change_log', 'DELETE')
       OR has_table_privilege('authenticated', 'public.change_log', 'TRUNCATE')
       OR has_table_privilege('service_role', 'public.change_log', 'SELECT')
       OR has_table_privilege('anon', 'public.change_log', 'SELECT') THEN
        RAISE EXCEPTION 'H1_PROOF|change_log has a direct grant';
    END IF;
    IF has_column_privilege('authenticated', 'public.purchase_order_history', 'new_estimated_unit_price', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.purchase_order_history', 'amend_reason', 'SELECT') THEN
        RAISE EXCEPTION 'H1_PROOF|purchase_order_history column grants are not the masked shape';
    END IF;
    -- ⑩ 7 个真账号都没被停用
    IF EXISTS (SELECT 1 FROM auth.users WHERE banned_until > now()) THEN
        RAISE EXCEPTION 'H1_PROOF|an account is disabled';
    END IF;
END;
$proof$;

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(len(p) for p in parts)} bytes)")

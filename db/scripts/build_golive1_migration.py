#!/usr/bin/env python3
"""GOLIVE-1(v1.4.82):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 策略、函数、视图与列级授权原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。照 build_mes9c_migration.py 的形状。
跑法:python3 db/scripts/build_golive1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-29-golive-1.sql"


def read(path):
    return (ROOT / path).read_text()


def fn(name):
    body = read(f"db/functions/{name}.sql").rstrip("\n") + "\n"
    assert body.count("CREATE OR REPLACE FUNCTION") == 1, name
    body = re.sub(r"^\$function\$$", "$function$;", body, flags=re.M)
    return "\n" + body


def policy(table_file, name):
    t = read(f"db/tables/{table_file}.sql")
    m = re.search(r'CREATE POLICY "' + re.escape(name) + r'"\n.*?;\n', t, re.S)
    assert m, (table_file, name)
    return m.group(0)


def block(path, start, end_inclusive):
    t = read(path)
    a = t.index(start)
    b = t.index(end_inclusive, a) + len(end_inclusive)
    return t[a:b]


def grant_lines(table):
    t = read(f"db/tables/{table}.sql")
    m = re.search(r"REVOKE SELECT ON public\." + table + r" FROM authenticated, anon;\nGRANT SELECT \(.*?\) ON public\." + table + r" TO authenticated;\n", t, re.S)
    assert m, table
    return m.group(0)


def view(name):
    t = read(f"db/views/{name}.sql")
    a = t.index("CREATE VIEW")
    return t[a:].rstrip("\n") + "\n"


ROW12_TABLES = ["sales_settlements", "contract_pricing_terms", "contract_refining_charges", "contract_penalty_elements", "contract_insurance_obligations"]

# ── row 6:container_overview 用 CREATE OR REPLACE VIEW … WITH (security_invoker = off) 重建(列不变),注释同步 ──────────────
cov = read("db/views/container_overview.sql")
cov_def = cov[cov.index("CREATE VIEW public.container_overview"):cov.index("COMMENT ON VIEW public.container_overview")]
cov_def = cov_def.replace("CREATE VIEW public.container_overview WITH (security_invoker = off) AS",
                          "CREATE OR REPLACE VIEW public.container_overview WITH (security_invoker = off) AS").rstrip("\n") + "\n"
cov_comment = cov[cov.index("COMMENT ON VIEW public.container_overview"):cov.index("GRANT SELECT ON public.container_overview")].rstrip("\n") + "\n"
assert "module.purchasing.view" not in cov_def

# employee 的说明取自引导那一行(Q3)—— 迁移与镜像同一串字
m = re.search(re.escape("('employee', 'Employee (unused)', '员工(暂未使用)', '") + r"((?:[^']|'')*)', '((?:[^']|'')*)', false, true, 100\)", read("db/tables/roles.sql"))
assert m, "employee bootstrap row"
emp_en, emp_zh = m.group(1).replace("''", "'"), m.group(2).replace("''", "'")

sql = f"""-- db/migrations/2026-10-29-golive-1.sql
-- GOLIVE-1(v1.4.82,docs/forward-queue.md「上线准备组」第 1 · 2 · 4 · 5 · 6 · 11 · 12 行)—— Tim 2026-10-20 的 d2 #2 · #6 · #14 · #27 · #30,
--   2026-10-23 TABLE-EXPORT-2b Q5,2026-10-25 TABLE-EXPORT-3c Q3,2026-10-29 GOLIVE-1 Step 0 的 Q1–Q9。由 db/scripts/build_golive1_migration.py 从镜像拼出。
--
--   第 1 行  action.metal_prices 读得到 metal_prices · index_market_calendar · pricing_settings(Q6:三张一起)。
--   第 2 行  【线上不动】:方案 1 与 4 早在 COD-2(2026-09-08)落地;本刀补的是重建一侧(db/platform-prelude.sql 的重放后一段)、
--            安装清单、基线收缩与一道比默认权限的门 —— 都不是线上 DDL。
--   第 4 行  已批准(approved · active · suspended)的供应商改了法定名、税号或类型 → 回到 pending_review、清批准戳(Q7);
--            状态历史的触发器从 UPDATE OF status 改成 UPDATE … WHEN 状态变了,这一次回待审才会留下一行历史。
--   第 5 行  hr · procurement · sales 删掉(下面先断言 0 个持有人,含已撤销的授予);auditor 补 module.quality.view · data.view_cod ·
--            data.view_change_log(Q2,25 个码);employee 的说明改写(Q3);operations 与 floor_display 不动(Q4)。
--   第 6 行  container_overview 的读者 = module.logistics.view(FIX-2a 留下的 purchasing OR logistics 收成一个码)。
--   第 11 行 save_employee:看不见身份四列(work_email · work_phone · identity_no · work_pass_no)的人保存,那四列原样不动(Q8)。
--   第 12 行 结算金额(sales_settlements 六列钱,data.view_prices)与合同条款上的价格(payable_pct · 精炼费 · 罚则费率 · 保险最低金额,
--            按合同那一侧:客户 → data.view_prices,供应商 → data.view_purchase_prices)从此列级遮蔽:REVOKE SELECT + 列清单 GRANT +
--            五张 <表>_masked;变更记录的遮蔽规则 +10 行(新写法 contract_price);list_totals_settlements 改读伴生视图。
-- 镜像(同一个提交):db/tables/metal_prices · index_market_calendar · pricing_settings · suppliers · roles · role_permissions ·
--   sales_settlements · contract_pricing_terms · contract_refining_charges · contract_penalty_elements · contract_insurance_obligations;
--   db/functions/requeue_supplier_on_identity_change · save_employee · contract_terms_price_visible · change_log_mask_rules ·
--   change_log_rule_visible · list_totals_settlements;db/views/container_overview 与五张 *_masked。
-- 【引导默认值】roles / role_permissions 是运行期配置的表:本刀把它们的引导改成【线上那 11 个角色、逐码相同】(Q5)——
--   引导的数仍然是对的(它们现在就是线上的数),由 db/fixtures/298 与 db/live-fixtures/298 两头钉住。
BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 第 5 行 · 删之前先量:hr / procurement / sales 必须 0 个持有人(含已撤销的授予 —— user_roles 对 roles 是 ON DELETE RESTRICT)
-- ════════════════════════════════════════════════════════════════════════════
DO $held$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id WHERE r.code IN ('hr', 'procurement', 'sales');
    IF n <> 0 THEN
        RAISE EXCEPTION 'GOLIVE1_ROLE_HELD|% grant row(s) on hr / procurement / sales — not deleting a held role', n;
    END IF;
    IF (SELECT count(*) FROM public.roles WHERE code IN ('hr', 'procurement', 'sales')) <> 3 THEN
        RAISE EXCEPTION 'GOLIVE1_ROLES_MISSING|expected hr, procurement and sales to exist before the delete';
    END IF;
END
$held$;

-- ════════════════════════════════════════════════════════════════════════════
-- 第 1 行 · 三张表的读策略
-- ════════════════════════════════════════════════════════════════════════════
DROP POLICY "metal_prices select by permission" ON public.metal_prices;
{policy("metal_prices", "metal_prices select by permission")}
DROP POLICY "index market calendar select by pricing permission" ON public.index_market_calendar;
{policy("index_market_calendar", "index market calendar select by pricing permission")}
DROP POLICY "pricing_settings select" ON public.pricing_settings;
{policy("pricing_settings", "pricing_settings select")}
-- ════════════════════════════════════════════════════════════════════════════
-- 第 4 行 · 改身份回待审
-- ════════════════════════════════════════════════════════════════════════════
{fn("requeue_supplier_on_identity_change")}
DROP TRIGGER trg_suppliers_status_history ON public.suppliers;
{block("db/tables/suppliers.sql", "CREATE TRIGGER trg_suppliers_status_history", "EXECUTE FUNCTION public.log_supplier_status_change();")}

{block("db/tables/suppliers.sql", "CREATE TRIGGER trg_suppliers_zz_requeue_on_identity_change", "EXECUTE FUNCTION public.requeue_supplier_on_identity_change();")}

-- ════════════════════════════════════════════════════════════════════════════
-- 第 5 行 · 空角色
-- ════════════════════════════════════════════════════════════════════════════
DELETE FROM public.roles WHERE code IN ('hr', 'procurement', 'sales');   -- role_permissions 随之 CASCADE

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, c FROM public.roles r, unnest(ARRAY['module.quality.view', 'data.view_cod', 'data.view_change_log']) c
 WHERE r.code = 'auditor'
ON CONFLICT (role_id, permission_code) DO NOTHING;

UPDATE public.roles
   SET description_en = '{emp_en.replace("'", "''")}',
       description_zh = '{emp_zh.replace("'", "''")}'
 WHERE code = 'employee';

-- ════════════════════════════════════════════════════════════════════════════
-- 第 6 行 · container_overview 的读者
-- ════════════════════════════════════════════════════════════════════════════
{cov_def}
{cov_comment}
-- ════════════════════════════════════════════════════════════════════════════
-- 第 11 行 · 员工表单不清身份四列
-- ════════════════════════════════════════════════════════════════════════════
{fn("save_employee")}
-- ════════════════════════════════════════════════════════════════════════════
-- 第 12 行 · 结算与合同条款上的价格:列级遮蔽 + 伴生视图 + 变更记录规则
-- ════════════════════════════════════════════════════════════════════════════
{fn("contract_terms_price_visible")}
REVOKE EXECUTE ON FUNCTION public.contract_terms_price_visible(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.contract_terms_price_visible(uuid) TO authenticated, service_role;

{"".join(grant_lines(t) for t in ROW12_TABLES)}
{"".join(view(t + "_masked") + chr(10) for t in ROW12_TABLES)}{fn("change_log_mask_rules")}{fn("change_log_rule_visible")}{fn("list_totals_settlements")}
-- ── 事务内自证:任何一条不成立,整支回滚 ────────────────────────────────────
DO $proof$
DECLARE v text; n int;
BEGIN
    SELECT string_agg(code, ',' ORDER BY code) INTO v FROM public.roles;
    IF v IS DISTINCT FROM 'admin,auditor,cco,cfo,cto,employee,finance,floor_display,gm,operations,warehouse' THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF roles: %', v;
    END IF;
    SELECT count(*) INTO n FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'auditor';
    IF n <> 25 OR EXISTS (SELECT 1 FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                           WHERE r.code = 'auditor' AND (rp.permission_code NOT LIKE '%.view%' OR rp.permission_code IN
                                 ('data.view_banking', 'data.view_pay', 'data.view_identity', 'data.view_health', 'data.view_reviews'))) THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF auditor: % codes', n;
    END IF;
    IF (SELECT count(*) FROM public.permissions WHERE code LIKE 'module.%.view'
          AND code NOT IN (SELECT rp.permission_code FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'auditor')) <> 0 THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF auditor lacks a module view code';
    END IF;
    IF EXISTS (SELECT 1 FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'employee') THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF employee holds a code';
    END IF;
    SELECT count(*) INTO n FROM pg_policies WHERE schemaname = 'public' AND cmd = 'SELECT'
       AND tablename IN ('metal_prices', 'index_market_calendar', 'pricing_settings') AND qual LIKE '%action.metal_prices%';
    IF n <> 3 THEN RAISE EXCEPTION 'GOLIVE1_PROOF metal read policies: % of 3', n; END IF;
    IF pg_get_viewdef('public.container_overview'::regclass) LIKE '%purchasing%'
       OR pg_get_viewdef('public.container_overview'::regclass) NOT LIKE '%module.logistics.view%'
       OR NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.container_overview'::regclass AND 'security_invoker=off' = ANY (reloptions)) THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF container_overview';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.suppliers'::regclass AND tgname = 'trg_suppliers_zz_requeue_on_identity_change') THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF requeue trigger';
    END IF;
    IF has_column_privilege('authenticated', 'public.sales_settlements', 'amount_usd', 'SELECT')
       OR has_column_privilege('authenticated', 'public.contract_refining_charges', 'usd_per_tonne_of_metal', 'SELECT')
       OR has_column_privilege('authenticated', 'public.contract_penalty_elements', 'usd_per_tonne_per_pct_over', 'SELECT')
       OR has_column_privilege('authenticated', 'public.contract_insurance_obligations', 'min_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.contract_pricing_terms', 'payable_pct', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.sales_settlements', 'sales_order_id', 'SELECT')
       OR has_table_privilege('anon', 'public.sales_settlements', 'SELECT') THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF column grants';
    END IF;
    SELECT count(*) INTO n FROM change_log_mask_rules();
    IF n <> 129 THEN RAISE EXCEPTION 'GOLIVE1_PROOF mask rules: %', n; END IF;
    IF jsonb_array_length(change_log_mask_gaps() -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'GOLIVE1_PROOF mask gaps: %', change_log_mask_gaps();
    END IF;
    RAISE NOTICE 'GOLIVE1_PROOF ok';
END
$proof$;

COMMIT;
"""
OUT.write_text(sql)
print(f"wrote {OUT} ({len(sql)} bytes)")

\set ON_ERROR_STOP 1
SET lock_timeout = '10s';
\timing on
BEGIN;
SELECT 'PROOF|A|postgres|' || json_build_object(
  'new_code_holders', (SELECT COALESCE(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code), 'none')
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                    WHERE rp.permission_code IN ('action.manage_esg','data.view_whistleblowing','data.view_whistleblowing_escalated')),
  'grants_total', (SELECT count(*) FROM public.role_permissions),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t),
  'new_tables', (SELECT COALESCE(string_agg(relname, ',' ORDER BY relname), 'none') FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ('esg_settings','grid_emission_factors','required_trainings','company_policies','whistleblowing_reports','whistleblowing_updates','incident_days_lost_corrections')),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'incidents', (SELECT count(*) FROM public.incidents), 'training_records', (SELECT count(*) FROM public.training_records),
  'approvals', (SELECT approvals_enabled FROM public.finance_settings),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM public.ingest_settings))::text;
-- ── migration body ──

-- ── 0 · 前提:线上是我们以为的那个样子 ──
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ESG2_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
                WHERE c.relname IN ('esg_settings', 'grid_emission_factors', 'required_trainings', 'company_policies', 'whistleblowing_reports', 'whistleblowing_updates', 'incident_days_lost_corrections', 'company_policy_rows', 'whistleblowing_report_rows'))
       OR EXISTS (SELECT 1 FROM permissions WHERE code IN ('data.view_whistleblowing', 'data.view_whistleblowing_escalated', 'action.manage_esg'))
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'training_records' AND column_name = 'required_training_id') THEN
        RAISE EXCEPTION 'ESG2_PRE|an ESG-2 table, view, column or code already exists';
    END IF;
    IF (SELECT count(*) FROM roles) <> 11 OR (SELECT count(*) FROM roles WHERE code IN ('admin', 'cco', 'cfo')) <> 3 THEN
        RAISE EXCEPTION 'ESG2_PRE|expected the 11 roles including admin, cco and cfo';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'ESG2_PRE|require_calibrated_since must be empty and the two CODs in place';
    END IF;
END;
$pre$;
CREATE TEMP TABLE esg2_grants_before ON COMMIT DROP AS
SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE esg2_user_roles_before ON COMMIT DROP AS
SELECT user_id, role_id, revoked_at FROM user_roles;
CREATE TEMP TABLE esg2_incident_rows_before ON COMMIT DROP AS
SELECT id, days_lost FROM incident_rows;

-- ── 1 · 三个新码(与 db/tables/permissions.sql 同几行)与它们的五处授予(与 db/tables/role_permissions.sql 同)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_whistleblowing', 'data', 'Read whistleblowing reports', '阅读举报', 'Read the whistleblowing reports that are not marked as concerning the CCO, record reports received outside the system, and add their status updates. Reports marked as concerning the CCO are read only under Read escalated whistleblowing reports.', '阅读没有标明涉及 CCO 的举报,登记在系统之外收到的举报,并为它们追加状态。标明涉及 CCO 的举报只归「阅读涉及 CCO 的举报」。', 295),
    ('data.view_whistleblowing_escalated', 'data', 'Read escalated whistleblowing reports', '阅读涉及 CCO 的举报', 'Read the whistleblowing reports marked as concerning the CCO, record such reports received outside the system, and add their status updates. The CCO cannot read these.', '阅读标明涉及 CCO 的举报,登记在系统之外收到的这类举报,并为它们追加状态。CCO 读不到这些。', 296),
    ('action.manage_esg', 'action', 'Maintain ESG settings and registers', '维护 ESG 设定与登记簿', 'Set the grid emission factor for a year (a correction adds a new version with a reason), set the standard hours per working day used for injury rates, maintain the list of required trainings, and record company policies and their new versions.', '设定某一年的电网排放因子(更正是带理由的新版本)、设定算工伤率用的标准日工时、维护必修培训清单,以及登记公司制度与它们的新版本。', 1290);
UPDATE public.permissions SET requires_view_any = ARRAY['module.finance.view','module.hr.view','module.processing.view','module.safety.view'] WHERE code = 'action.manage_esg';
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, g.code FROM (VALUES ('admin', 'action.manage_esg'), ('cco', 'action.manage_esg'), ('cco', 'data.view_whistleblowing'), ('cfo', 'action.manage_esg'), ('cfo', 'data.view_whistleblowing_escalated')) AS g(role, code)
  JOIN public.roles r ON r.code = g.role
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 2 · 新的读策略要调的两支判据(镜像原样)──
-- db/functions/whistleblowing_report_readable.sql
-- ESG-2(Tim 2026-10-31 Q13):一件举报【当前读者】读不读得到 —— 判据只有这一份(两张举报表的读策略、四支举报函数、举报页都问它)。
--   concerns_cco = true(交的人勾了「这件事涉及 CCO」)→ 只认 data.view_whistleblowing_escalated(cfo);cco 持的 data.view_whistleblowing 不算。
--   concerns_cco = false → 只认 data.view_whistleblowing(cco)。两个码都不授 admin(db/tables/role_permissions.sql)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.whistleblowing_report_readable(p_concerns_cco boolean)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_concerns_cco THEN has_permission('data.view_whistleblowing_escalated')
                ELSE has_permission('data.view_whistleblowing') END;
$function$;
-- db/functions/incident_injured_is_caller.sql
-- ESG-2(Tim 2026-10-31 Q7):这件事故受伤的那名员工,是不是【调用者自己】。incident_days_lost_corrections 的读策略用它给受伤的人本人让路
--   (与 incidents_masked 里 OR injured_employee_id = current_user_employee() 同一个判据)。
--   【属主权限】injured_employee_id 从列授权里拿掉了,读策略里的子查询以调用者身份读不到那一列;这里只回一个布尔,不回任何列。
--   current_user_employee() 为空(没有员工档案)→ false(COALESCE,CLEANUP-A 的那个陷阱)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.incident_injured_is_caller(p_incident_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((SELECT i.injured_employee_id = current_user_employee() FROM incidents i WHERE i.id = p_incident_id), false);
$function$;

-- ── 3 · esg_settings(镜像原样:db/tables/esg_settings.sql)──
-- db/tables/esg_settings.sql
-- ESG-2(Tim 2026-10-31 Q4 · Q9):【ESG 的设定 —— 单行】。今天只有一样:
--   standard_hours_per_day —— 一个工作日算几个小时,用来把考勤折成「工时」(安全率页的分母:LTIFR = 误工事故 × 1,000,000 ÷ 工时)。
--     为空 = 「没设」:安全率页每个月的工时读「没设标准日工时」,一个率都不算(不猜一个 8)。Tim 设一次(他的待办)。
--   由 action.manage_esg(admin · cco · cfo)经 esg_set_standard_hours 改;修改史在变更记录里(主语 esg_settings)。
--   RUNTIME CONFIG:引导一行、值为空;Tim 填一次,线上就与本文件不同 —— 那是系统在正常工作。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.esg_settings (
    id                      boolean PRIMARY KEY DEFAULT true CHECK (id),
    standard_hours_per_day  numeric CHECK (standard_hours_per_day IS NULL OR (standard_hours_per_day > 0 AND standard_hours_per_day <= 24)),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    updated_by              uuid DEFAULT auth.uid()
);
COMMENT ON TABLE public.esg_settings IS
    'ESG-2:ESG 的设定(单行)。standard_hours_per_day = 一个工作日算几个小时(安全率的工时分母);为空时不算任何率。action.manage_esg 经 esg_set_standard_hours 改。';
COMMENT ON COLUMN public.esg_settings.standard_hours_per_day IS
    '一个工作日算几个小时(Tim 2026-10-31 Q4)。工时 = (在职期间的工作日 − 批准的请假天数)× 本值 + 三列加班工时。空 = 没设 —— 安全率页不算率。';
INSERT INTO public.esg_settings (id) VALUES (true);
CREATE TRIGGER trg_esg_settings_updated_at
    BEFORE UPDATE ON public.esg_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
ALTER TABLE public.esg_settings ENABLE ROW LEVEL SECURITY;
-- 读:安全查看码(安全率页)或维护它的码。写只经函数。
CREATE POLICY "esg_settings select by permission" ON public.esg_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['module.safety.view'::text, 'action.manage_esg'::text])));
REVOKE ALL ON public.esg_settings FROM authenticated, anon;
GRANT SELECT ON public.esg_settings TO authenticated;

-- ── 3 · grid_emission_factors(镜像原样:db/tables/grid_emission_factors.sql)──
-- db/tables/grid_emission_factors.sql
-- ESG-2(Tim 2026-10-31 Q1 · Q2 · Q3 · Q9):【电网排放因子 —— 一年一个,带历史】。Scope 2(按地点法)= 电费单的 kWh × 那一年的因子。
--   【一年一个,按电费单的年份用】(Q2 (a)):一张单用它【账期结束那一天】的年份的因子;那一年没有就用【更早最近的一年】,页面照直说用的是哪一年;
--     比所有已填年份都早的单 → 「没设因子」,从不读成 0(Q1)。
--   【更正是新版本】(Q2):同一年再填一次 = 追加一行,要写理由;最后一行说了算(id 是 identity,排得出先后 —— AGING-1)。行写下就不改、不删。
--   【单位】EMA 公布的新加坡电网因子只含 CO2(不是 CO2e),所以单位写死 kg CO2/kWh,页面上的数读 tCO2(Q3)。
--   【引导不带值】(Q1):Tim 对着 EMA 的页面核过之后自己填(候选 0.402 / 2024,未核实,见 docs/known-issues.md § ESG2-GRID-FACTOR-UNVERIFIED)。
--   【写】只经 esg_set_grid_factor(action.manage_esg:admin · cco · cfo)。【读】每一个登录的人(一个公开的数;读不到它会把「没设」说成真的)。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.grid_emission_factors (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    factor_year     integer NOT NULL CHECK (factor_year BETWEEN 2000 AND 2100),
    kg_co2_per_kwh  numeric NOT NULL CHECK (kg_co2_per_kwh > 0 AND kg_co2_per_kwh < 5),
    unit            text NOT NULL DEFAULT 'kg CO2/kWh' CHECK (unit = 'kg CO2/kWh'),
    source          text NOT NULL CHECK (btrim(source) <> ''),
    reason          text CHECK (reason IS NULL OR btrim(reason) <> ''),
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    recorded_by     uuid DEFAULT auth.uid()
);
CREATE INDEX grid_emission_factors_year ON public.grid_emission_factors (factor_year, id);
COMMENT ON TABLE public.grid_emission_factors IS
    'ESG-2:电网排放因子(kg CO2/kWh),一年一个、带历史:同一年再填一次是带理由的新版本,最后一行说了算。电费单用它账期结束那一年的因子,没有就用更早最近的一年。只经 esg_set_grid_factor 写(action.manage_esg);写下就不改、不删。';
COMMENT ON COLUMN public.grid_emission_factors.reason IS
    '同一年的第二个及以后的版本必填(为什么改);第一个版本为空。';

-- 写下就不改、不删(语句级,所以 RLS 碰不到行时照样抛 —— ALERT-1)。authenticated 没有任何写授权,唯一的写入口是 esg_set_grid_factor;
--   这支守卫挡的是属主那一侧的路(一次迁移、一支 DEFINER 函数)。
CREATE OR REPLACE FUNCTION public.guard_grid_emission_factor_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'ESG_GRID_FACTOR_IMMUTABLE';
END;
$function$;
CREATE TRIGGER trg_grid_emission_factors_immutable
    BEFORE UPDATE OR DELETE ON public.grid_emission_factors
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_grid_emission_factor_write();
CREATE TRIGGER trg_grid_emission_factors_truncate
    BEFORE TRUNCATE ON public.grid_emission_factors
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.grid_emission_factors ENABLE ROW LEVEL SECURITY;
CREATE POLICY "grid_emission_factors select by any signed-in user" ON public.grid_emission_factors
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);
REVOKE ALL ON public.grid_emission_factors FROM authenticated, anon;
GRANT SELECT ON public.grid_emission_factors TO authenticated;

-- ── 3 · required_trainings(镜像原样:db/tables/required_trainings.sql)──
-- db/tables/required_trainings.sql
-- ESG-2(Tim 2026-10-31 Q8 · Q9):【必修培训清单】—— 哪些培训是【必须有】的、对谁必须、有效多久。培训合规页(ESG › 培训合规)按它算覆盖与到期。
--   一行 = 一门必修培训:名字 · 类别(与 training_records.category 同一组)· 有效期(月;空 = 不过期,除非那一条记录自己写了到期日)·
--   对谁必须(applies_to):everyone 全体在职员工 · office 办公室 · shopfloor 车间(employees.work_category)· positions 点名的岗位(position_ids,至少一个)。
--   【培训记录挂到这一门上】training_records.required_training_id(HR 的培训表单里选)。不挂的老记录照旧在,页面把它们数成「没挂到必修培训」。
--   【到期】一条记录的到期日 = 它自己写的 expiry_date;没写而这一门有有效期 → completed_date + 有效期;两样都没有 → 不过期。
--     「快到期」= 90 天内,「紧急」= 30 天内(与 hr_alerts 的 training_expiry 同一组窗口,Q8)。
--   【停用不删】retired_at:不再必修的一门从覆盖里拿掉,挂着它的记录照旧在。
--   【写】只经 required_training_save / required_training_retire(action.manage_esg:admin · cco · cfo)。【读】module.hr.view 或 action.manage_esg。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.required_trainings (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name             text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    category         text CHECK (category IN ('induction','safety','compliance','cybersecurity','technical','leadership','other')),
    validity_months  integer CHECK (validity_months IS NULL OR validity_months BETWEEN 1 AND 240),
    applies_to       text NOT NULL CHECK (applies_to IN ('everyone','office','shopfloor','positions')),
    position_ids     uuid[] NOT NULL DEFAULT '{}'::uuid[],
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    updated_by       uuid DEFAULT auth.uid(),
    retired_at       timestamptz,
    retired_by       uuid,
    CONSTRAINT required_trainings_positions_shape CHECK ((applies_to = 'positions') = (cardinality(position_ids) > 0)),
    CONSTRAINT required_trainings_retired_shape CHECK ((retired_at IS NULL) = (retired_by IS NULL))
);
CREATE UNIQUE INDEX required_trainings_name_active ON public.required_trainings (lower(btrim(name))) WHERE retired_at IS NULL;
COMMENT ON TABLE public.required_trainings IS
    'ESG-2(Q8):必修培训清单 —— 名字、类别、有效期(月)、对谁必须(全体 / 办公室 / 车间 / 点名的岗位)。培训记录经 training_records.required_training_id 挂上来;培训合规页按它算覆盖与到期。停用不删。只经 required_training_save / _retire 写(action.manage_esg)。';
CREATE TRIGGER trg_required_trainings_updated_at
    BEFORE UPDATE ON public.required_trainings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
ALTER TABLE public.required_trainings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "required_trainings select by permission" ON public.required_trainings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_any_permission(ARRAY['module.hr.view'::text, 'action.manage_esg'::text])));
-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是两支属主权限函数。
REVOKE ALL ON public.required_trainings FROM authenticated, anon;
GRANT SELECT ON public.required_trainings TO authenticated;

-- ── 3 · training_records 加一列(镜像 db/tables/training_records.sql 里它是 CREATE TABLE 的最后一列)──
ALTER TABLE public.training_records ADD COLUMN required_training_id uuid REFERENCES public.required_trainings (id);
CREATE INDEX idx_training_records_required ON public.training_records (required_training_id) WHERE deleted_at IS NULL;

-- ── 3 · company_policies(镜像原样:db/tables/company_policies.sql)──
-- db/tables/company_policies.sql
-- ESG-2(Tim 2026-10-31 Q9 · Q10):【公司制度登记簿】—— 一行 = 一份制度的【一个版本】:标题 · 版本号 · 负责人(一名员工)· 生效日 · 复审日 · 文件在哪(一句文字,
--   不上传文件 —— 免费档 900 MB 的存储上限,也不开新桶)。
--   【新版本取代旧版本】supersedes_id 指着它取代的那一版;被取代的那一版记 superseded_at(由写函数一并写,同一笔事务)。一份制度的「现在」= 没被取代的那一版。
--     一版最多被取代一次(部分唯一索引)。行写下之后只有 superseded_at 那一格会被写一次,别的列不改、不删(守卫)。
--   【复审逾期】现在那一版的复审日早于新加坡的今天 → 页面标「复审逾期」(company_policy_rows.review_overdue)。
--   【写】只经 company_policy_record(action.manage_esg:admin · cco · cfo)。
--   【读】每一个登录的【员工】(有员工档案的人)与持 action.manage_esg 的人 —— 供应商门户的账号也是 authenticated,所以判据不是 true。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.company_policies (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    title              text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 200),
    version            text NOT NULL CHECK (length(btrim(version)) BETWEEN 1 AND 40),
    owner_employee_id  uuid NOT NULL REFERENCES public.employees (id),
    effective_date     date NOT NULL,
    review_date        date NOT NULL,
    document_ref       text NOT NULL CHECK (length(btrim(document_ref)) BETWEEN 1 AND 500),
    supersedes_id      uuid REFERENCES public.company_policies (id),
    superseded_at      timestamptz,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    CONSTRAINT company_policies_review_after_effective CHECK (review_date >= effective_date),
    CONSTRAINT company_policies_not_self CHECK (supersedes_id IS NULL OR supersedes_id <> id)
);
CREATE UNIQUE INDEX company_policies_superseded_once ON public.company_policies (supersedes_id) WHERE supersedes_id IS NOT NULL;
CREATE INDEX company_policies_owner_employee_id_rel ON public.company_policies (owner_employee_id);
COMMENT ON TABLE public.company_policies IS
    'ESG-2(Q10):公司制度登记簿 —— 一行是一份制度的一个版本(标题、版本号、负责人、生效日、复审日、文件在哪的一句文字)。新版本经 supersedes_id 取代旧版本,旧版本记 superseded_at。只经 company_policy_record 写(action.manage_esg);每一位员工都读得到。';

-- 只许 superseded_at 被写一次;别的列不改;不删(语句级的删除守卫让 RLS 碰不到行时照样抛)。
CREATE OR REPLACE FUNCTION public.guard_company_policy_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'COMPANY_POLICY_IMMUTABLE';
    END IF;
    IF (to_jsonb(NEW) - 'superseded_at') IS DISTINCT FROM (to_jsonb(OLD) - 'superseded_at')
       OR OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL THEN
        RAISE EXCEPTION 'COMPANY_POLICY_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;
CREATE TRIGGER trg_company_policies_guard
    BEFORE UPDATE ON public.company_policies
    FOR EACH ROW EXECUTE FUNCTION public.guard_company_policy_write();
CREATE TRIGGER trg_company_policies_no_delete
    BEFORE DELETE ON public.company_policies
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_company_policy_write();
CREATE TRIGGER trg_company_policies_truncate
    BEFORE TRUNCATE ON public.company_policies
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.company_policies ENABLE ROW LEVEL SECURITY;
CREATE POLICY "company_policies select by employees" ON public.company_policies
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT current_user_employee()) IS NOT NULL OR (SELECT has_permission('action.manage_esg'::text)));
REVOKE ALL ON public.company_policies FROM authenticated, anon;
GRANT SELECT ON public.company_policies TO authenticated;

-- ── 3 · whistleblowing_reports(镜像原样:db/tables/whistleblowing_reports.sql)──
-- db/tables/whistleblowing_reports.sql
-- ESG-2(Tim 2026-10-31 Q11 – Q14):【举报登记簿】—— 一行 = 一件举报。
--   【谁交】(Q11)任何一位登录的员工,在 /me 的「提出一个关切」里交(source = in_system,filed_by_employee_id = 他自己);
--     读者也可以把【系统之外】收到的举报登记进来(电邮、信、电话、当面):outside_named(写下举报人)或 outside_anonymous(匿名来源)。
--   【保密,不是匿名】(Q12)系统里交的举报存着交的人是谁,只有读者看得见;表单照直这么说。「匿名来源」只出现在读者登记的外来举报上。
--   【谁读】(Q13)concerns_cco = false → 持 data.view_whistleblowing 的人(cco);concerns_cco = true(交的人勾了「这件事涉及 CCO」)→ 只有持
--     data.view_whistleblowing_escalated 的人(cfo)读,cco 读不到。判据只有一份:whistleblowing_report_readable(concerns_cco)。
--     交的人读得到【自己那几件的状态】(my_concerns(),不经本表的读策略)。
--   【不改、不删】(Q14)状态的变化是 whistleblowing_updates 的追加行;本表的行写下就定了(语句级守卫,对谁都按名拒)。本刀不设保留期。
--   【不进变更记录】变更记录会把每一行的【操作人】印给持 data.view_change_log 的人(admin · cfo · auditor)—— 那就把「谁交了举报」交了出去;
--     而行本身写下就不改、自带谁在何时(recorded_by / recorded_at)。于是两张举报表登记为变更记录的豁免(change_log_exclusions,带理由),
--     举报的内容与交的人在变更记录里对谁都不出现(Q13:"masked in Change history for everyone except the report's readers" —— 读者在举报页上读全部)。
--   【写】只经 whistleblowing_report_file(员工自己交)与 whistleblowing_report_record_outside(读者登记外来的)。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.whistleblowing_reports (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source                text NOT NULL CHECK (source IN ('in_system', 'outside_named', 'outside_anonymous')),
    concerns_cco          boolean NOT NULL,
    filed_by_employee_id  uuid REFERENCES public.employees (id),
    reporter_name         text,
    received_via          text CHECK (received_via IS NULL OR received_via IN ('email', 'letter', 'phone', 'in_person', 'other')),
    received_on           date NOT NULL,
    subject               text NOT NULL CHECK (length(btrim(subject)) BETWEEN 1 AND 200),
    details               text NOT NULL CHECK (length(btrim(details)) BETWEEN 1 AND 10000),
    recorded_at           timestamptz NOT NULL DEFAULT now(),
    recorded_by           uuid NOT NULL,
    -- 系统里交的:交的人是一名员工、没有收到的方式与外来的名字;外来的:有收到的方式,具名的写下名字,匿名的不写
    CONSTRAINT whistleblowing_reports_source_shape CHECK (
        (source = 'in_system' AND filed_by_employee_id IS NOT NULL AND reporter_name IS NULL AND received_via IS NULL)
        OR (source = 'outside_named' AND filed_by_employee_id IS NULL AND reporter_name IS NOT NULL AND btrim(reporter_name) <> '' AND received_via IS NOT NULL)
        OR (source = 'outside_anonymous' AND filed_by_employee_id IS NULL AND reporter_name IS NULL AND received_via IS NOT NULL))
);
CREATE INDEX whistleblowing_reports_filed_by_employee_id_rel ON public.whistleblowing_reports (filed_by_employee_id);
COMMENT ON TABLE public.whistleblowing_reports IS
    'ESG-2(Q11–Q14):举报登记簿,一行一件。员工在 /me 交(保密,不是匿名),或读者登记系统之外收到的(具名或匿名来源)。concerns_cco = 真的只由持 data.view_whistleblowing_escalated 的人读(cfo),否则由持 data.view_whistleblowing 的人读(cco)。不改、不删;状态在 whistleblowing_updates。不进变更记录(操作人会把交的人交出去)。';
COMMENT ON COLUMN public.whistleblowing_reports.concerns_cco IS
    '交的人勾了「这件事涉及 CCO」(Q13):真 → 只有持 data.view_whistleblowing_escalated 的人读得到,cco 读不到。';

CREATE OR REPLACE FUNCTION public.guard_whistleblowing_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'WHISTLEBLOWING_IMMUTABLE';
END;
$function$;
CREATE TRIGGER trg_whistleblowing_reports_immutable
    BEFORE UPDATE OR DELETE ON public.whistleblowing_reports
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_whistleblowing_write();
CREATE TRIGGER trg_whistleblowing_reports_truncate
    BEFORE TRUNCATE ON public.whistleblowing_reports
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.whistleblowing_reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY "whistleblowing_reports select by its reader code" ON public.whistleblowing_reports
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (whistleblowing_report_readable(concerns_cco));
REVOKE ALL ON public.whistleblowing_reports FROM authenticated, anon;
GRANT SELECT ON public.whistleblowing_reports TO authenticated;

-- ── 3 · whistleblowing_updates(镜像原样:db/tables/whistleblowing_updates.sql)──
-- db/tables/whistleblowing_updates.sql
-- ESG-2(Tim 2026-10-31 Q14):【一件举报之后的事】(只追加)—— 收到确认(acknowledged)· 调查中(investigating)· 结案(closed,带结论)。
--   一件举报现在的状态 = 它最后一行(id 是 identity,排得出先后);一行都没有 = 「已收到」(received)。结案之后不再追加。
--   【谁写】读得到那件举报的人(whistleblowing_report_update,同一个判据 whistleblowing_report_readable)。【谁读】同一批人;
--     交的人只经 my_concerns() 读到【状态与时刻】,读不到读者写的说明。不改、不删;不进变更记录(理由同 whistleblowing_reports)。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.whistleblowing_updates (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_id    uuid NOT NULL REFERENCES public.whistleblowing_reports (id),
    status       text NOT NULL CHECK (status IN ('acknowledged', 'investigating', 'closed')),
    note         text NOT NULL CHECK (length(btrim(note)) BETWEEN 1 AND 10000),
    recorded_at  timestamptz NOT NULL DEFAULT now(),
    recorded_by  uuid NOT NULL
);
CREATE INDEX whistleblowing_updates_report_id_rel ON public.whistleblowing_updates (report_id, id);
COMMENT ON TABLE public.whistleblowing_updates IS
    'ESG-2(Q14):一件举报之后的状态(收到确认 · 调查中 · 结案,各带一句说明),只追加;最后一行是现在的状态,没有行 = 已收到。读与写都按那件举报自己的读码。不进变更记录。';
CREATE TRIGGER trg_whistleblowing_updates_immutable
    BEFORE UPDATE OR DELETE ON public.whistleblowing_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_whistleblowing_write();
CREATE TRIGGER trg_whistleblowing_updates_truncate
    BEFORE TRUNCATE ON public.whistleblowing_updates
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
ALTER TABLE public.whistleblowing_updates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "whistleblowing_updates select by its report's reader code" ON public.whistleblowing_updates
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM whistleblowing_reports r WHERE r.id = report_id AND whistleblowing_report_readable(r.concerns_cco)));
REVOKE ALL ON public.whistleblowing_updates FROM authenticated, anon;
GRANT SELECT ON public.whistleblowing_updates TO authenticated;

-- ── 3 · incident_days_lost_corrections(镜像原样:db/tables/incident_days_lost_corrections.sql)──
-- db/tables/incident_days_lost_corrections.sql
-- ESG-2(Tim 2026-10-31 Q7):【误工天数的更正】—— 误工天数是健康数据(data.view_health,或受伤的那名员工本人),所以它的更正不能住在
--   incident_updates 里(那张表的 new_value 对每一个持 module.safety.view 的人都可读)。一行 = 一次带理由的更正;最后一行说了算(id 是 identity)。
--   【谁写】持 module.safety.edit 的人(与记下这件事故、记下原来那个数的是同一批人),经 record_incident_days_lost_correction:
--     只在有受伤的人的事故上;理由必填;与现在的值相同按名拒。
--   【谁读】持 data.view_health 的人,或受伤的那名员工本人 —— 与 incidents_masked 里 days_lost 那句 CASE 同一个判据。
--   【现在的值】incident_rows.days_lost = 最后一次更正,没有更正就是原来那个数(遮蔽照旧);安全率页按同一个值算误工天数与误工事故。
--   不改、不删。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.incident_days_lost_corrections (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    incident_id  uuid NOT NULL REFERENCES public.incidents (id),
    days_lost    numeric NOT NULL CHECK (days_lost >= 0),
    reason       text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 2000),
    recorded_at  timestamptz NOT NULL DEFAULT now(),
    recorded_by  uuid DEFAULT auth.uid()
);
CREATE INDEX incident_days_lost_corrections_incident_id_rel ON public.incident_days_lost_corrections (incident_id, id);
COMMENT ON TABLE public.incident_days_lost_corrections IS
    'ESG-2(Q7):一件事故误工天数的更正(带理由,最后一次说了算)。健康数据:读要 data.view_health 或就是受伤的那名员工本人。写只经 record_incident_days_lost_correction(module.safety.edit)。不改、不删。';
CREATE OR REPLACE FUNCTION public.guard_incident_days_lost_correction_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'INCIDENT_IMMUTABLE';
END;
$function$;
CREATE TRIGGER trg_incident_days_lost_corrections_immutable
    BEFORE UPDATE OR DELETE ON public.incident_days_lost_corrections
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_incident_days_lost_correction_write();
CREATE TRIGGER trg_incident_days_lost_corrections_truncate
    BEFORE TRUNCATE ON public.incident_days_lost_corrections
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
ALTER TABLE public.incident_days_lost_corrections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "incident_days_lost_corrections select by health or self" ON public.incident_days_lost_corrections
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('data.view_health'::text))
        OR incident_injured_is_caller(incident_id));
REVOKE ALL ON public.incident_days_lost_corrections FROM authenticated, anon;
GRANT SELECT ON public.incident_days_lost_corrections TO authenticated;

-- ── 4 · 读新表的函数(镜像原样)──
-- db/functions/esg_set_grid_factor.sql
-- ESG-2(Tim 2026-10-31 Q1 · Q2 · Q9):设定某一年的电网排放因子(kg CO2/kWh)。要 action.manage_esg(admin · cco · cfo)。
--   同一年第一次 = 第一个版本(理由可空);那一年已经有了 = 更正,是一个【新版本】,理由必填(Q2);与那一年现在的值和出处都一样 → 按名拒。
--   按名拒:ESG_GRID_FACTOR_YEAR_INVALID(2000–2100 之外或空)· ESG_GRID_FACTOR_VALUE_INVALID(不是 0 < 值 < 5)·
--     ESG_GRID_FACTOR_SOURCE_REQUIRED · ESG_GRID_FACTOR_REASON_REQUIRED|<年>(更正没写理由)· ESG_GRID_FACTOR_NO_CHANGE|<年>。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_set_grid_factor(p_year integer, p_kg_co2_per_kwh numeric, p_source text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cur grid_emission_factors%ROWTYPE;
    v_id  bigint;
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF p_year IS NULL OR p_year NOT BETWEEN 2000 AND 2100 THEN
        RAISE EXCEPTION 'ESG_GRID_FACTOR_YEAR_INVALID';
    END IF;
    IF p_kg_co2_per_kwh IS NULL OR p_kg_co2_per_kwh <= 0 OR p_kg_co2_per_kwh >= 5 THEN
        RAISE EXCEPTION 'ESG_GRID_FACTOR_VALUE_INVALID';
    END IF;
    IF p_source IS NULL OR btrim(p_source) = '' THEN
        RAISE EXCEPTION 'ESG_GRID_FACTOR_SOURCE_REQUIRED';
    END IF;
    SELECT * INTO v_cur FROM grid_emission_factors g WHERE g.factor_year = p_year ORDER BY g.id DESC LIMIT 1;
    IF FOUND THEN
        IF v_cur.kg_co2_per_kwh = p_kg_co2_per_kwh AND v_cur.source = btrim(p_source) THEN
            RAISE EXCEPTION 'ESG_GRID_FACTOR_NO_CHANGE|%', p_year;
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'ESG_GRID_FACTOR_REASON_REQUIRED|%', p_year;
        END IF;
    END IF;
    INSERT INTO grid_emission_factors (factor_year, kg_co2_per_kwh, source, reason, recorded_by)
    VALUES (p_year, p_kg_co2_per_kwh, btrim(p_source), NULLIF(btrim(COALESCE(p_reason, '')), ''), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id, 'factor_year', p_year, 'correction', v_cur.id IS NOT NULL);
END;
$function$;
-- db/functions/grid_emission_factor_for.sql
-- ESG-2(Tim 2026-10-31 Q2 (a)):某一年【用哪一个】电网排放因子 —— 那一年有就用那一年的,没有就用【更早最近的一年】;
--   一年里取最后一个版本(id 最大 —— identity 记录先后)。比所有已填年份都早 → 零行(「没设因子」,从不读成 0)。
--   回 factor_year(真正用的那一年,与 p_year 不同时页面照直说)与值。读的是一张人人可读的表,不必另判。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.grid_emission_factor_for(p_year integer)
 RETURNS TABLE(factor_year integer, kg_co2_per_kwh numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT g.factor_year, g.kg_co2_per_kwh
      FROM grid_emission_factors g
     WHERE g.factor_year <= p_year
     ORDER BY g.factor_year DESC, g.id DESC
     LIMIT 1;
$function$;
-- db/functions/esg_scope2_bills.sql
-- ESG-2(Tim 2026-10-31 Q2 · Q3):每一张电费单的 Scope 2(按地点法)—— kWh × 那张单的年份的电网因子 ÷ 1000 = tCO2(EMA 的因子只含 CO2)。
--   【一张单的年份】= 账期结束那一天的年份(电费单是在账期结束时开的);那一年没有因子就用更早最近的一年(grid_emission_factor_for),
--     factor_year 照直交回,页面在它与 bill_year 不同时说「用的是 <年> 的因子」;一个都用不上 → factor_year / tco2 为空 =「没设因子」(Q1)。
--   【哪些单】与能耗强度页同一个判据:electricity_allocations_masked 里、不在 electricity_allocation_reversals_masked 里的(冲回的不算)。
--     kWh 那张视图不遮(它只遮金额)。【一份实现,两个读者】能耗强度页的那一列与 esg_scope2_monthly(月份按天摊的那一份)。
--   【门】与能耗强度页同一对码(module.finance.view 或 module.processing.view);都不持 → 按名拒(零行会把「受限」读成「没有电费单」)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_scope2_bills()
 RETURNS TABLE(allocation_id uuid, period_from date, period_to date, invoice_ref text, bill_kwh numeric, bill_year integer, factor_year integer, kg_co2_per_kwh numeric, tco2 numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT has_any_permission(ARRAY['module.finance.view', 'module.processing.view']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;
    RETURN QUERY
    SELECT a.id, a.period_from, a.period_to, a.invoice_ref, a.bill_kwh::numeric,
           EXTRACT(year FROM a.period_to)::integer,
           f.factor_year, f.kg_co2_per_kwh,
           CASE WHEN f.kg_co2_per_kwh IS NULL THEN NULL ELSE round(a.bill_kwh::numeric * f.kg_co2_per_kwh / 1000, 6) END
      FROM electricity_allocations_masked a
      LEFT JOIN LATERAL grid_emission_factor_for(EXTRACT(year FROM a.period_to)::integer) f ON true
     WHERE NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals_masked r WHERE r.allocation_id = a.id)
     ORDER BY a.period_from DESC, a.id;
END;
$function$;
-- db/functions/esg_scope2_monthly.sql
-- ESG-2(Tim 2026-10-31 Q3):某一年每个日历月的 kWh 与 Scope 2 —— 【按天摊】(apportioned by days):一张单的 kWh 与 tCO2 按它的账期里
--   落在那个月的天数 ÷ 账期总天数 分到那个月(SP 的账期按抄表日,不是整月)。每张单的 tCO2 先按它自己那一年的因子算好再摊
--   (esg_scope2_bills,一份实现),所以各月之和 = 各单之和,不会因为摊而多出或少掉一点。
--   一个月里有任何一张单没设因子 → 那个月的 tco2 为空、factor_missing 为真(不把一部分当成全部);bills = 有几张单落进这个月。
--   一个月没有任何单 → kwh 0、bills 0:页面说「没有电费单覆盖这个月」,不说「0 tCO2」。门与 esg_scope2_bills 相同,这里先判一次(不靠被读的那一支恰好被求值)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_scope2_monthly(p_year integer)
 RETURNS TABLE(month date, kwh numeric, tco2 numeric, factor_missing boolean, bills integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    IF NOT has_any_permission(ARRAY['module.finance.view', 'module.processing.view']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;
    RETURN QUERY
    WITH b AS (
        SELECT s.allocation_id, s.period_from, s.period_to, s.bill_kwh, s.tco2,
               (s.period_to - s.period_from + 1)::numeric AS days
          FROM esg_scope2_bills() s
         WHERE s.period_from <= make_date(p_year, 12, 31) AND s.period_to >= make_date(p_year, 1, 1)
    ), m AS (
        SELECT make_date(p_year, k, 1) AS m_from, (make_date(p_year, k, 1) + interval '1 month - 1 day')::date AS m_to
          FROM generate_series(1, 12) k
    ), share AS (
        SELECT m.m_from, b.allocation_id, b.tco2 IS NULL AS missing,
               (LEAST(b.period_to, m.m_to) - GREATEST(b.period_from, m.m_from) + 1)::numeric / b.days AS frac,
               b.bill_kwh, b.tco2
          FROM m JOIN b ON b.period_from <= m.m_to AND b.period_to >= m.m_from
    )
    SELECT m.m_from,
           COALESCE(round(sum(s.bill_kwh * s.frac), 3), 0),
           CASE WHEN bool_or(s.missing) THEN NULL ELSE COALESCE(round(sum(s.tco2 * s.frac), 6), 0) END,
           COALESCE(bool_or(s.missing), false),
           count(s.allocation_id)::integer
      FROM m LEFT JOIN share s ON s.m_from = m.m_from
     GROUP BY m.m_from
     ORDER BY m.m_from;
END;
$function$;
-- db/functions/esg_set_standard_hours.sql
-- ESG-2(Tim 2026-10-31 Q4 · Q9):设定一个工作日算几个小时(安全率的工时分母)。要 action.manage_esg(admin · cco · cfo)。
--   按名拒:ESG_STANDARD_HOURS_INVALID(空、≤ 0 或 > 24)· ESG_STANDARD_HOURS_NO_CHANGE。修改史在变更记录里(esg_settings 绑着)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_set_standard_hours(p_hours numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old numeric;
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF p_hours IS NULL OR p_hours <= 0 OR p_hours > 24 THEN
        RAISE EXCEPTION 'ESG_STANDARD_HOURS_INVALID';
    END IF;
    SELECT standard_hours_per_day INTO v_old FROM esg_settings WHERE id;
    IF v_old IS NOT DISTINCT FROM p_hours THEN
        RAISE EXCEPTION 'ESG_STANDARD_HOURS_NO_CHANGE';
    END IF;
    UPDATE esg_settings SET standard_hours_per_day = p_hours, updated_by = auth.uid() WHERE id;
    RETURN jsonb_build_object('standard_hours_per_day', p_hours, 'previous', v_old);
END;
$function$;
-- db/functions/esg_safety_rates.sql
-- ESG-2(Tim 2026-10-31 Q4 · Q5 · Q6 · Q7):某一年每个月的误工事故、误工天数与误工事故频率(LTIFR),外加一行【年初至今】(month 为空)。
--   【误工事故】(Q5)种类(更正过的)是 injury、受伤的是一名【员工】、误工天数(最后一次更正,没有更正就是原来那个数 —— Q7)> 0;
--     按事故的新加坡日期归月。受伤的不是员工(只写了名字)的另数(nonemployee_injuries,同样要误工天数 > 0),不进率。
--   【工时】(Q4)那个月的考勤期(attendance_periods)里每一行员工:
--     (在职期间的工作日 − 那个月批准的请假天数,各种假都算)× esg_settings.standard_hours_per_day + 三列加班工时。
--     在职期间 = GREATEST(入职日, 月初) .. LEAST(离职日或月末, 月末)(与 complete_attendance_period 填 active_from / active_to 同一个式子);
--     工作日与请假天数都用 calculate_leave_days(周一至周五、扣新加坡公共假期、半天 0.5 —— 与请假模块同一支)。
--   【一个月什么时候算得出】hours_state:no_period(那个月没有考勤期)· incomplete(考勤期里不是每一行都记过 —— lines_recorded / lines_total)·
--     hours_not_set(标准日工时没设)· complete。只有 complete 的月份有工时与率;年初至今那一行只有每一个月都 complete 才有(Q4)。
--   【率】LTIFR = 误工事故 × 1,000,000 ÷ 工时(新加坡 MOM 的口径,Q5)。
--   【遮蔽】(Q6)误工事故、误工天数、非员工受伤与率要 data.view_health;不持的人这几列为空、injury_visible 为假(页面画「受限」)。
--     工时是一个合计,持 module.safety.view 的人都读得到。【门】module.safety.view,不持 → 按名拒。
--   【哪几个月】过去的年份 12 个月;今年到新加坡的这个月为止;将来的年份零行。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_safety_rates(p_year integer)
 RETURNS TABLE(month date, hours_state text, lines_recorded integer, lines_total integer, hours_worked numeric, injury_visible boolean, lti integer, days_lost numeric, nonemployee_injuries integer, ltifr numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    v_today   date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_std     numeric;
    v_health  boolean;
    v_last    integer;
    v_all_ok  boolean := true;
    v_rec     integer := 0;
    v_tot     integer := 0;
    v_hours   numeric := 0;
    v_lti     integer := 0;
    v_days    numeric := 0;
    v_non     integer := 0;
    r         record;
BEGIN
    PERFORM require_permission('module.safety.view');
    IF p_year IS NULL OR p_year > EXTRACT(year FROM v_today)::integer THEN
        RETURN;
    END IF;
    v_last := CASE WHEN p_year = EXTRACT(year FROM v_today)::integer THEN EXTRACT(month FROM v_today)::integer ELSE 12 END;
    SELECT s.standard_hours_per_day INTO v_std FROM esg_settings s WHERE s.id;
    v_health := has_permission('data.view_health');

    FOR r IN
        WITH mm AS (
            SELECT make_date(p_year, k, 1) AS m_from, (make_date(p_year, k, 1) + interval '1 month - 1 day')::date AS m_to
              FROM generate_series(1, v_last) k
        ), lines AS (
            SELECT mm.m_from, l.recorded_at, e.hire_date, e.separation_date,
                   l.ot_normal_hours + l.ot_rest_day_hours + l.ot_public_holiday_hours AS ot,
                   GREATEST(e.hire_date, mm.m_from) AS a_from,
                   LEAST(COALESCE(e.separation_date, mm.m_to), mm.m_to) AS a_to,
                   l.employee_id, mm.m_to
              FROM mm
              JOIN attendance_periods p ON p.period_month = mm.m_from
              JOIN attendance_lines l ON l.period_id = p.id
              JOIN employees e ON e.id = l.employee_id
        ), per_line AS (
            SELECT ln.m_from, ln.recorded_at, ln.ot,
                   GREATEST(
                       CASE WHEN ln.a_from > ln.a_to THEN 0 ELSE calculate_leave_days(ln.a_from, ln.a_to) END
                       - COALESCE((SELECT sum(calculate_leave_days(
                                        GREATEST(lr.start_date, ln.m_from), LEAST(lr.end_date, ln.m_to),
                                        lr.start_half_day AND lr.start_date >= ln.m_from,
                                        lr.end_half_day AND lr.end_date <= ln.m_to))
                                     FROM leave_requests lr
                                    WHERE lr.employee_id = ln.employee_id AND lr.status = 'approved' AND lr.deleted_at IS NULL
                                      AND lr.start_date <= ln.m_to AND lr.end_date >= ln.m_from), 0),
                       0) AS work_days
              FROM lines ln
        ), hours AS (
            SELECT pl.m_from, count(*)::integer AS tot, count(pl.recorded_at)::integer AS rec,
                   sum(pl.work_days * COALESCE(v_std, 0) + pl.ot) AS h
              FROM per_line pl GROUP BY pl.m_from
        ), inj AS (
            SELECT date_trunc('month', c.occurred_on)::date AS m_from, i.injured_employee_id,
                   COALESCE((SELECT d.days_lost FROM incident_days_lost_corrections d WHERE d.incident_id = i.id ORDER BY d.id DESC LIMIT 1),
                            i.days_lost) AS dl
              FROM incident_current_all c
              JOIN incidents i ON i.id = c.id
             WHERE c.kind_code = 'injury'
               AND c.occurred_on BETWEEN make_date(p_year, 1, 1) AND make_date(p_year, v_last, 1) + interval '1 month - 1 day'
        )
        SELECT mm.m_from,
               EXISTS (SELECT 1 FROM attendance_periods p WHERE p.period_month = mm.m_from) AS has_period,
               COALESCE(h.rec, 0) AS rec, COALESCE(h.tot, 0) AS tot, h.h,
               (SELECT count(*) FROM inj WHERE inj.m_from = mm.m_from AND inj.injured_employee_id IS NOT NULL AND inj.dl > 0)::integer AS lti,
               COALESCE((SELECT sum(inj.dl) FROM inj WHERE inj.m_from = mm.m_from AND inj.injured_employee_id IS NOT NULL AND inj.dl > 0), 0) AS dl,
               (SELECT count(*) FROM inj WHERE inj.m_from = mm.m_from AND inj.injured_employee_id IS NULL AND inj.dl > 0)::integer AS non
          FROM mm LEFT JOIN hours h ON h.m_from = mm.m_from
         ORDER BY mm.m_from
    LOOP
        month := r.m_from;
        lines_recorded := r.rec;
        lines_total := r.tot;
        hours_state := CASE WHEN NOT r.has_period THEN 'no_period'
                            WHEN r.tot = 0 OR r.rec < r.tot THEN 'incomplete'
                            WHEN v_std IS NULL THEN 'hours_not_set'
                            ELSE 'complete' END;
        hours_worked := CASE WHEN hours_state = 'complete' THEN round(r.h, 2) END;
        injury_visible := v_health;
        lti := CASE WHEN v_health THEN r.lti END;
        days_lost := CASE WHEN v_health THEN r.dl END;
        nonemployee_injuries := CASE WHEN v_health THEN r.non END;
        ltifr := CASE WHEN v_health AND hours_state = 'complete' AND r.h > 0 THEN round(r.lti * 1000000 / r.h, 2) END;
        v_all_ok := v_all_ok AND hours_state = 'complete';
        v_rec := v_rec + r.rec; v_tot := v_tot + r.tot;
        v_hours := v_hours + COALESCE(r.h, 0);
        v_lti := v_lti + r.lti; v_days := v_days + r.dl; v_non := v_non + r.non;
        RETURN NEXT;
    END LOOP;

    -- 年初至今:每一个月都 complete 才有工时与率(Q4)
    month := NULL;
    lines_recorded := v_rec;
    lines_total := v_tot;
    hours_state := CASE WHEN v_all_ok THEN 'complete' ELSE 'incomplete' END;
    hours_worked := CASE WHEN v_all_ok THEN round(v_hours, 2) END;
    injury_visible := v_health;
    lti := CASE WHEN v_health THEN v_lti END;
    days_lost := CASE WHEN v_health THEN v_days END;
    nonemployee_injuries := CASE WHEN v_health THEN v_non END;
    ltifr := CASE WHEN v_health AND v_all_ok AND v_hours > 0 THEN round(v_lti * 1000000 / v_hours, 2) END;
    RETURN NEXT;
END;
$function$;
-- db/functions/record_incident_days_lost_correction.sql
-- ESG-2(Tim 2026-10-31 Q7):更正一件事故的误工天数(带理由;最后一次更正说了算)。与 record_incident_update 的 correction 同一套规矩:
--   要 module.safety.edit;关闭之后不收(INCIDENT_CLOSED|<编号>);理由必填(INCIDENT_CORRECTION_REASON_REQUIRED);
--   与现在的值相同(INCIDENT_CORRECTION_NO_CHANGE|days_lost);值要是 ≥ 0 的数(INCIDENT_DAYS_LOST_INVALID)。
--   另加一条:只在【有受伤的人】的事故上(INCIDENT_INJURY_NEEDS_PERSON —— 与 incidents_injury_needs_person 那条约束同一句)。
--   存进 incident_days_lost_corrections(健康数据,读要 data.view_health 或受伤的那名员工本人),不进 incident_updates(那张表人人可读)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.record_incident_days_lost_correction(p_incident_id uuid, p_days_lost numeric, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_i   incidents%ROWTYPE;
    v_cur numeric;
    v_id  bigint;
BEGIN
    PERFORM require_permission('module.safety.edit');
    SELECT * INTO v_i FROM incidents WHERE id = p_incident_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', p_incident_id;
    END IF;
    IF EXISTS (SELECT 1 FROM incident_updates u WHERE u.incident_id = v_i.id AND u.kind = 'closed') THEN
        RAISE EXCEPTION 'INCIDENT_CLOSED|%', v_i.code;
    END IF;
    IF v_i.injured_employee_id IS NULL AND v_i.injured_person_name IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_INJURY_NEEDS_PERSON';
    END IF;
    IF p_days_lost IS NULL OR p_days_lost < 0 THEN
        RAISE EXCEPTION 'INCIDENT_DAYS_LOST_INVALID';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_REASON_REQUIRED';
    END IF;
    v_cur := COALESCE((SELECT d.days_lost FROM incident_days_lost_corrections d WHERE d.incident_id = v_i.id ORDER BY d.id DESC LIMIT 1),
                      v_i.days_lost);
    IF v_cur IS NOT DISTINCT FROM p_days_lost THEN
        RAISE EXCEPTION 'INCIDENT_CORRECTION_NO_CHANGE|days_lost';
    END IF;
    INSERT INTO incident_days_lost_corrections (incident_id, days_lost, reason, recorded_by)
    VALUES (v_i.id, p_days_lost, btrim(p_reason), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('correction_id', v_id, 'incident_id', v_i.id);
END;
$function$;
-- db/functions/required_training_save.sql
-- ESG-2(Tim 2026-10-31 Q8 · Q9):新增或改一门必修培训(p_id 空 = 新增)。要 action.manage_esg(admin · cco · cfo)。
--   按名拒:REQUIRED_TRAINING_NAME_REQUIRED · REQUIRED_TRAINING_CATEGORY_INVALID · REQUIRED_TRAINING_VALIDITY_INVALID(1–240 个月之外)·
--     REQUIRED_TRAINING_APPLIES_INVALID · REQUIRED_TRAINING_POSITIONS_REQUIRED(选了「点名的岗位」却一个都没选)·
--     REQUIRED_TRAINING_POSITION_NOT_FOUND|<id> · REQUIRED_TRAINING_NAME_TAKEN|<名字>(在用的清单里同名)·
--     REQUIRED_TRAINING_NOT_FOUND · REQUIRED_TRAINING_RETIRED(停用了的改不了)。不选岗位的范围存一个空数组。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.required_training_save(p_id uuid, p_name text, p_category text, p_validity_months integer, p_applies_to text, p_position_ids uuid[] DEFAULT '{}'::uuid[], p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_pos  uuid[] := CASE WHEN p_applies_to = 'positions' THEN COALESCE(p_position_ids, '{}'::uuid[]) ELSE '{}'::uuid[] END;
    v_bad  uuid;
    v_id   uuid;
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF p_name IS NULL OR btrim(p_name) = '' THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_NAME_REQUIRED';
    END IF;
    IF p_category IS NOT NULL AND p_category NOT IN ('induction','safety','compliance','cybersecurity','technical','leadership','other') THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_CATEGORY_INVALID';
    END IF;
    IF p_validity_months IS NOT NULL AND p_validity_months NOT BETWEEN 1 AND 240 THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_VALIDITY_INVALID';
    END IF;
    IF p_applies_to IS NULL OR p_applies_to NOT IN ('everyone','office','shopfloor','positions') THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_APPLIES_INVALID';
    END IF;
    IF p_applies_to = 'positions' AND cardinality(v_pos) = 0 THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_POSITIONS_REQUIRED';
    END IF;
    SELECT x INTO v_bad FROM unnest(v_pos) x WHERE NOT EXISTS (SELECT 1 FROM positions p WHERE p.id = x) LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_POSITION_NOT_FOUND|%', v_bad;
    END IF;
    IF EXISTS (SELECT 1 FROM required_trainings t WHERE t.retired_at IS NULL AND lower(btrim(t.name)) = lower(btrim(p_name))
                AND t.id IS DISTINCT FROM p_id) THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_NAME_TAKEN|%', btrim(p_name);
    END IF;
    IF p_id IS NULL THEN
        INSERT INTO required_trainings (name, category, validity_months, applies_to, position_ids, notes, created_by, updated_by)
        VALUES (btrim(p_name), p_category, p_validity_months, p_applies_to, v_pos, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid(), auth.uid())
        RETURNING id INTO v_id;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM required_trainings t WHERE t.id = p_id) THEN
            RAISE EXCEPTION 'REQUIRED_TRAINING_NOT_FOUND';
        END IF;
        IF EXISTS (SELECT 1 FROM required_trainings t WHERE t.id = p_id AND t.retired_at IS NOT NULL) THEN
            RAISE EXCEPTION 'REQUIRED_TRAINING_RETIRED';
        END IF;
        UPDATE required_trainings
           SET name = btrim(p_name), category = p_category, validity_months = p_validity_months, applies_to = p_applies_to,
               position_ids = v_pos, notes = NULLIF(btrim(COALESCE(p_notes, '')), ''), updated_by = auth.uid()
         WHERE id = p_id
        RETURNING id INTO v_id;
    END IF;
    RETURN jsonb_build_object('id', v_id);
END;
$function$;
-- db/functions/required_training_retire.sql
-- ESG-2(Tim 2026-10-31 Q8):停用一门必修培训 —— 从覆盖里拿掉,挂着它的培训记录照旧在(不删行)。要 action.manage_esg。
--   按名拒:REQUIRED_TRAINING_NOT_FOUND · REQUIRED_TRAINING_RETIRED(已经停用)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.required_training_retire(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF NOT EXISTS (SELECT 1 FROM required_trainings t WHERE t.id = p_id) THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_NOT_FOUND';
    END IF;
    IF EXISTS (SELECT 1 FROM required_trainings t WHERE t.id = p_id AND t.retired_at IS NOT NULL) THEN
        RAISE EXCEPTION 'REQUIRED_TRAINING_RETIRED';
    END IF;
    UPDATE required_trainings SET retired_at = now(), retired_by = auth.uid(), updated_by = auth.uid() WHERE id = p_id;
    RETURN jsonb_build_object('id', p_id);
END;
$function$;
-- db/functions/esg_training_status.sql
-- ESG-2(Tim 2026-10-31 Q8):【谁的哪一门必修培训是什么状态】—— 每一门在用的必修培训 × 每一位它适用的在职员工,一行。
--   适用:everyone 全体 · office / shopfloor 按 employees.work_category · positions 按 employees.position_id ∈ position_ids;
--     在职 = 没有软删、employment_status 不是 separated。
--   这一位的那一门取【最好的一条】挂着它的培训记录(没删的):到期日 = 记录自己的 expiry_date,没写而这一门有有效期 → completed_date + 有效期,
--     两样都没有 → 不过期(最好);有到期日的取最晚的那一条。
--   status:valid(不过期,或 90 天以外)· expiring(90 天内到期;days_remaining ≤ 30 页面标紧急 —— 与 hr_alerts 同一组窗口)·
--     expired(已过期)· missing(一条挂着它的记录都没有)。今天 = 新加坡的今天。
--   【门】module.hr.view(培训记录的读码);不持 → 按名拒。【一份实现,两个读者】培训合规页的人表与 esg_training_coverage 的合计。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_training_status()
 RETURNS TABLE(required_training_id uuid, training_name text, employee_id uuid, employee_code text, employee_name text, status text, training_record_id uuid, completed_date date, expiry_date date, days_remaining integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
BEGIN
    PERFORM require_permission('module.hr.view');
    RETURN QUERY
    WITH rt AS (
        SELECT t.* FROM required_trainings t WHERE t.retired_at IS NULL
    ), who AS (
        SELECT rt.id AS rt_id, rt.name AS rt_name, rt.validity_months, e.id AS e_id, e.code AS e_code,
               COALESCE(e.preferred_name, e.legal_name) AS e_name
          FROM rt
          JOIN employees e ON e.deleted_at IS NULL AND e.employment_status <> 'separated'
         WHERE rt.applies_to = 'everyone'
            OR (rt.applies_to IN ('office', 'shopfloor') AND e.work_category = rt.applies_to)
            OR (rt.applies_to = 'positions' AND e.position_id = ANY (rt.position_ids))
    ), best AS (
        SELECT DISTINCT ON (w.rt_id, w.e_id) w.rt_id, w.e_id, r.id AS rec_id, r.completed_date,
               COALESCE(r.expiry_date, CASE WHEN w.validity_months IS NOT NULL
                                            THEN (r.completed_date + make_interval(months => w.validity_months))::date END) AS exp
          FROM who w
          JOIN training_records r ON r.employee_id = w.e_id AND r.required_training_id = w.rt_id AND r.deleted_at IS NULL
         ORDER BY w.rt_id, w.e_id,
                  (COALESCE(r.expiry_date, CASE WHEN w.validity_months IS NOT NULL
                                                THEN (r.completed_date + make_interval(months => w.validity_months))::date END)) DESC NULLS FIRST,
                  r.completed_date DESC, r.id
    )
    SELECT w.rt_id, w.rt_name, w.e_id, w.e_code, w.e_name,
           CASE WHEN b.rec_id IS NULL THEN 'missing'
                WHEN b.exp IS NULL THEN 'valid'
                WHEN b.exp < v_today THEN 'expired'
                WHEN b.exp - v_today <= 90 THEN 'expiring'
                ELSE 'valid' END AS status,
           b.rec_id, b.completed_date, b.exp,
           CASE WHEN b.exp IS NULL THEN NULL ELSE (b.exp - v_today) END
      FROM who w
      LEFT JOIN best b ON b.rt_id = w.rt_id AND b.e_id = w.e_id
     ORDER BY w.rt_name, w.e_code;
END;
$function$;
-- db/functions/esg_training_coverage.sql
-- ESG-2(Tim 2026-10-31 Q8):每一门在用的必修培训的覆盖 —— 适用几人、有效几人(含快到期)、快到期几人、已过期几人、没有记录几人。
--   覆盖率 = (有效 + 快到期)÷ 适用(快到期仍然有效)。逐人的判定只在 esg_training_status 里(这里只是数它),门也由它判(module.hr.view)。
--   门自己先判一次(module.hr.view,不持 → 按名拒),不靠被读的那一支恰好被求值。
--   一门一个适用的人都没有 → applicable 0,页面说「没有适用的在职员工」,不画一个 0%。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_training_coverage()
 RETURNS TABLE(required_training_id uuid, name text, category text, validity_months integer, applies_to text, position_ids uuid[], applicable integer, valid integer, expiring integer, expired integer, missing integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    PERFORM require_permission('module.hr.view');
    RETURN QUERY
    WITH s AS (SELECT * FROM esg_training_status())
    SELECT t.id, t.name, t.category, t.validity_months, t.applies_to, t.position_ids,
           count(s.employee_id)::integer,
           count(*) FILTER (WHERE s.status = 'valid')::integer,
           count(*) FILTER (WHERE s.status = 'expiring')::integer,
           count(*) FILTER (WHERE s.status = 'expired')::integer,
           count(*) FILTER (WHERE s.status = 'missing')::integer
      FROM required_trainings t
      LEFT JOIN s ON s.required_training_id = t.id
     WHERE t.retired_at IS NULL
     GROUP BY t.id
     ORDER BY t.name;
END;
$function$;
-- db/functions/company_policy_record.sql
-- ESG-2(Tim 2026-10-31 Q9 · Q10):登记一份公司制度,或它的一个新版本(p_supersedes_id = 它取代的那一版)。要 action.manage_esg(admin · cco · cfo)。
--   新版本:被取代的那一版必须还是「现在」的那一版(COMPANY_POLICY_ALREADY_SUPERSEDED),版本号不能与它相同(COMPANY_POLICY_VERSION_SAME);
--     同一笔事务里给它记 superseded_at。
--   按名拒:COMPANY_POLICY_TITLE_REQUIRED · COMPANY_POLICY_VERSION_REQUIRED · COMPANY_POLICY_OWNER_NOT_FOUND(负责人要是一名没删的员工)·
--     COMPANY_POLICY_DATES_REQUIRED · COMPANY_POLICY_REVIEW_BEFORE_EFFECTIVE · COMPANY_POLICY_DOCUMENT_REQUIRED · COMPANY_POLICY_NOT_FOUND。
--   日期都必填、没有默认(AGENTS.md:决定一段时间的日期不许默认成今天)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.company_policy_record(p_supersedes_id uuid, p_title text, p_version text, p_owner_employee_id uuid, p_effective_date date, p_review_date date, p_document_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old company_policies%ROWTYPE;
    v_id  uuid;
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF p_title IS NULL OR btrim(p_title) = '' THEN
        RAISE EXCEPTION 'COMPANY_POLICY_TITLE_REQUIRED';
    END IF;
    IF p_version IS NULL OR btrim(p_version) = '' THEN
        RAISE EXCEPTION 'COMPANY_POLICY_VERSION_REQUIRED';
    END IF;
    IF p_owner_employee_id IS NULL OR NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = p_owner_employee_id AND e.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'COMPANY_POLICY_OWNER_NOT_FOUND';
    END IF;
    IF p_effective_date IS NULL OR p_review_date IS NULL THEN
        RAISE EXCEPTION 'COMPANY_POLICY_DATES_REQUIRED';
    END IF;
    IF p_review_date < p_effective_date THEN
        RAISE EXCEPTION 'COMPANY_POLICY_REVIEW_BEFORE_EFFECTIVE';
    END IF;
    IF p_document_ref IS NULL OR btrim(p_document_ref) = '' THEN
        RAISE EXCEPTION 'COMPANY_POLICY_DOCUMENT_REQUIRED';
    END IF;
    IF p_supersedes_id IS NOT NULL THEN
        SELECT * INTO v_old FROM company_policies WHERE id = p_supersedes_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COMPANY_POLICY_NOT_FOUND';
        END IF;
        IF v_old.superseded_at IS NOT NULL THEN
            RAISE EXCEPTION 'COMPANY_POLICY_ALREADY_SUPERSEDED|%', v_old.version;
        END IF;
        IF lower(btrim(v_old.version)) = lower(btrim(p_version)) THEN
            RAISE EXCEPTION 'COMPANY_POLICY_VERSION_SAME|%', v_old.version;
        END IF;
    END IF;
    INSERT INTO company_policies (title, version, owner_employee_id, effective_date, review_date, document_ref, supersedes_id, recorded_by)
    VALUES (btrim(p_title), btrim(p_version), p_owner_employee_id, p_effective_date, p_review_date, btrim(p_document_ref), p_supersedes_id, auth.uid())
    RETURNING id INTO v_id;
    IF p_supersedes_id IS NOT NULL THEN
        UPDATE company_policies SET superseded_at = now() WHERE id = p_supersedes_id;
    END IF;
    RETURN jsonb_build_object('id', v_id, 'supersedes_id', p_supersedes_id);
END;
$function$;
-- db/functions/whistleblowing_report_file.sql
-- ESG-2(Tim 2026-10-31 Q11 · Q12 · Q13):一位员工在 /me 交一件举报(「提出一个关切」)。【任何一位登录的员工】—— 要有员工档案
--   (供应商门户的账号也是 authenticated,它交不了:WHISTLEBLOWING_EMPLOYEES_ONLY)。不要任何码。
--   保密,不是匿名(Q12):存下交的人是谁(filed_by_employee_id),只有读者看得见。p_concerns_cco 必须答(是 / 否,没有默认):
--   是 → 只有持 data.view_whistleblowing_escalated 的人读(cfo),cco 读不到(Q13)。收到日 = 新加坡的今天。
--   按名拒:WHISTLEBLOWING_EMPLOYEES_ONLY · WHISTLEBLOWING_SUBJECT_REQUIRED · WHISTLEBLOWING_DETAILS_REQUIRED · WHISTLEBLOWING_CONCERNS_CCO_REQUIRED。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.whistleblowing_report_file(p_subject text, p_details text, p_concerns_cco boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp uuid := current_user_employee();
    v_id  uuid;
BEGIN
    IF auth.uid() IS NULL OR v_emp IS NULL THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_EMPLOYEES_ONLY';
    END IF;
    IF p_subject IS NULL OR btrim(p_subject) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_SUBJECT_REQUIRED';
    END IF;
    IF p_details IS NULL OR btrim(p_details) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_DETAILS_REQUIRED';
    END IF;
    IF p_concerns_cco IS NULL THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_CONCERNS_CCO_REQUIRED';
    END IF;
    INSERT INTO whistleblowing_reports (source, concerns_cco, filed_by_employee_id, received_on, subject, details, recorded_by)
    VALUES ('in_system', p_concerns_cco, v_emp, (now() AT TIME ZONE 'Asia/Singapore')::date, btrim(p_subject), btrim(p_details), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id);
END;
$function$;
-- db/functions/whistleblowing_report_record_outside.sql
-- ESG-2(Tim 2026-10-31 Q11 · Q12 · Q13):读者登记一件在【系统之外】收到的举报(电邮、信、电话、当面、别的)。
--   p_reporter_name 空 = 匿名来源(outside_anonymous;Q12 —— 「匿名来源」只出现在这里)。
--   【谁】只能登记自己读得到的那一种:p_concerns_cco = 真要 data.view_whistleblowing_escalated,假要 data.view_whistleblowing
--     (whistleblowing_report_readable —— 一个登记了就再也读不到的人不该是登记它的人)。
--   按名拒:PERMISSION_DENIED|<那个码> · WHISTLEBLOWING_CONCERNS_CCO_REQUIRED · WHISTLEBLOWING_RECEIVED_ON_REQUIRED ·
--     WHISTLEBLOWING_RECEIVED_ON_IN_FUTURE · WHISTLEBLOWING_RECEIVED_VIA_INVALID · WHISTLEBLOWING_SUBJECT_REQUIRED · WHISTLEBLOWING_DETAILS_REQUIRED。
--   收到日必填、不许默认成今天(AGENTS.md)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.whistleblowing_report_record_outside(p_received_on date, p_received_via text, p_reporter_name text, p_subject text, p_details text, p_concerns_cco boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id uuid;
BEGIN
    IF p_concerns_cco IS NULL THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_CONCERNS_CCO_REQUIRED';
    END IF;
    IF NOT whistleblowing_report_readable(p_concerns_cco) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', CASE WHEN p_concerns_cco THEN 'data.view_whistleblowing_escalated' ELSE 'data.view_whistleblowing' END;
    END IF;
    IF p_received_on IS NULL THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_RECEIVED_ON_REQUIRED';
    END IF;
    IF p_received_on > (now() AT TIME ZONE 'Asia/Singapore')::date THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_RECEIVED_ON_IN_FUTURE';
    END IF;
    IF p_received_via IS NULL OR p_received_via NOT IN ('email', 'letter', 'phone', 'in_person', 'other') THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_RECEIVED_VIA_INVALID';
    END IF;
    IF p_subject IS NULL OR btrim(p_subject) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_SUBJECT_REQUIRED';
    END IF;
    IF p_details IS NULL OR btrim(p_details) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_DETAILS_REQUIRED';
    END IF;
    INSERT INTO whistleblowing_reports (source, concerns_cco, reporter_name, received_via, received_on, subject, details, recorded_by)
    VALUES (CASE WHEN NULLIF(btrim(COALESCE(p_reporter_name, '')), '') IS NULL THEN 'outside_anonymous' ELSE 'outside_named' END,
            p_concerns_cco, NULLIF(btrim(COALESCE(p_reporter_name, '')), ''), p_received_via, p_received_on, btrim(p_subject), btrim(p_details), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id);
END;
$function$;
-- db/functions/whistleblowing_report_update.sql
-- ESG-2(Tim 2026-10-31 Q14):给一件举报追加一个状态(收到确认 · 调查中 · 结案),每一个都带一句说明。追加,不改、不删。
--   【谁】读得到那一件的人(whistleblowing_report_readable(concerns_cco));读不到的人得到的是「找不到」(WHISTLEBLOWING_NOT_FOUND)——
--     不告诉他那一件存不存在。结案之后不再收(WHISTLEBLOWING_CLOSED)。
--   按名拒:WHISTLEBLOWING_NOT_FOUND · WHISTLEBLOWING_CLOSED · WHISTLEBLOWING_STATUS_INVALID · WHISTLEBLOWING_NOTE_REQUIRED。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.whistleblowing_report_update(p_report_id uuid, p_status text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r  whistleblowing_reports%ROWTYPE;
    v_id bigint;
BEGIN
    SELECT * INTO v_r FROM whistleblowing_reports WHERE id = p_report_id;
    IF NOT FOUND OR NOT whistleblowing_report_readable(v_r.concerns_cco) THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_NOT_FOUND';
    END IF;
    IF EXISTS (SELECT 1 FROM whistleblowing_updates u WHERE u.report_id = v_r.id AND u.status = 'closed') THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_CLOSED';
    END IF;
    IF p_status IS NULL OR p_status NOT IN ('acknowledged', 'investigating', 'closed') THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_STATUS_INVALID';
    END IF;
    IF p_note IS NULL OR btrim(p_note) = '' THEN
        RAISE EXCEPTION 'WHISTLEBLOWING_NOTE_REQUIRED';
    END IF;
    INSERT INTO whistleblowing_updates (report_id, status, note, recorded_by)
    VALUES (v_r.id, p_status, btrim(p_note), auth.uid())
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('update_id', v_id, 'status', p_status);
END;
$function$;
-- db/functions/my_concerns.sql
-- ESG-2(Tim 2026-10-31 Q11 · Q13):交的人读到【自己交的那几件】的状态(/me 的「我提出的关切」)—— 标题、交的那一天、有没有标「涉及 CCO」、
--   现在的状态(最后一个追加的状态,没有 = received)与它的时刻。读者写的说明【不】给(Q13:"Filers see the status of their own reports")。
--   不经两张举报表的读策略(交的人通常不是读者);只回 filed_by_employee_id = 调用者自己的那几行。没有员工档案 → 零行。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.my_concerns()
 RETURNS TABLE(id uuid, subject text, received_on date, recorded_at timestamptz, concerns_cco boolean, status text, status_at timestamptz)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.id, r.subject, r.received_on, r.recorded_at, r.concerns_cco,
           COALESCE(u.status, 'received'), COALESCE(u.recorded_at, r.recorded_at)
      FROM whistleblowing_reports r
      LEFT JOIN LATERAL (SELECT x.status, x.recorded_at FROM whistleblowing_updates x WHERE x.report_id = r.id ORDER BY x.id DESC LIMIT 1) u ON true
     WHERE r.filed_by_employee_id = current_user_employee()
     ORDER BY r.recorded_at DESC, r.id;
$function$;

-- ── 4 · 变更记录的豁免名单换一版(两张举报表)(镜像原样:db/functions/change_log_exclusions.sql)──
-- db/functions/change_log_exclusions.sql
-- HISTORY-1(Tim 的 Q5):不挂变更记录触发器的表 —— 【唯一】的一份名单,每一条带理由。
--
-- 三处读它,所以它只能有一份:
--   · change_log_coverage_gaps() —— gate 的 changelog 那一行(线上 + 重建)与 fixture 234;
--   · scripts/check-change-log-coverage.mjs —— 构建里的静态检查,从本文件的 VALUES 里读;
--   · db/scripts/gen_change_log_bindings.py —— 生成绑定清单时跳过这几张。
-- ★ 规矩(docs/change-log.md):新建的每一张 public 表,要么在 db/views/zzz_change_log_triggers.sql
--   里有两条绑定,要么在这里有一行带理由的豁免。两者都没有,构建与 gate 都会红。
-- ★ MES-1(2026-10-06,MES-0 Q14,Tim):第二种被接受的豁免 —— 【采集层的三份日志】(收件箱 · 传输日志 · 网关中断)。
--   它们本身就是只追加的日志(守卫按名拒改与删);再记一遍是把规格 §2.1 警告的量翻一倍,而不多一个事实。
--   状态的变化记在行上(收件箱的 attempts · last_attempt_* · discarded_*)。
-- ★ MES-9b(2026-10-19,MES-9 Step 0 Q22,Tim):第九张 —— 门户下载记录(portal_document_downloads)。同一类:它本身就是一份只追加的日志
--   (守卫按名拒改、删、清空),每一行就是一个事实;再记一遍是把量翻一倍而不多一个事实。豁免 8 → 9。
-- ★ TABLE-FEATURES-3(2026-10-26,Tim Q3):第十张 —— 保存的视图(saved_views)。与 notification_reads 同一类:每个读者自己的屏幕偏好,
--   没有业务含义。豁免 9 → 10。
-- ★ ESG-2(2026-10-31,Tim Q13):第十一、十二张 —— 两张举报表(whistleblowing_reports · whistleblowing_updates)。不同的一类:
--   变更记录会把每一行的【操作人】印给持 data.view_change_log 的人(admin · cfo · auditor),那就把「谁交了举报」交了出去;
--   而这两张表本身只追加(守卫按名拒改、删、清空)、每一行自带谁在何时。举报的内容与交的人只在举报页上给它的读者。豁免 10 → 12。
CREATE OR REPLACE FUNCTION public.change_log_exclusions()
 RETURNS TABLE(table_name text, reason text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('change_log'::text, 'The change log itself; a trigger on it would record its own writes.'::text),
        ('festival_doodles', 'Home-screen holiday artwork; screen decoration with no business meaning.'),
        ('gateway_outages', 'Ingestion log (MES-1): itself an append-only record of gateway silences; logging it again doubles the volume and adds no fact.'),
        ('home_greetings', 'Home-screen greeting text; screen decoration with no business meaning.'),
        ('ingest_inbox', 'Ingestion log (MES-1): itself an append-only landing table; its status changes are recorded on the row (attempts, last attempt, discard).'),
        ('ingest_transmissions', 'Ingestion log (MES-1): itself an append-only log of every gateway call; logging it again doubles the volume and adds no fact.'),
        ('notification_reads', 'Per-viewer "seen" marks on notifications; screen state with no business meaning.'),
        ('saved_views', 'Per-user saved list views (TABLE-FEATURES-3, Tim Q3): a reader''s own screen preference with no business meaning.'),
        ('portal_document_downloads', 'Supplier portal download log (MES-9b, MES-9 Step 0 Q22): itself an append-only record of every issued document a portal user took; logging it again doubles the volume and adds no fact.'),
        ('whistleblowing_reports', 'Whistleblowing reports (ESG-2, Tim Q13): the change log prints each row''s actor to every change-history reader, which would reveal who filed a report; the table is append-only and carries its own who and when, shown only to the report''s readers.'),
        ('whistleblowing_updates', 'Whistleblowing status updates (ESG-2, Tim Q13): append-only, readable only by the report''s readers; the change log would show their content and actors to every change-history reader.'),
        ('scan_events', 'Scan log (MES-3b): itself an append-only record of every scan resolved on a page; logging it again doubles the volume and adds no fact.');
$function$;

-- ── 5 · 视图 company_policy_rows(CREATE → CREATE OR REPLACE)(镜像原样:db/views/company_policy_rows.sql)──
-- db/views/company_policy_rows.sql
-- ESG-2(Tim 2026-10-31 Q10):制度登记簿读的那一行 —— 每一个版本,加上负责人的显示标签(员工号 · 名字;标签跟着单据走,四条常设裁定之三)、
--   它是不是「现在」的那一版(没被取代)与复审是不是逾期(现在那一版的复审日早于新加坡的今天)。
--   【属主权限】行谓词 = company_policies 的读策略(有员工档案的人,或持 action.manage_esg 的人);借来的只有负责人的名字。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.

CREATE OR REPLACE VIEW public.company_policy_rows WITH (security_invoker = off) AS
 SELECT p.id,
    p.title,
    p.version,
    p.owner_employee_id,
    (e.code || ' · '::text) || COALESCE(e.preferred_name, e.legal_name) AS owner_label,
    p.effective_date,
    p.review_date,
    p.document_ref,
    p.supersedes_id,
    p.superseded_at,
    p.superseded_at IS NULL AS is_current,
    p.superseded_at IS NULL AND p.review_date < (now() AT TIME ZONE 'Asia/Singapore'::text)::date AS review_overdue,
    p.recorded_at,
    p.recorded_by
   FROM company_policies p
     JOIN employees e ON e.id = p.owner_employee_id
  WHERE current_user_employee() IS NOT NULL OR has_permission('action.manage_esg'::text);

COMMENT ON VIEW public.company_policy_rows IS
    'ESG-2(Q10):制度登记簿的每一个版本 + 负责人标签 + 是不是现在那一版 + 复审逾期。行谓词 = company_policies 的读策略(有员工档案的人,或持 action.manage_esg 的人)。';

REVOKE ALL ON public.company_policy_rows FROM authenticated, anon;
GRANT SELECT ON public.company_policy_rows TO authenticated;

-- ── 5 · 视图 whistleblowing_report_rows(CREATE → CREATE OR REPLACE)(镜像原样:db/views/whistleblowing_report_rows.sql)──
-- db/views/whistleblowing_report_rows.sql
-- ESG-2(Tim 2026-10-31 Q11 – Q14):举报登记簿读的那一行 —— 一件举报,加上交的人的显示标签(系统里交的)、现在的状态(最后一个追加的状态,
--   没有 = received)与它的时刻、追加过几次。
--   【属主权限】行谓词就是 whistleblowing_report_readable(concerns_cco):涉及 CCO 的只给持 data.view_whistleblowing_escalated 的人,
--   别的只给持 data.view_whistleblowing 的人(Q13)。交的人读自己那几件走 my_concerns(),不走这里。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.

CREATE OR REPLACE VIEW public.whistleblowing_report_rows WITH (security_invoker = off) AS
 SELECT r.id,
    r.source,
    r.concerns_cco,
    r.filed_by_employee_id,
    (e.code || ' · '::text) || COALESCE(e.preferred_name, e.legal_name) AS filed_by_label,
    r.reporter_name,
    r.received_via,
    r.received_on,
    r.subject,
    r.details,
    COALESCE(u.status, 'received'::text) AS status,
    COALESCE(u.recorded_at, r.recorded_at) AS status_at,
    ( SELECT count(*)::integer AS count
           FROM whistleblowing_updates x
          WHERE x.report_id = r.id) AS updates,
    r.recorded_at,
    r.recorded_by
   FROM whistleblowing_reports r
     LEFT JOIN employees e ON e.id = r.filed_by_employee_id
     LEFT JOIN LATERAL ( SELECT x.status,
            x.recorded_at
           FROM whistleblowing_updates x
          WHERE x.report_id = r.id
          ORDER BY x.id DESC
         LIMIT 1) u ON true
  WHERE whistleblowing_report_readable(r.concerns_cco);

COMMENT ON VIEW public.whistleblowing_report_rows IS
    'ESG-2(Q11–Q14):举报登记簿的一行 —— 举报 + 交的人标签 + 现在的状态。行谓词 = whistleblowing_report_readable(concerns_cco)(涉及 CCO 的只给 cfo 的码,别的只给 cco 的码)。';

REVOKE ALL ON public.whistleblowing_report_rows FROM authenticated, anon;
GRANT SELECT ON public.whistleblowing_report_rows TO authenticated;

-- ── 5 · 视图 incident_rows(CREATE → CREATE OR REPLACE)(镜像原样:db/views/incident_rows.sql)──
-- db/views/incident_rows.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q6 · Q10 · Q11 · Q17,Tim):事故清单与事故页读的那一行 —— 现在的值(incident_current_all)
--   加上人读的标签(种类的名字、库位、机器、负责的人、引用的停机与异常事件)与受伤的细节(经 incidents_masked,遮蔽照旧)。
--   【属主权限】行谓词就是 incidents_masked 的那一句(module.safety.view,或受伤的那名员工本人):它读 incidents_masked,
--   而那张视图里的 has_permission / current_user_employee 回答的是【调用者】(AGENTS.md:属主视图不放宽模块的门)。
--   借来的列只有【标签】(名字、编号、时刻)—— 显示标签跟着单据走(四条常设裁定之三),没有任何一列钱。
--   injury_visible:这位读者能不能读受伤的细节(data.view_health 或本人)。为假时页面说「受限」—— 不论这一件有没有受伤的记录,
--   于是"有没有人受伤"这件事本身也不会从一个空字段里漏出去。
--   ★ ESG-2(Tim 2026-10-31 Q7):days_lost 现在是【最后一次更正】(incident_days_lost_corrections),没有更正就是记下时的那个数 —— 遮蔽照旧
--     (不持 data.view_health、又不是受伤的那名员工本人 → 空);days_lost_recorded = 记下时的那个数,days_lost_corrections = 更正过几次(同样遮蔽)。
--     判据与 incidents_masked 里那句 CASE 逐字同一个(m.injured_employee_id 对看不见的人本来就是空,于是只剩 has_permission 那一半)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.

CREATE OR REPLACE VIEW public.incident_rows WITH (security_invoker = off) AS
 SELECT m.id,
    m.code,
    c.kind_code,
    k.name_en AS kind_name_en,
    k.name_zh AS kind_name_zh,
    c.occurred_at,
    c.occurred_on,
    m.location_id,
    l.code AS location_code,
    l.name AS location_name,
    m.equipment_id,
    fa.code AS equipment_code,
    fa.description AS equipment_name,
    c.duration_min,
    c.what_happened,
    c.immediate_action,
    c.responsible_employee_id,
    COALESCE((re.code || ' · '::text) || COALESCE(re.preferred_name, re.legal_name), c.responsible_name) AS responsible_label,
    c.nea_reportable,
    m.source,
    m.downtime_id,
    d.started_at AS downtime_started_at,
    m.run_event_id,
    ev.run_id AS run_event_run_id,
    pr.code AS run_event_run_code,
    ev.event_type_code AS run_event_type,
    ev.occurred_at AS run_event_occurred_at,
    m.recorded_at,
    m.recorded_by,
    c.corrections,
    c.notified_at,
    c.notified_reference,
    c.report_submitted_at,
    c.report_reference,
    c.closed_at,
    c.closed_summary,
    c.report_deadline,
    c.deadline_state,
    c.deadline_working_days,
    c.deadline_confirmed,
    has_permission('data.view_health'::text) OR COALESCE(m.injured_employee_id = current_user_employee(), false) AS injury_visible,
    m.injured_employee_id,
    (ie.code || ' · '::text) || COALESCE(ie.preferred_name, ie.legal_name) AS injured_employee_label,
    m.injured_person_name,
    m.injury_nature,
    m.injury_treatment,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(m.injured_employee_id = current_user_employee(), false) THEN COALESCE(( SELECT dc.days_lost
               FROM incident_days_lost_corrections dc
              WHERE dc.incident_id = m.id
              ORDER BY dc.id DESC
             LIMIT 1), m.days_lost)
            ELSE NULL::numeric
        END AS days_lost,
    ( SELECT count(*)::integer AS count
           FROM incident_batches b
          WHERE b.incident_id = m.id AND b.unlinked_at IS NULL) AS linked_batches,
    m.days_lost AS days_lost_recorded,
        CASE
            WHEN has_permission('data.view_health'::text) OR COALESCE(m.injured_employee_id = current_user_employee(), false) THEN ( SELECT count(*)::integer AS count
               FROM incident_days_lost_corrections dc
              WHERE dc.incident_id = m.id)
            ELSE NULL::integer
        END AS days_lost_corrections
   FROM incidents_masked m
     JOIN incident_current_all c ON c.id = m.id
     JOIN incident_kinds k ON k.code = c.kind_code
     LEFT JOIN storage_locations l ON l.id = m.location_id
     LEFT JOIN fixed_assets fa ON fa.id = m.equipment_id
     LEFT JOIN employees re ON re.id = c.responsible_employee_id
     LEFT JOIN employees ie ON ie.id = m.injured_employee_id
     LEFT JOIN equipment_downtime d ON d.id = m.downtime_id
     LEFT JOIN processing_run_events ev ON ev.id = m.run_event_id
     LEFT JOIN processing_runs pr ON pr.id = ev.run_id;

COMMENT ON VIEW public.incident_rows IS
    'MES-7b-1:事故清单与事故页的一行 —— 现在的值(更正过的)、NEA 通报 / 书面报告 / 关闭、期限与它的状态(未确认的 V19 照算、标出来)、人读的标签,以及受伤的细节(经 incidents_masked 遮蔽;injury_visible 为假时页面说「受限」)。属主权限,行谓词 = incidents_masked 的那一句(module.safety.view 或本人)。';

-- ★ 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl:postgres 建的表与视图 authenticated=arwdDxtm),
--   而一张简单的属主视图是【可以写穿的】—— 以属主身份写基表,绕开 RLS 与那几支 DEFINER 函数的码。所以先全收,再只授回 SELECT。
REVOKE ALL ON public.incident_rows FROM authenticated, anon;
GRANT SELECT ON public.incident_rows TO authenticated;

-- ── 6 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 同一串字)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.company_policies
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.company_policies
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.esg_settings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.esg_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.grid_emission_factors
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.grid_emission_factors
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.incident_days_lost_corrections
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.incident_days_lost_corrections
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.required_trainings
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.required_trainings
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 7 · 自证 ──
DO $proof$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'ESG2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT user_id, role_id, revoked_at FROM user_roles EXCEPT SELECT * FROM esg2_user_roles_before)
               UNION ALL (SELECT * FROM esg2_user_roles_before EXCEPT SELECT user_id, role_id, revoked_at FROM user_roles)) THEN
        RAISE EXCEPTION 'ESG2_PROOF|a role grant to an account changed';
    END IF;
    IF EXISTS ((SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id EXCEPT SELECT * FROM esg2_grants_before)
               EXCEPT SELECT * FROM (VALUES ('admin', 'action.manage_esg'), ('cco', 'action.manage_esg'), ('cco', 'data.view_whistleblowing'), ('cfo', 'action.manage_esg'), ('cfo', 'data.view_whistleblowing_escalated')) g(code, permission_code))
       OR EXISTS (SELECT * FROM esg2_grants_before EXCEPT SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)
       OR (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
            WHERE (r.code, rp.permission_code) IN (('admin', 'action.manage_esg'), ('cco', 'action.manage_esg'), ('cco', 'data.view_whistleblowing'), ('cfo', 'action.manage_esg'), ('cfo', 'data.view_whistleblowing_escalated'))) <> 5 THEN
        RAISE EXCEPTION 'ESG2_PROOF|role codes: expected exactly the five new grants';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE rp.permission_code IN ('data.view_whistleblowing', 'data.view_whistleblowing_escalated') AND r.code NOT IN ('cco', 'cfo')) THEN
        RAISE EXCEPTION 'ESG2_PROOF|a whistleblowing read code reached a role other than its one reader';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['esg_settings', 'grid_emission_factors', 'required_trainings', 'company_policies', 'whistleblowing_reports', 'whistleblowing_updates', 'incident_days_lost_corrections']) t
                WHERE NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass)
                   OR has_table_privilege('anon', 'public.' || t, 'SELECT')
                   OR has_table_privilege('authenticated', 'public.' || t, 'INSERT')
                   OR has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
                   OR has_table_privilege('authenticated', 'public.' || t, 'DELETE')
                   OR NOT has_table_privilege('authenticated', 'public.' || t, 'SELECT')) THEN
        RAISE EXCEPTION 'ESG2_PROOF|a new table is not read-only-under-RLS for authenticated and closed to anon';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['company_policy_rows', 'whistleblowing_report_rows', 'incident_rows']) v
                WHERE has_table_privilege('authenticated', 'public.' || v, 'INSERT') OR has_table_privilege('authenticated', 'public.' || v, 'UPDATE')
                   OR has_table_privilege('authenticated', 'public.' || v, 'DELETE') OR has_table_privilege('anon', 'public.' || v, 'SELECT')) THEN
        RAISE EXCEPTION 'ESG2_PROOF|a view is writable by authenticated or readable by anon';
    END IF;
    IF jsonb_array_length(change_log_coverage_gaps() -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'ESG2_PROOF|change-log coverage: %', change_log_coverage_gaps();
    END IF;
    IF (SELECT count(*) FROM esg_settings) <> 1 OR (SELECT standard_hours_per_day FROM esg_settings) IS NOT NULL
       OR EXISTS (SELECT 1 FROM grid_emission_factors) THEN
        RAISE EXCEPTION 'ESG2_PROOF|the two settings must ship unset (Q1 · Q4)';
    END IF;
    IF EXISTS ((SELECT id, days_lost FROM incident_rows EXCEPT SELECT * FROM esg2_incident_rows_before)
               UNION ALL (SELECT * FROM esg2_incident_rows_before EXCEPT SELECT id, days_lost FROM incident_rows)) THEN
        RAISE EXCEPTION 'ESG2_PROOF|incident_rows.days_lost changed for an incident with no correction';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'ESG2_PROOF|require_calibrated_since was set or a COD changed';
    END IF;
END;
$proof$;

NOTIFY pgrst, 'reload schema';

-- ── function-grant replay (apply_migration.sh does this inside the same transaction) ──
-- db/views/zzz_function_grants.sql
-- 【函数的 EXECUTE 权限 —— 镜像此前完全没有记它们】
--
-- ════════════════════════════════════════════════════════════════════════════
-- pg_get_functiondef 不吐 GRANT/REVOKE,而表镜像是【手写】把 GRANT 补进去的
-- (22 个表镜像里都有),函数镜像没有。后果是实测出来的:
--     live    calculate_metal_price_internal  anon=false authenticated=false
--     rebuilt calculate_metal_price_internal  anon=true  authenticated=true
--     live    reverse_journal_entry_internal  anon=false authenticated=false
--     rebuilt reverse_journal_entry_internal  anon=true  authenticated=true
-- 也就是说【这个系统里每一次 REVOKE 都活不过一次重建】。照镜像切到生产,
-- 冲销分录的引擎会向匿名用户敞开 —— 而匿名 key 是随应用公开发出去的。
--
-- 【为什么这个文件住在 db/views/ 而不是 db/functions/】重放顺序是
-- functions → tables → views,而【表镜像里也定义函数】(守卫触发器、取号函数,共 36 个)。
-- 放在 db/functions 里跑,那 36 个还没建出来,REVOKE ON ALL FUNCTIONS 收不到它们 ——
-- 实测:重建之后 anon 仍能调 36 个。放在 views 阶段、文件名 zzz 排最后,才真的收得干净。
-- 它不定义任何视图,只声明权限。
--
-- 【anon 在 public 架构里不该有任何 EXECUTE】anon 就是互联网。
-- 未登录的界面(登录页、设置密码页)走的是 Supabase auth 端点,不调 public 的函数,
-- 所以这是一句可以下得很死的断言,而不是需要逐个斟酌的清单。
-- 真有哪个函数将来必须给 anon,就在下面显式加一行【并写明理由】。
-- ════════════════════════════════════════════════════════════════════════════

-- 先全部收回(含 PUBLIC —— 默认授权给的是 PUBLIC,authenticated 是从它继承的;
-- 只收 authenticated/anon 是没有用的,OPS-3 实测过)。
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;

-- 再把登录用户与服务角色需要的授回。
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;

-- 【内层函数:连 authenticated 也不给】它们没有调用者检查,靠的就是调不到。
-- 有调用者检查的函数不在此列 —— 那是另一半保证(见 check 的 C1 不变式)。
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_internal(uuid, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_journal_entry_internal(uuid, date, text) FROM authenticated;
-- FIN-27:条款解析与承诺写入的内层算子。同上 —— 没有调用者检查,靠的就是调不到;
-- 它们只从 calculate_metal_price_internal / apply_assay_result /
-- reprice_from_committed_terms / create_purchase_order 的函数体内被调用(属主身份)。
-- SOD-1(2026-08-24):职责分离的三支内层函数。**gate 的 B2 抓到它们**,
-- 而其中两支是真的越权读:sod_manual_posters_in / sod_supplier_creator 是
-- SECURITY DEFINER 且没有调用者检查,留着 authenticated 的 EXECUTE,任何登录用户
-- 都能绕过 RLS 读出"谁记过手工凭证"与"谁建了这家供应商"。
-- 三支都只从 guard_payment_sod / guard_finance_settings_sod 的函数体内被调用,
-- 而那两个是属主身份跑的触发器 —— 所以收回之后照常工作,靠的就是调不到。
-- (approvals_readiness 不在此列:它【要】被页面调用,所以走的是另一半保证 ——
--  fu2 给它加了 require_permission(...)。★ APR-1(N6)把那个码从 module.finance.view
--  换成了 action.manage_permissions —— 与 /settings/approvals 那一页的闸同一个码,
--  于是屏幕与它调的函数不再是两个码守同一块屏幕。)
REVOKE EXECUTE ON FUNCTION public.assert_segregated(text, uuid[], text) FROM authenticated;

-- GST-1(2026-08-24):两支查表函数。**gate 的 definer 判词点了它们的名**。
-- 它们都是 SECURITY DEFINER 且没有调用者检查:tax_rate_for 绕过 tax_rates 的 RLS,
-- gst_registered 绕过 finance_settings 的 RLS。
-- 实测 app / lib 里没有任何一处调它们 —— 界面调的是 f5_return / f5_box_detail
-- (两者都带 require_permission),以及 finance_settings.gst_registered 这一【列】
-- (走该表自己的 RLS)。库内只有 f5_return 与 post_journal_entry 调它们,
-- 两个都是 SECURITY DEFINER,以属主身份执行,收回之后照常工作。
-- 【为什么不给它们加 require_permission】它们被属主(postgres)在 definer 内部调用,
-- 而 postgres 没有 claims —— 加了门反而会在过账与出表的路上抛权限错。
-- 与上面三支同形:够不着的东西不需要门,需要的是【真的够不着】。
REVOKE EXECUTE ON FUNCTION public.gst_registered() FROM authenticated;

-- EQP-PAY-1(2026-09-01):一张采购单是设备单还是材料单。**gate 的 B2 点了它的名。**
-- 它是 SECURITY DEFINER 且没有调用者检查 —— 而那是【故意的】:它是给守卫触发器
-- 认主语用的。若它受 RLS 约束,一个看不见行的调用者会拿到 NULL,而守卫会因此
-- 【静默放行】—— 正是本仓库记过的"守卫对主语缺席这一格是瞎的"那条病。
--
-- 【为什么不给它加 require_permission,而是收回 EXECUTE】它唯一的库内调用者
-- guard_payment_term_applicable 是【属主身份跑的触发器】,而属主(postgres)没有
-- claims —— 加一道门反而会在每一次写付款计划的路上抛权限错。与上面
-- gst_registered / tax_rate_for 同形:**够不着的东西不需要门,需要的是【真的够不着】。**
-- app / lib 里没有任何一处调它(实测);报表里要用它,以 postgres 身份跑。
REVOKE EXECUTE ON FUNCTION public.purchase_order_kind(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.tax_rate_for(text, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_manual_posters_in(date, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sod_supplier_creator(uuid) FROM authenticated;

-- COD-1(2026-09-07):销毁证书的三支内层函数。**gate 的 B2 点了它们的名,
-- 而其中一支是真的越权动作** —— void_cod_internal 是 SECURITY DEFINER 且【没有
-- 调用者检查】,留着 authenticated 的 EXECUTE,任何登录用户都能作废任何一张
-- 已签发的销毁证书,完全绕开 action.issue_cod。带门的那一支叫 void_cod;
-- 这一支存在,是因为【冲销加工单的人不持有签发权限】,而冲销必须能作废证书。
--
-- 三支各自的唯一调用者,全部是属主身份跑的 SECURITY DEFINER:
--   * void_cod_internal      ← void_cod、refresh_cod_for_batch
--   * refresh_cod_for_batch  ← commit_processing_run / rollback_processing_run /
--                              soft_delete_inbound_batch(三处挂钩)
--   * cod_delivery_completion ← refresh_cod_for_batch、cod_certificate_data
-- 所以收回之后照常工作,靠的就是【真的够不着】。
--
-- 【为什么不给它们加 require_permission,而是收回 EXECUTE】与上面 gst_registered /
-- purchase_order_kind 同形,但这里的理由更硬一格:refresh_cod_for_batch 是在
-- 【投料的那个人】的会话里被调用的,而运营角色不持有 action.issue_cod ——
-- 加一道门会让"提交加工单"这个动作本身抛权限错。
--
-- ★【界面因此走带门的那一支】★ 面板要显示"为什么还不能签发",而那句话
-- 由 cod_certificate_data 的 CANNOT_CERTIFY|批号|理由 抛出 —— 它有
-- action.issue_cod 的门。判据仍然只有一份实现,而外面只有一扇门。
REVOKE EXECUTE ON FUNCTION public.void_cod_internal(uuid, text, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.refresh_cod_for_batch(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.cod_delivery_completion(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_formula(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pricing_terms_of_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_metal_price_from_terms(jsonb, jsonb, numeric, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.commit_pricing_terms(uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.resolve_pricing_commitment(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.committed_terms_price(uuid, date) FROM authenticated;
-- TASK-1c-a-fu1:【一个事实,一个写入者】那个函数 —— 归属人置为活跃参与者。
-- 它没有调用者检查,只从两扇门的触发器体内被调用(属主身份),所以靠的就是调不到。
-- 门被 gate 的 B2 抓到过一次:留着 authenticated 的 EXECUTE,任何登录用户都能
-- 把【自己】插成【任何一张任务】的活跃参与者 —— 而活跃参与者正是 can_edit_task
-- 团队分支的全部判据。也就是说它等于一把万能写权限。
REVOKE EXECUTE ON FUNCTION public.ensure_task_owner_participant(uuid, uuid, uuid) FROM authenticated;
-- APR-1:审批留痕的唯一写入口。没有调用者检查 —— 它只从 decide_leave_request /
-- decide_medical_claim / submit_review / approve_review / acknowledge_review 的函数体内
-- 以属主身份被调用,而那五个各自已经把过关了。给了 authenticated 就等于任何登录用户
-- 都能伪造一行留痕,而留痕正是"不可伪造"才有意义的东西。
REVOKE EXECUTE ON FUNCTION public.record_approval_decision(text, uuid, text, smallint, text) FROM authenticated;
-- APR-2:审批引擎的两个内层算子。approval_level_for 读的是 finance_settings 上的阈值,
-- require_approver_for 是"你能不能批这一级"的判词本身 —— 两个都没有调用者检查,
-- 靠的就是调不到。公开入口是 approve_purchase_order / reject_purchase_order,
-- 它们各自 require_permission。给了 authenticated 就等于把阈值和授权判断敞开。
REVOKE EXECUTE ON FUNCTION public.approval_level_for(numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.require_approver_for(smallint) FROM authenticated;
-- ★ APR-3:分档那个比较号搬出来单独成一支(approval_level_at)。它【不是】DEFINER
-- (它一个东西都不读:两个入参,一次比较),所以 gate 的 B2 与它无关;收权是为了
-- 与它的公开入口 approval_level_for 一致 —— 两支答的是同一个问题,不该一支敞着。
REVOKE EXECUTE ON FUNCTION public.approval_level_at(numeric, numeric) FROM authenticated;
-- ★ APR-3:一张报销单值多少本位币。【不是】DEFINER —— 它读 expense_claims 与
-- fx_rates,而那两张表的 RLS 正是这个问题该有的答案。收权的理由不是安全(RLS
-- 已经管住了),是【它是一支内层算子】:它的三个调用方都以属主身份跑,而一个
-- 敞着的内层算子迟早会长出第四个调用方,那时谁也说不清它该答什么。
REVOKE EXECUTE ON FUNCTION public.expense_claim_amount_base(uuid) FROM authenticated;
-- ★★ APR-3:哪些单据正在等人批。SECURITY DEFINER 且【没有】调用者检查,
-- 与 real_role_holders / approval_gate_intersections 逐字同源同理由:它的三个
-- 调用方里两个是【属主身份跑的触发器】(guard_approvals_switch 的关闭那一支与
-- APPROVALS_POLICY_WOULD_STRAND),属主没有 claims,加一道门会在每一次写策略的
-- 路上抛权限错;第三个 approvals_readiness 自己开头就查 action.manage_permissions。
-- 给了 authenticated 就等于把采购与财务两个模块的在途单据编号一起敞开。
REVOKE EXECUTE ON FUNCTION public.approval_pending_documents() FROM authenticated;
-- SAL-B:客户敞口算子。无调用者检查,靠调不到 —— 消费方是 record_output_sale
-- (definer)与 operations_now(属主视图),两者都以属主身份执行。给了
-- authenticated 就等于把任意客户的应收敞口敞开给没有财务权限的人。
REVOKE EXECUTE ON FUNCTION public.customer_ar_exposure_base(uuid) FROM authenticated;
-- IOD-1:库存排空与冲销镜像的内层算子。无调用者检查,靠的就是调不到 ——
-- drain_stock 的调用方是 record_output_sale(output.edit)、commit_processing_run
-- (processing.edit)与注销触发器(批次侧的 edit),【三者各自已经把过关】,
-- 而它们分属不同模块:给 drain_stock 挑一个权限码只能挑一个比三者都松的,
-- 那不是把关、那是把关的样子。mirror_consume_restore 只从 rollback_processing_run
-- 体内被调用。给了 authenticated 就等于任何登录用户都能凭空写出入库/出库流水。
REVOKE EXECUTE ON FUNCTION public.drain_stock(numeric, text, date, uuid, uuid, text[], uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.mirror_consume_restore(uuid, uuid, uuid, numeric, date, uuid) FROM authenticated;
-- IOD-1b:收货库位的翻译器。三个建批次 RPC 共用它,而那三个分属两个模块
-- (进料 inbound.edit / 产出 output.edit)且各自已把过关 —— 给它挑一个权限码
-- 只能挑一个比两者都松的。靠"调不到"。
REVOKE EXECUTE ON FUNCTION public.resolve_receipt_location(uuid) FROM authenticated;
-- IOD-2:库位/物料分类的判词。同 resolve_receipt_location —— 四个落地点共用它,
-- 而那四个分属三个模块(inbound.edit / output.edit / inventory.edit)且各自已把
-- 过关;给它挑一个权限码只能挑一个比三者都松的,那不是把关、是把关的样子。
-- 它没有调用者检查,靠的就是调不到(gate 的 B2 判词认这条出路)。
REVOKE EXECUTE ON FUNCTION public.check_location_class(uuid, uuid) FROM authenticated;
-- NTF-1:两个通知发射器。【它们能凭空写出一条通知】,而 notifications 之所以可信,
-- 靠的正是"只有属主身份的函数写得进"(与 approval_log 同一条:留痕不该有第二个
-- 写法)。给了 authenticated,任何登录用户都能伪造一条"某某库位违规"的事件 ——
-- 而通知是拿来被相信的东西。
-- 【调用它们的是谁】notify_landing_warnings 从四个建批次 RPC 的函数体内被调用
-- (那四个是 DEFINER,以属主身份执行);notify_class_violations 从两个触发器函数
-- 内被调用,而那两个触发器函数【也声明了 SECURITY DEFINER】—— 触发器函数默认以
-- 调用者身份跑,不声明就会在这里撞上"调不到"。
REVOKE EXECUTE ON FUNCTION public.notify_landing_warnings(text[], uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.notify_class_violations(text, uuid[], uuid[]) FROM authenticated;
-- SO-3b:发货单号的取号器。无调用者检查,靠的就是调不到 —— 唯一调用方是
-- ship_order(DEFINER,module.sales.edit,以属主身份执行)。给了 authenticated
-- 就等于任何登录用户都能凭空烧掉一个无缝单号,而无缝的意思正是"号码之间没有洞"。
REVOKE EXECUTE ON FUNCTION public.next_shipment_code(date) FROM authenticated;
-- LOG-2a:集装箱取号器。同 next_shipment_code —— 无调用者检查,靠的就是调不到。
REVOKE EXECUTE ON FUNCTION public.next_container_code(date) FROM authenticated;
-- SO-3b fu5:"这一行已经许出去多少"(已发 + 活预留)。无调用者检查,靠的就是
-- 调不到 —— 消费方是 reserve_stock(DEFINER,module.sales.edit),以及下一刀
-- SO-1b 的改单下限。它读的是订单行的履约情况,而那是 module.sales.view 的东西;
-- 给了 authenticated 就等于任何登录用户都能一行一行问出别人订单的发货进度。
REVOKE EXECUTE ON FUNCTION public.line_spoken_for(uuid) FROM authenticated;
-- SO-1b:"这张单发完了没有"(已发 vs 已订)。同上 —— 没有调用者检查,靠的就是
-- 调不到;两个消费方 ship_order 与 amend_sales_order 都是 DEFINER、都要
-- module.sales.edit,以属主身份执行。给了 authenticated 就等于任何登录用户都能
-- 一张一张问出别人订单的履约进度,而那是 module.sales.view 的东西。
REVOKE EXECUTE ON FUNCTION public.sales_order_fulfilment_status(uuid) FROM authenticated;
-- CN-1:贷项凭证的取号器。同 next_shipment_code —— 无调用者检查,靠的就是调不到;
-- 唯一调用方是 create_credit_note(DEFINER,module.finance.edit,以属主身份执行)。
-- 给了 authenticated 就等于任何登录用户都能凭空烧掉一个无缝单号,而无缝的意思
-- 正是"号码之间没有洞"。
REVOKE EXECUTE ON FUNCTION public.next_credit_note_code(date) FROM authenticated;
-- SO-4a:报价的取号器。同上 —— 无调用者检查,靠的就是调不到。
-- 【而建报价【走直连】,没有 RPC 门可以代取】—— 两者放在一起,客户端就永远
-- 拿不到号。解法不是把它授出去,是让号【根本不由客户端取】:
-- generate_quote_code(BEFORE INSERT,属主身份)在同一条语句里补上,
-- 先例是 customers.generate_customer_code。客户端插的是一行没有号的报价。
REVOKE EXECUTE ON FUNCTION public.next_quote_code(date) FROM authenticated;
-- EQP-1c-a:固定资产的取号器。同 next_shipment_code / next_container_code /
-- next_quote_code —— 没有调用者检查,靠的就是调不到。它有【两个】调用方
-- (record_expense 的新建支与 create_fixed_asset),两个都是 DEFINER 且各自
-- require_permission('module.finance.edit'),以属主身份执行。给了 authenticated
-- 就等于任何登录用户都能凭空烧掉一个 FA 号,而"无缝"的意思正是号码之间没有洞。
REVOKE EXECUTE ON FUNCTION public.next_fixed_asset_code(date) FROM authenticated;

-- GST-2(2026-08-25):税码解析器。与上面 GST-1 那两支【逐字同一条理由】——
-- SECURITY DEFINER、没有调用者检查、绕过 tax_codes 的 RLS 读出整本税码字典。
-- 界面从不调它:屏幕上的税码下拉读的是 tax_codes 这张表本身(走它自己的 RLS,
-- 谓词是 has_permission('module.finance.view'))。库内只有 create_invoice /
-- create_order_invoice / record_expense 调它,三支都是 SECURITY DEFINER、
-- 以属主身份执行,收回之后照常工作。
-- 【为什么不给它加 require_permission】它被属主(postgres)在 definer 内部调用,
-- 而 postgres 没有 claims —— 加了门反而会在开票与记费用的路上抛权限错。
REVOKE EXECUTE ON FUNCTION public.resolve_tax_code(text, text, text, text) FROM authenticated;

-- CHAIN-BUILD-1(2026-08-30):审批链的两支内层判据。
-- 【为什么收回】两支都是 SECURITY DEFINER 且【没有调用者检查】,而 gate 的 B2
-- 正是查这个。它们【不需要】门,需要的是【真的够不着】——
-- real_role_holders 读 auth.users(账号是否确认/封禁/删除)与 user_roles,
-- 给了 authenticated 就等于任何登录用户都能把整个账号目录的登录状态问出来;
-- role_can_see_amounts 读 role_permissions,同理会把权限矩阵问出来。
-- 【唯一的调用方,逐个点名】三支都是 SECURITY DEFINER、以属主身份执行,
-- 而且三支各自已经把过关(readiness 有 require_permission;另两支是闸自己):
--   · real_role_holders   ← guard_approvals_switch / approvals_readiness / require_approver_for
--   · role_can_see_amounts ← guard_approvals_switch / approvals_readiness
-- 收回之后照常工作,靠的就是调不到 —— 与上面 SOD-1 那三支逐字同一条理由。
REVOKE EXECUTE ON FUNCTION public.real_role_holders(text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.role_can_see_amounts(text) FROM authenticated;

-- ★ APR-2(2026-09-22):approval_gate_intersections —— 与上面这两支【同源同理由】。
-- 它经 real_role_grants 读 auth.users 的登录状态,并把整张 role_permissions
-- 摊平成"谁真的持有哪个码"。给了 authenticated 就等于把账号目录 + 权限矩阵
-- 一次问出来 —— 比单独任何一支都宽。
-- 【唯一的两个调用方】approvals_readiness(自己有 require_permission)与
-- guard_approvals_switch(属主身份跑的触发器),两者都是 SECURITY DEFINER,
-- 收回之后照常工作,靠的就是调不到。
-- ⚠【为什么这一行必须在这里】C-1 的 real_role_grants 实测过:
--   apply_migration.sh 在 COMMIT 【之前】重放本文件,而本文件第一句是
--   REVOKE EXECUTE ON ALL FUNCTIONS ... FROM PUBLIC 后面跟着 GRANT ... TO authenticated
--   —— 只写在迁移里的那次 REVOKE 会被原样冲掉,而迁移报告成功。
REVOKE EXECUTE ON FUNCTION public.approval_gate_intersections(text, text) FROM authenticated;

-- ★ APR-2:approval_chain_gates 与 forbid_self_approval 【故意不收】。
--   两支都【不是】SECURITY DEFINER,也都不读任何受 RLS 约束的东西:
--   前者是一张常量名册,后者只比较 auth.uid() 与两个传进来的 uuid。
--   ☞ 照直写下来,免得下一个人以为它们是被漏掉的 —— 一份"该收而没收"的
--     清单与一份"想过、不收"的清单,在文件里长得一模一样。
--   ★ APR-ROUTE-1 之后【后半句不再逐字成立】:forbid_self_approval 现在经
--     self_leg 与 self_approval_exception 去问(两者都已收回)。它仍然【不收】——
--     它自己不是 DEFINER,一个 authenticated 直接调它会在那两支上撞 42501,
--     什么都探不到;而它唯一的调用方是 DEFINER 决定函数,以属主身份执行。

-- ★ C-1(2026-09-04):real_role_grants —— 与上面 real_role_holders 【同源同理由】。
-- 它就是那四条判据的行级形状(返回 grant_id + user_id),real_role_holders 如今
-- 是它的投影。所以它读的东西一字不差:auth.users 的确认/封禁/删除 + user_roles。
-- 给了 authenticated 就等于把整个账号目录的登录状态问出来 —— 收回。
-- 【唯一的调用方】guard_last_admin(user_roles 上的 BEFORE UPDATE/DELETE 触发器)。
-- ★ 它正是因此才被改成 SECURITY DEFINER 的:调用者权限的触发器以 authenticated
--   身份跑,收回之后就【调不到】,守卫会在每一次撤销授权时抛权限错。
--   DEFINER 让它以属主身份跑,于是"收回"与"守卫能用"同时成立。
--
-- ⚠【这一行是被实测逼出来的,不是照抄】C-1 起初只把 REVOKE 写在迁移里。
--   apply_migration.sh 在 COMMIT 之后会【重新断言一遍本文件】(那是它的兜底),
--   而本文件当时没有这一行 —— 于是那次 REVOKE 被原样冲掉,
--   实测 has_function_privilege('authenticated', 'real_role_grants', 'EXECUTE') = true,
--   一条【活的 B2 违规】。**收回必须写在这里,写在迁移里不算数。**
REVOKE EXECUTE ON FUNCTION public.real_role_grants(text) FROM authenticated;

-- PROC-COST-2(2026-08-31):【计值读取器】与【单位落地成本】三支内层函数。
-- 三支都是 SECURITY DEFINER 且【没有调用者检查】,而 gate 的 B2 正是查这个。
-- 它们【不该】有门,需要的是【真的够不着】—— 理由与上面那一族逐字同源,
-- 但这里的"为什么不加门"有它自己的一条,值得写清楚:
--
-- 【为什么这两支【必须】没有判据】batch_freight_base / batch_processing_cost_base
-- 是【屏幕读取器】,无权返回 NULL(受限)——「受限」与 0.00 不是同一件事。
-- 而注销与盘点要过账的那个金额【不许取决于谁按的按钮】:一个只有
-- module.inbound.edit 的仓管按下注销时,若计值读的是带判据的那一支,
-- COALESCE(NULL, 0) 会让它安静地退回按 unit_price 计值 —— 也就是 PROC-COST-2
-- 正在修的那个缺陷原样复发,而且再没有人看得见。所以算术与受众拆成两层:
-- 算术在 _all 这一对里(只有一份定义),受众在带判据的那一对里。
--
-- 【唯一的调用方,逐个点名】三支都只从属主身份执行的地方被调用:
--   · batch_freight_base_all          ← batch_freight_base(definer,带判据)
--                                       inbound_batch_landed_unit_cost(definer)
--                                       allocate_processing_costs(definer,ROLE-1 Batch 3a 起)
--   · batch_processing_cost_base_all  ← batch_processing_cost_base(definer,带判据)
--                                       inbound_batch_landed_unit_cost(definer)
--                                       allocate_processing_costs(definer,ROLE-1 Batch 3a 起)
--   · inbound_batch_landed_unit_cost_all ← emit_batch_writeoff_movement(触发器,definer)
--                                       post_stocktake(definer)
--                                       inventory_control_reconciliation(definer)
--                                       inventory_valuation_snapshot(definer)
--     【CLEANUP-A fu1】它是【过账】原语,刻意没有判据 —— 账上的金额不许取决于
--     按按钮的人有什么读权限。所以它必须靠"调不到"活着,与上面那一对同一条规矩。
--   · inbound_batch_landed_unit_cost  ← inbound_batch_valuation_rows(definer)
--     【它自己带判据(CLEANUP-A / R3)】,收权是第二层,不是唯一那层。
--     (此处原写着 post_stocktake(definer,module.stocktakes.edit)—— 不对:fu1 起 post_stocktake
--      读 _all。ROLE-1 Batch 3a 顺手更正,并拿掉了判据里 stocktakes.edit 那一支。)
-- 给了 authenticated 就等于把【绕过 RLS 的运费与加工成本读取】敞开给任何登录
-- 用户 —— 那正是带判据的那一对存在的全部理由,而这三支会把它一句话作废。
-- 收回之后照常工作,靠的就是调不到。
REVOKE EXECUTE ON FUNCTION public.batch_freight_base_all(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_processing_cost_base_all(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost(uuid) FROM authenticated;
-- CLEANUP-A fu1:过账原语,无判据,必须靠"调不到"活着。
REVOKE EXECUTE ON FUNCTION public.inbound_batch_landed_unit_cost_all(uuid) FROM authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ COD-2(2026-09-08):本仓库【第一条】给 anon 的 EXECUTE ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 本文件抬头写着:「anon 在 public 架构里不该有任何 EXECUTE……真有哪个函数
-- 将来必须给 anon,就在下面显式加一行【并写明理由】。」这就是那一行,
-- 而下面是那个理由。
--
-- 【它是什么】cod_verification(text) —— 销毁证书核验页的取数。供应商扫证书上
-- 的二维码打开 /verify/cod/<令牌>,那一页就是这支函数的输出。**这是本系统
-- 第一个不用登录就打得开的页面**,而这支函数是它够得着的【唯一】一样东西。
--
-- 【为什么必须给 anon,不能靠"页面在服务端用 service_role 读"】
--   两种都成立,而选这一种的理由是【判据落在哪里】:给 anon 授权,把关的是
--   数据库 —— 这支函数收一个令牌、回一份白名单子集,任何调用者都只拿得到那些。
--   走 service_role 的话,把关的是"那一页恰好是服务端渲染的、而且它恰好只
--   显示了该显示的" —— 一次页面重写就可能悄悄改掉它,而没有任何东西会说话。
--   ★ 一条能在数据库这边说清的判据,不该寄存在一个页面的写法里。★
--
-- 【它没有调用者检查,而这是【正确的】】它的"权限"就是【持有那个令牌】:
--   122 位随机、与证书号毫无关系、改一位数字得到的是一个不存在的值。
--   一个匿名的核验入口若还要问 has_permission,它就永远回答不了任何人。
--   check_mirrors 的 DEFINER_NO_CHECK_ALLOWED 里有它,理由逐字同此。
--
-- 【它的限流住在函数体里,不在路由上】anon key 随浏览器包发出去,所以
--   POST /rest/v1/rpc/cod_verification 是第二条门,不经过 Vercel ——
--   一个住在路由上的限流器会被它要拦的那个工具整个绕过去。
--
-- ⚠★【这一行【必须】在这里,而不是只在迁移里】★⚠ 与 C-1 的 real_role_grants
--   那一段【方向相反、道理相同】:db/apply_migration.sh 把本文件拼在 COMMIT
--   之前、同一个事务里重跑一遍,而本文件的第一句是
--       REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
--   一条只写在迁移里的 GRANT 会在提交之前被它冲掉,**而迁移报告成功**。
--   所以真源在这里,写在那句 REVOKE 的【后面】。
GRANT EXECUTE ON FUNCTION public.cod_verification(text) TO anon;

-- COD-2:执照判据(在完成日当天在效的那一张 GWDF)。与 cod_delivery_completion
-- 逐字同一条理由 —— SECURITY DEFINER、没有调用者检查,靠的就是【调不到】。
-- 它绕过 company_compliance 的 RLS(那张表的谓词借的是 module.suppliers.view,
-- 而仓储现场读不到它,却仍然被这道闸管着 —— 那正是它必须 DEFINER 的原因)。
-- 给了 authenticated 就等于任何登录用户都能把公司的执照号、发证机关与有效期
-- 问出来。唯一的两个调用方 issue_cod 与 cod_certificate_data 都是 DEFINER、
-- 各自 require action.issue_cod,以属主身份执行,收回之后照常工作。
REVOKE EXECUTE ON FUNCTION public.cod_governing_licence(date) FROM authenticated;

-- ★ APR-ROUTE-1(2026-09-23):五支新的内层函数,全部【收回】。
--   五支都是 SECURITY DEFINER、没有调用者检查,靠的就是【调不到】:
--     account_person          —— 回答【任意一个账号】是哪一名员工(账号目录);
--     self_leg                —— 经它能逐个探测"某账号是不是某单据的提单人/主角";
--     self_approval_exception —— 经 real_role_holders 读审批人名单;
--     approval_level_eligible —— 同上;
--     approval_deciders       —— 读 auth.users 的登录状态与整张权限矩阵。
--   调用方(forbid_self_approval 在 DEFINER 决定函数里、record_approval_decision、
--   require_approver_for、approval_gate_intersections、approvals_readiness、
--   guard_approvals_switch)全部以属主身份执行,收回之后照常工作。
--   ⚠ 写在这里而不是只写在迁移里:理由见上面 approval_gate_intersections 那一段。
--   ☞ self_approved_decisions【不收】:它有自己的调用者检查
--     (require_permission('data.view_self_approvals')),而 /finance/self-approved 要调它。
REVOKE EXECUTE ON FUNCTION public.account_person(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.self_leg(uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.self_approval_exception(text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.approval_level_eligible(smallint, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.approval_deciders(text, text, smallint, uuid, uuid, text, text) FROM authenticated;

-- PAY-REQ-1(2026-09-23):付款申请的内层引擎与算子。**这几支没有调用者检查,靠的就是调不到。**
--   record_payment_internal / reverse_payment_internal —— 原 record_payment / reverse_payment
--     的函数体,拿掉了 require_permission(CFO 批准时要用它们试跑,而 CFO 不持 finance.edit)。
--     留着 authenticated 的 EXECUTE,任何登录用户都能不经申请直接出款 —— 本刀要关的正是这扇门。
--     唯一的外门:record_payment(收款 + 豁免出款)与 pay_payment_request(已批准的申请)。
--   payment_request_dry_run —— 按 id 试跑一张申请再回滚;无检查,只从申请函数体内调用。
--   payment_request_conflict / payment_request_payee_check —— 申请函数体内的两个判断。
--   调用方全部是 SECURITY DEFINER,以属主身份执行,收回之后照常工作。
REVOKE EXECUTE ON FUNCTION public.record_payment_internal(text, uuid, numeric, text, numeric, text, date, text, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_payment_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_dry_run(uuid, date, numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_conflict(jsonb, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payment_request_payee_check(text, uuid) FROM authenticated;

-- PAY-REQ-1 · Batch B(2026-09-23):行内转账、转账冲销、代扣税缴纳与其冲销的内层引擎。
--   同一条理由:它们拿掉了权限检查(CFO 批准时要用它们试跑,而 CFO 不持 finance.edit),
--   靠的就是调不到。唯一的外门是 pay_payment_request(一张已批准的申请);
--   record_bank_transfer / reverse_bank_transfer / remit_wht 只剩按名拒绝的外壳。
REVOKE EXECUTE ON FUNCTION public.record_bank_transfer_internal(date, text, text, numeric, numeric, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_bank_transfer_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.remit_wht_internal(date, date, text, text, text, numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reverse_wht_remittance_internal(uuid, date, text) FROM authenticated;

-- PAYROLL-APR-1(2026-09-24):工资过账的内层引擎与申请的算子。**这几支没有调用者检查,靠的就是调不到。**
--   post_payroll_period_internal / unpost_payroll_period_internal —— 原 post_payroll_period /
--     unpost_payroll_period 的函数体,拿掉了 require_permission(CFO 批准时要用它们试跑,而 CFO
--     不持 module.hr.edit)。留着 authenticated 的 EXECUTE,任何登录用户都能不经申请直接过账 ——
--     本刀要关的正是这扇门。唯一的外门:post_payroll_period / unpost_payroll_period(要一张已批的申请)。
--   payroll_request_dry_run —— 按 id 试跑一张申请再回滚;只从申请函数体内调用。
--   payroll_period_fingerprint —— 一个期间此刻的那一组数(含逐行摘要),只从申请函数体内调用。
--   ☞ payroll_period_frozen 【不在】此列:调它的是两支 INVOKER 守卫,收回就 42501
--     (period_close_floor 同一条;两处 allowlist 有它)。
REVOKE EXECUTE ON FUNCTION public.post_payroll_period_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.unpost_payroll_period_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_period_fingerprint(uuid) FROM authenticated;
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22):四支内层函数,没有调用者检查,靠的就是调不到 ——
--   reverse_payroll_payment_internal —— 冲一次工资付款的引擎;外门是 reverse_payroll_payment(要一张批过的申请)与申请的两次试跑。
--   assert_entry_not_bank_matched —— 银行行已配对就按名拒(Q6);只在四支冲销引擎的函数体内调用。
--   payroll_payment_entry_kind —— 从已付的戳认付款种类;只在引擎、路由、付薪页读者(都是 DEFINER)里调用。
--   leave_service_entitlement —— 按服务期给的额度(B1);只在 leave_balance_internal 里调用。
REVOKE EXECUTE ON FUNCTION public.reverse_payroll_payment_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_entry_not_bank_matched(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_payment_entry_kind(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.leave_service_entitlement(text, date, date) FROM authenticated;

-- ROLE-1 Batch 4a(2026-09-25,侧门 (c)):reprice_inbound_batch 是每一条定价路径落进来的那支【引擎】
--   (写 unit_price、price_history,过 purchase 分录)。它留着 authenticated 的 EXECUTE,就是
--   set_inbound_unit_price 之外的第二扇公开的定价门。外门只剩:set_inbound_unit_price ·
--   reprice_from_committed_terms · create_inbound_batch(带价)—— 各问 action.price_receipts ——
--   与 apply_assay_result(action.apply_assay)。引擎自己仍问 data.view_purchase_prices
--   (看不见价格的人不能定价),所以它【有】调用者检查;收回是再加的一道,不是唯一的一道。
REVOKE EXECUTE ON FUNCTION public.reprice_inbound_batch(uuid, numeric, text, numeric, text) FROM authenticated;

-- ROLE-1 Batch 4b(2026-09-25):收货定价申请的内层算子。**这几支没有调用者检查,靠的就是调不到。**
--   receipt_price_submit_internal —— 四扇门(定价面板 · 按承诺条款改价 · 收货台带价 · 应用化验)
--     各问完自己的码才落进来;留着 EXECUTE,任何登录用户都能不经那几扇门直接提申请(或在审批
--     关着时直接过账)。
--   receipt_price_post_internal —— 过账本身(调引擎);只从批准、审批关着时的提交与试跑里调用。
--   receipt_price_request_dry_run · receipt_price_withdraw_internal · receipt_price_fingerprint ·
--   receipt_settled_base —— 只从申请函数体内调用。
--   ☞ receipt_price_open 【不在】此列:调它的是两支 INVOKER 守卫,收回就 42501
--     (payroll_period_frozen 同一条;两处 allowlist 有它)。
REVOKE EXECUTE ON FUNCTION public.receipt_price_submit_internal(uuid, numeric, text, text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_withdraw_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_price_fingerprint(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.receipt_settled_base(uuid) FROM authenticated;

-- ROLE-1 Batch 3a(2026-09-25,Q12):assert_other_decider —— 提单人之外没人批得动时按名拒的那一句断言。
--   只从 SECURITY DEFINER 的提交函数(submit_payroll_request 与六支付款申请提交)里调用;它读
--   approval_deciders(本身已收回),留着 EXECUTE 就是把"谁批得了"这张名单的一个问法敞开。
REVOKE EXECUTE ON FUNCTION public.assert_other_decider(text, text, smallint, text) FROM authenticated;
-- U1-B(2026-10-05):带主角的那一版,同一条理由。
REVOKE EXECUTE ON FUNCTION public.assert_other_decider_for_subject(text, text, smallint, uuid, text) FROM authenticated;

-- APR-5a(2026-09-25):贷项 / 作废申请的内层算子。**这几支没有调用者检查,靠的就是调不到。**
--   void_invoice_internal · create_credit_note_internal —— 原 void_invoice / create_credit_note 的函数体(去掉门);
--     留着 EXECUTE,财务就能不经 CFO 直接作废、直接开贷项,而这正是本刀要关的那一扇。
--   invoice_request_submit_internal —— 两扇提交的门各问完 module.finance.edit 才落进来。
--   invoice_request_post_internal —— 过账本身;只从批准、审批关着时的提交与试跑里调用。
--   invoice_request_dry_run —— 只从提交里调用。
REVOKE EXECUTE ON FUNCTION public.void_invoice_internal(uuid, text, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_credit_note_internal(uuid, date, text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_submit_internal(uuid, text, date, text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.invoice_request_dry_run(uuid) FROM authenticated;

-- APR-5b(2026-09-25,grilling Q7):预留的两支内层算子。**没有调用者检查,靠的就是调不到。**
--   release_reservation_internal —— 原 release_reservation 的函数体(去掉门)。两个调用方各自先问:
--     release_reservation(module.sales.edit)· ship_order(action.ship_goods,部分发货先放回多出来的那一截)。
--   reserve_stock_internal —— 原 reserve_stock 的函数体(去掉门)。调用方:reserve_stock(module.sales.edit)·
--     release_reservation_internal(部分释放就地重新预留剩余)。
--   留着 EXECUTE,任何登录用户都能不经销售就改别人订单的预留 —— 而仓库发货正是要够得着这一半、够不着那一半。
REVOKE EXECUTE ON FUNCTION public.release_reservation_internal(uuid, numeric, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.reserve_stock_internal(uuid, uuid, numeric, uuid) FROM authenticated;

-- APR-6(2026-09-25,grilling Q1):**人手里过手工凭证的门从 post_journal_entry 换成 submit_journal_request。**
--   post_journal_entry —— 过账核心,INVOKER、本体不问码、收调用方给的任意 source_type。线上调它的 30 支函数
--     全是 SECURITY DEFINER(属主 postgres),在属主身份下执行,不需要 authenticated 的 EXECUTE;而留着它,
--     持 module.finance.edit 的人就能不经 CFO 过一张任意标签的分录(一张 'purchase' 进 2000 · 一笔贷银行)——
--     ROLE1B4A-PURCHASE-JOURNAL-FORGEABLE 与 PAYREQ1-MANUAL-JOURNAL-CREDITS-BANK 两扇门的根。
--   journal_request_submit_internal —— 两扇提交的门各问完 module.finance.edit 才落进来。
--   journal_request_post_internal —— 过账本身;只从批准、审批关着时的提交与试跑里调用。
--   journal_request_dry_run —— 只从提交里调用。**这几支没有调用者检查,靠的就是调不到。**
REVOKE EXECUTE ON FUNCTION public.post_journal_entry(date, text, text, uuid, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_submit_internal(text, date, text, jsonb, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_post_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_dry_run(uuid) FROM authenticated;

-- APR-7(2026-09-25):**注销、回滚、证书作废的门换成了四张申请**(仓库提,CFO 批)。
--   soft_delete_inbound_batch_internal / soft_delete_output_batch_internal / rollback_processing_run_internal ——
--     原来三扇门的函数体(去掉了码的检查)。调用者:空批一步删的两扇门(先问 action.batch_write_off 与
--     "要不要经 CFO")与 warehouse_request_execute_internal。留着 EXECUTE,任何登录用户都能不经 CFO、
--     不经任何码注销一批料或回滚一张加工单 —— 那正是本刀要关的门。
--   warehouse_request_submit_internal —— 四扇提交的门各问完自己的码才落进来。
--   warehouse_request_execute_internal —— 生效本身;只从批准、审批关着时的提交与试跑里调用。
--   warehouse_request_dry_run —— 只从提交里调用。
--   warehouse_request_touches / warehouse_request_freezing / warehouse_request_snapshot —— 三支读者只给上面几支
--     与冻结守卫用;snapshot 会把供应商名、证书号交给任何登录用户。**这几支没有调用者检查,靠的就是调不到。**
REVOKE EXECUTE ON FUNCTION public.soft_delete_inbound_batch_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.soft_delete_output_batch_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.rollback_processing_run_internal(uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_submit_internal(text, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_touches(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_freezing(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_snapshot(text, uuid) FROM authenticated;
-- warehouse_request_conflict / batch_write_off_needs_request:只从两扇一步删的门与提交里调(属主身份);屏幕从
--   warehouse_requests_visible 与批次行自己的数读同一件事,不需要它们。
REVOKE EXECUTE ON FUNCTION public.warehouse_request_conflict(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_write_off_needs_request(uuid, uuid) FROM authenticated;

-- APR-8(2026-09-26):**合同条款与定价公式的生效换成了一张申请**(cco 提,CFO 批)。
--   terms_request_submit_internal —— 四扇提交的门各问完自己的码才落进来。
--   terms_request_execute_internal —— 生效本身(把条款写进公式并启用 / 把合同改成 active);只从批准、审批关着时的
--     提交与试跑里调用。留着 EXECUTE,任何登录用户都能不经 CFO 让一张公式或一份合同生效 —— 那正是本刀要关的门。
--   terms_request_dry_run —— 只从提交里调用。
--   terms_request_snapshot / terms_request_fingerprint / formula_terms_state / contract_terms_state —— 会把公式的
--     费率与比例、合同的条款交给任何登录用户(公式表的费率列本来只经遮蔽视图读)。**这几支没有调用者检查,靠的就是调不到。**
--   contract_terms_lock_reason 【留着】:两支合同守卫以调用者身份问它;它只说出 active 或那一张在等申请的 label。
REVOKE EXECUTE ON FUNCTION public.terms_request_submit_internal(text, uuid, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_snapshot(text, uuid, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_fingerprint(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.formula_terms_state(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.contract_terms_state(uuid) FROM authenticated;

-- APR-9(2026-09-27):**调薪与固定资产处置换成了申请**(调薪:财务提、CFO 批 / CFO 是当事人时 cco 批;处置:财务提、CFO 批)。
--   salary_change_execute_internal / asset_disposal_execute_internal / dispose_fixed_asset_internal —— 生效本身
--     (改月薪、过处置分录)。留着 EXECUTE,任何登录用户都能不经批准改一个人的月薪或处置一台资产 —— 那正是本刀要关的门。
--   asset_disposal_dry_run —— 只从提交里调用。
--   salary_change_fingerprint / salary_change_open / salary_change_deciders / salary_effective_period_block /
--   pay_decision_code / asset_disposal_fingerprint —— 会交出月薪、账号 ↔ 员工对照或资产成本;
--     **没有调用者检查,靠的就是调不到**。屏幕经 salary_change_requests_visible / asset_disposal_requests_visible /
--     review_approval_code(本来就给)读它们的答案。
REVOKE EXECUTE ON FUNCTION public.salary_change_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.dispose_fixed_asset_internal(uuid, date, numeric, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_dry_run(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_fingerprint(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_open(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_deciders(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_effective_period_block(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.pay_decision_code(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_fingerprint(uuid) FROM authenticated;

-- APR-10(2026-09-27):**GST 申报换成了申请;采购单按品类开、按开单人或这一类的码改。**
--   gst_filing_execute_internal —— 生效本身(写 gst_return_boxes、期间 → approved)。留着 EXECUTE,任何登录用户都能
--     不经 CFO 批就把一组数定成"批准过的申报"—— 那正是本刀要关的门。
--   assert_po_manager —— 只从五扇改单的门里调(全是 DEFINER);它自己不查调用者之外的任何事,靠的是调不到。
--     屏幕读 po_may_manage(只回读者自己的一个布尔)。
REVOKE EXECUTE ON FUNCTION public.gst_filing_execute_internal(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_po_manager(uuid) FROM authenticated;

-- OVERTIME-1(2026-09-28):三支内层判据只由 DEFINER 的加班函数与 complete_attendance_period 在属主身份下调用。
REVOKE EXECUTE ON FUNCTION public.overtime_approved_hours(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.overtime_assert_month_open(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.overtime_other_approver_exists(uuid, uuid[]) FROM authenticated;

-- HISTORY-1(2026-09-28):通用变更记录的内层函数只由 DEFINER 的读法(change_log_rows)、写法(change_log_capture
--   触发器)与匿名化(anonymise_employee)在属主身份下调用。
--   change_log_field —— 按表名动态读【任意一张表】的任意一列:给了 authenticated 就是一扇绕过列级遮蔽的门
--     (以调用者身份跑时列权限仍挡着,但那是第二道;第一道是调不到)。
--   change_log_rule_visible / change_log_task_visible —— 经它们能逐行探测别人的员工 id 与任务归属。
--   change_log_redact_employee —— 唯一能改 change_log 的路;只许 anonymise_employee 走(它自己也查码)。
--   change_log_capture —— 触发器函数,不该被直接调。
--   ☞ change_log_rows / change_log_filters / record_account_event【不收】:各自查 data.view_change_log /
--     action.manage_permissions,屏幕与服务端动作要调它们。change_log_mask_gaps / change_log_coverage_gaps
--     只读目录与常量名单,gate 与 fixture 调它们。
REVOKE EXECUTE ON FUNCTION public.change_log_field(text, jsonb, jsonb, jsonb, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_rule_visible(text, text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_task_visible(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_redact_employee(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.change_log_capture() FROM authenticated;

-- AUDIT-TRAIL-1a(2026-09-29):审计记录的内层函数只由 DEFINER 的读法(record_trail · change_log_rows ·
--   change_log_filters)在属主身份下调用,自己没有调用者检查,靠的就是调不到:
--   change_log_mask_row —— 遮蔽那一步;它调的 change_log_field 能按表名读任意一张表。
--   trail_current_image / trail_ref_label / trail_refs / trail_row_record —— 按表名动态读任意一行(或它最后的影像)。
--   trail_row_visible —— 给了 authenticated 就是一支"任意一行你看不看得见"的探针。
--   trail_actor —— 回答任意一个账号 / 员工 id 是谁(与 account_person 同一个理由)。
--   ☞ record_trail / change_log_find_records【不收】:前者查主语的查看码与根行的读规则,后者查 data.view_change_log。
--     trail_subjects / trail_subject_members / trail_prelog_sources / trail_pk_columns / trail_fk_targets /
--     change_log_began_at 只读常量名单或目录,留着(fixture 与检查脚本会调)。
REVOKE EXECUTE ON FUNCTION public.change_log_mask_row(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_current_image(text, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_ref_label(text, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_refs(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_row_record(text, jsonb, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_row_visible(text, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trail_actor(text, uuid, uuid) FROM authenticated;

-- AUDIT-TRAIL-1d-1(2026-10-04):M12 的门只由 record_trail(属主身份)调用 —— 给了 authenticated 就是一支
--   "这一份评审的审核人是不是你"的探针。M9 / M10 的两张登记表(trail_log_only_tables · trail_member_columns)只读常量,留着
--   (与 trail_subjects 同一个理由:fixture 与检查脚本会调)。save_employee【不收】:它是员工表单的那一次写入,
--   按调用者的身份跑(SECURITY INVOKER),表的策略与守卫照常管。
REVOKE EXECUTE ON FUNCTION public.trail_root_gate(text, text, jsonb) FROM authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ MES-1(2026-10-06):本仓库【第二条】、也是 MES 组里【唯一一条】给 anon 的 EXECUTE ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是什么】ingest_submit(text, text, jsonb) —— 车间网关唯一够得着的东西(MES-0 Q4,Tim)。网关带着项目的公开 apikey
--   POST /rest/v1/rpc/ingest_submit;它的"权限"是那把 244 位随机的网关钥匙,函数里只比 sha256(MES-0 Q5)。
-- 【它碰得到什么】白名单:只插入收件箱、传输日志与网关中断(两种桶的四个计数列除外),一行设备都不改,不跑转换代码,
--   只回调用者自己的序号与固定的码。函数抬头逐条写着;fixture 249 按事务内的逐表计数证"它只写了这三张"。
-- 【为什么给 anon,不给一个登录角色或一个 Supabase 账号】MES-0 §3.3:authenticated 默认执行每一支函数、44 条策略
--   USING (true) —— 一个登录的网关第一天就读得到内部的表;而 db/check_grants.py 只看 anon,一个登录角色它看不见。
-- ⚠★【必须写在这里,写在本文件第一句 REVOKE 的后面】与 cod_verification 同一个理由:apply_migration.sh 把本文件拼在
--   COMMIT 之前、同一个事务里重跑,一条只写在迁移里的 GRANT 会被那句 REVOKE 冲掉,而迁移报告成功。
GRANT EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) TO anon;
-- ★ 而且【只】给 anon(MES-1 Step 0 Q4,Tim):本文件第 31 行把每一支函数授给 authenticated 与 service_role ——
--   给了 authenticated,任何一个登录的人都能冒充网关送数(只要拿得到钥匙)而且绕开网关那条路的全部语义;
--   service_role 是服务端的钥匙,没有一条合法的服务端路径要调它。两个都收回;fixture 249 GRANT 臂两个都断言。
--   ☞ 这两句写在第 31 行【之后】,所以每一次重放都是"先全授、再收回"—— 顺序就是判据。
REVOKE EXECUTE ON FUNCTION public.ingest_submit(text, text, jsonb) FROM authenticated, service_role;

-- MES-1:分派器与转换器是【内层】—— 没有调用者检查,只由 ingest_process_pending / retry_inbox_row(各自查码)以属主身份调。
--   给了 authenticated,就是一支"随便哪一行收件箱都替你转换"的后门,也绕开了处理按钮的那一道码。
REVOKE EXECUTE ON FUNCTION public.ingest_transform_row(bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.transform_connection_test_v1(jsonb) FROM authenticated;

-- MES-2(2026-10-06):四支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   transform_weighing_v1:称重的转换器(分派器与确认按名字调它)。
--   capture_confirm_internal:确认一张草稿(confirm_capture_draft · submit_manual_capture · correct_weighing)。给了 authenticated,
--     就是一支绕开 action.confirm_capture 把草稿写成正式记录的后门。
--   weighbridge_share_internal:把地磅单分一份出去(两支收货函数 · share_weighbridge_ticket)—— 给了,就绕开收货与发货那两个码。
--   assert_receipt_reading_calibrated:校准闸(reprice_inbound_batch · preview_reprice_inbound_batch · issue_cod)。
--   calibration_status_from【不收】:它是一句纯判断(IMMUTABLE,不读任何表),属主视图里由读者的身份执行 —— 收了它,
--   weighing_calibration / instrument_calibration_now 对每一个读者 42501(AGENTS.md「属主视图替得了表,替不了函数的 EXECUTE」)。
REVOKE EXECUTE ON FUNCTION public.transform_weighing_v1(jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_receipt_reading_calibrated(uuid) FROM authenticated;

-- MES-3a(2026-10-06):两支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   receipt_ceiling_check_internal:库存上限的判法与那一行记录(两支收货函数 · create_output_batch)。给了 authenticated,
--     就是一支随手往 receipt_ceiling_checks 里写判法、还能锁执照行的后门。
--   assert_quarantine_landing:隔离闸(两支收货函数 · create_stock_transfer)。
--   quantity_in_tonnes【不收】:一句纯换算(IMMUTABLE),属主视图里由读者的身份执行。
--   storage_licence_in_force【不收】:它是 DEFINER,只回一个 id;storage_ceiling_status 与 pending_values 以读者身份调它。
REVOKE EXECUTE ON FUNCTION public.receipt_ceiling_check_internal(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_quarantine_landing(text[], uuid) FROM authenticated;

-- MES-3b(2026-10-07):三支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   label_object_data:一张标签上印什么(物料名与供应商名以属主身份读 —— Q2 的并入)。给了 authenticated,就是一支绕开 materials /
--     suppliers 的 RLS、按 id 读任何一批物料名与供应商名的后门。调用方:label_print_context。
--   label_print_context:印标签之前的全部判断(种类、查看码、模板、以前印过几次)。调用方:label_print_preview · record_label_print。
--   batch_quarantine_states:一批身上开着的要隔离的状态。调用方:shipment_document · shipping_queue_rows。
--   resolve_scan_code / label_print_preview / record_label_print【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.label_object_data(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.label_print_context(text, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_quarantine_states(uuid) FROM authenticated;

-- MES-4a(2026-10-07):五支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   assert_run_header:一张新加工单的表头说不说得通(commit_processing_run · correct_run_header;以及 processing_runs 的 INSERT 触发器 ——
--     直连插入早在 guard_processing_direct_write 那一步就按名拒了,触发器只在属主路径上真的跑到它)。
--   assert_run_equipment:这一炉的机器(EQP-2a 的三条 + 工序 ↔ 资产)。调用方:commit_processing_run · correct_run_header。给了 authenticated,
--     就是一支按 id 探 fixed_assets(只给财务读)的后门。
--   record_manual_weighing_internal:在提交那一刻落一条手工称重(收件箱 → 转换 → 草稿 → 确认)。给了,就绕开 action.confirm_capture。
--   record_run_value_internal:给一炉记 / 更正一个值。调用方:commit_processing_run · record_run_value · correct_run_value。给了,就绕开
--     action.processing_aftercare 与"加工单必须已提交"那一句。
--   run_event_check:一件异常事件的五样(record_run_event · correct_run_event)。
--   record_run_value / correct_run_value / record_run_event / correct_run_event / record_run_loss / correct_run_loss / close_run_balance /
--   correct_run_header / create_recipe_version / processing_runs_unclosed_balance【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_run_equipment(text, uuid, date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_manual_weighing_internal(numeric, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.record_run_value_internal(uuid, text, jsonb, text, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.run_event_check(text, timestamp with time zone, numeric, text, text) FROM authenticated;

-- MES-4b(2026-10-07):一支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   contamination_check_internal:一次交叉污染抽检的判据与落库(record_contamination_check · correct_contamination_check)。
--     给了 authenticated,就绕开 action.processing_aftercare,也绕开"只能更正链的末端"那一句。
--   set_batch_cell_construction / record_derived_electrolyte_loss / rederive_electrolyte_loss / record_contamination_check /
--   correct_contamination_check【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   guard_batch_cell_construction 是触发器函数(与其余触发器同一条:EXECUTE 只在被直接调用时才有意义)。
REVOKE EXECUTE ON FUNCTION public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text) FROM authenticated;

-- MES-5a-1(2026-10-08):四支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   discharge_result_internal:一条放电模组结果的判据与落库(record / correct_discharge_module_result)—— 给了 authenticated,
--     就绕开 action.confirm_capture,也绕开"只能更正链的末端"。
--   discharge_channel_internal:一条通道分配的判据与落库(assign / correct_discharge_channel)—— 绕开 action.processing_aftercare。
--   discharge_verify_batch:按逐模组结论改一批的安全状态 —— 给了 authenticated,任何人都能把一批"核实"成已放电(火闸的另一侧)。
--   create_stock_transfer_internal:库存转移的函数体(create_stock_transfer 判 module.inventory.edit 后转交;拆去隔离判
--     action.processing_aftercare 后转交)—— 给了 authenticated,就绕开库存编辑码。
--   guard_batch_module_count 是 SECURITY DEFINER 的触发器函数(它要数放电结果、读安全状态,不能被 RLS 数成 0);
--     触发器触发时不查 EXECUTE,所以收回它只关掉"被直接调用"那一条路。
--   set_batch_module_count / record_discharge_module_result / correct_discharge_module_result / assign_discharge_channel /
--   correct_discharge_channel / split_failed_modules_to_quarantine【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, uuid, text, text, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.discharge_verify_batch(text, uuid, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_batch_module_count() FROM authenticated;

-- MES-5a-2(2026-10-08):两支【内层】—— 没有调用者检查,只由各自查过码的 DEFINER 函数以属主身份调。
--   meter_reading_internal:一条电表读数的判据与落库(record / correct_meter_reading)—— 给了 authenticated,就绕开 action.confirm_capture,
--     也绕开"只能更正链的末端"。
--   electricity_allocation_compute:电费单怎么分(preview / post_electricity_allocation)—— 它自己不写任何东西,但它不查码,
--     而它读的是电表读数、各炉的电量与运行时长、估计的金额(加工成本的金额要 data.view_prices);给了 authenticated 就是一支绕开那道遮蔽的读法。
--   record_meter_reading / correct_meter_reading / preview_electricity_allocation / post_electricity_allocation / set_electricity_shared_pool_rule
--   【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.meter_reading_internal(uuid, timestamp with time zone, numeric, boolean, text, text, boolean, bigint, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.electricity_allocation_compute(date, date, numeric, numeric, text, text, text) FROM authenticated;

-- MES-5b-2(2026-10-09):一支【内层】与一支触发器函数。
--   reverse_expense_internal:冲一张费用单的那一段(reverse_expense 与 reverse_electricity_allocation 共用)—— 它不查码;给了 authenticated
--     就是一支绕开 module.finance.edit、也绕开"电费分摊的费用单只许整张撤回"的冲销。
--   guard_electricity_line_one_live_allocation:分摊行的插入守卫(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上)。
--   reverse_electricity_allocation【不收】:它是 DEFINER,自己查码,员工就是要调它。
REVOKE EXECUTE ON FUNCTION public.reverse_expense_internal(uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_electricity_line_one_live_allocation() FROM authenticated;

-- MES-5b-3(2026-10-09):一支【内层】与两支触发器函数。
--   blending_plan_write_children:配料计划的判据与落库(create / amend_blending_plan 共用;INVOKER,在它们里面以属主身份跑)—— 它不查码;给了 authenticated
--     就是一支绕开 action.wo_create、也绕开"只有草稿改得动"的写法。
--   guard_blending_run_from_plan · guard_blended_batch_metals_from_assay:触发器函数(触发时不查 EXECUTE,收掉只是让它们不在 API 上;
--     后一支是 DEFINER,更不该在 API 上)。
--   create / amend / release / cancel / execute_blending_plan【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_blending_plan_code【不收】:与 next_work_order_code 一样,是一支只读的取号函数(读 document_types 与编号的最大值)。
REVOKE EXECUTE ON FUNCTION public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_blending_run_from_plan() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_blended_batch_metals_from_assay() FROM authenticated;

-- MES-6a-1(2026-10-09):一支触发器函数。
--   guard_assay_sample_batch:化验指着的样品必须是同一批的(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上 —— 它是 DEFINER,更不该在)。
--   record_sample / record_sample_event / set_quality_settings / open_assay_dispute / record_dispute_umpire / withdraw_assay_dispute /
--   resolve_assay_dispute / link_dispute_fee【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_sample_code【不收】:与 next_blending_plan_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_assay_sample_batch() FROM authenticated;

-- MES-6a-2(2026-10-10):一支触发器函数与一支【内层】。
--   guard_substance_role:定价那几张表只收按含量计价的金属、惩罚条款只收惩罚元素(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上)。
--   payable_metals_only:把一张含量清单里的惩罚元素拿掉(只给那几支 DEFINER 计价读者在体内用;给了 authenticated 也只是一支无害的过滤器,
--     收掉是让 API 上少一支没有屏幕的函数)。
--   record_assay_result 的新签名(尾部多了 p_indicators)【不收】:它是 DEFINER,自己查码,员工就是要调它(上面那一句整体授权覆盖它)。
REVOKE EXECUTE ON FUNCTION public.guard_substance_role() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payable_metals_only(jsonb) FROM authenticated;

-- MES-6b-1(2026-10-15):三支触发器函数与两支【内层】。
--   guard_quality_hold:质量暂扣守在流水上(触发器函数;触发时不查 EXECUTE,收掉只是让它不在 API 上 —— 它是 DEFINER,更不该在)。
--   guard_substance_priced_and_penalised:一种物质在一份合同里要么计价、要么罚(触发器函数,DEFINER)。
--   guard_ncr_mutation:不合格报告只追加(触发器函数)。
--   ncr_open_internal:落一张不合格报告(取号、写一行)—— 不问码、不判来源;给了 authenticated 就是一支绕开 module.quality.edit、
--     也绕开"系统才开 quality_limit"的写法。
--   judge_quality_limits:判一批对一张单的质量验收限并在越限时开报告 —— 不问码;只在 record_assay_result / reserve_stock_internal 里以属主身份跑。
--   open_ncr / decide_ncr【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   batch_quality_hold【不收】:它是 INVOKER,以调用者的读规则读(销售结算的预览以读者身份调它);assay_is_supplement 同理【不收】。
--   next_ncr_code【不收】:与 next_sample_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_quality_hold() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_substance_priced_and_penalised() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_ncr_mutation() FROM authenticated;
-- MES-7b-1:末尾多了 p_incident_id(来源 incident 的那一张指着的事故)—— 签名换了,这一行跟着换。
-- MES-7b-2:末尾又多了 p_inspection_finding_id(来源 inspection 的那一张引用的巡检发现)—— 签名又换了,这一行再跟着换。
REVOKE EXECUTE ON FUNCTION public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.judge_quality_limits(uuid, uuid, text) FROM authenticated;

-- MES-6b-2(2026-10-15):一支触发器函数与五支【内层】。
--   guard_coa_mutation:分析证书签发之后只许作废、作废之后只许填一次替代品(触发器函数)。
--   coa_governing_assay · coa_output_calibration_problem · coa_issue_blockers · coa_assemble:证书说话的那一份化验、称重的校准、拒绝清单、
--     纸上每一个值 —— 不问码,以属主身份读批次、化验、争议、报告、合同副本与客户名;给了 authenticated 就是一扇绕开 module.output.view
--     读这些的门。外面经 coa_certificate_data(查 module.output.view)与 issue_coa(查 action.issue_coa)读它们。
--   void_coa_internal:作废一张分析证书 —— 只经 CFO 批准的 coa_void 申请走到这里;给了 authenticated 就是一扇绕开 CFO 的作废门。
--   issue_coa / record_coa_issue / submit_coa_void_request / coa_certificate_data【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
--   next_coa_code【不收】:与 next_ncr_code 一样,是一支只读的取号函数。
REVOKE EXECUTE ON FUNCTION public.guard_coa_mutation() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_governing_assay(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_output_calibration_problem(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_issue_blockers(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.coa_assemble(uuid, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.void_coa_internal(uuid, text, uuid) FROM authenticated;
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q3 · Q6):设备记录的内层与触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_downtime_cause · guard_downtime_cause_class · guard_equipment_direct_write:触发器函数(停机的原因与来源 · 被引用的原因类别冻住 ·
--     三张设备表不许绕过函数写)。
--   equipment_record_target · downtime_cause_check:五支设备记录函数共用的两句判据(一台在册的机器 · 一个能用的原因代号)。
--     调用方都是 DEFINER(open_ · close_ · correct_equipment_downtime · record_equipment_maintenance · save_equipment_service_interval),
--     以属主身份读 fixed_assets 与 downtime_causes。
--   那五支、equipment_reliability 与 coa_issuer【不收】:它们是 DEFINER,自己查码,员工就是要调它们。
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_downtime_cause_class() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_equipment_direct_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.equipment_record_target(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.downtime_cause_check(text) FROM authenticated;
-- MES-7a-2(2026-10-16,MES-7a Step 0 Q12 · Q13 · Q14):备件出库的内层与触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_maintenance_movement · guard_part_issue_write · guard_maintenance_capitalise_parts:触发器函数(两种保养流水只经那两支函数 ·
--     出库记录只可追加、只经函数写 · 还挂着件的保养记录不能资本化)。
--   inbound_batch_maintenance_net_qty:一批出给保养的净数量 —— 只在 reprice_inbound_batch · preview_reprice_inbound_batch ·
--     inventory_control_reconciliation(都是 DEFINER)里被调用;它不问码。
--   issue_spare_parts · return_spare_parts【不收】:它们是 DEFINER,自己查 module.inventory.edit,员工就是要调它们。
--   reprice_split【不收】(签名换成五个入参):纯算术,IMMUTABLE,不读任何表 —— 与它换签名之前一样。
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_movement() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_part_issue_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_maintenance_capitalise_parts() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.inbound_batch_maintenance_net_qty(uuid) FROM authenticated;
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q4 · Q7):事故登记簿的四支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_incident_kind_code(用过的种类代号冻住)· guard_incident_write(事故写下就不改、只经函数写、来源 / 时刻 / 种类 / 停机 / 事件的行规矩)·
--   guard_incident_update_write(之后的事实只可追加、只经函数写)· guard_incident_batch_write(链接只经函数写、只在解链接那一次改)。
--   record_incident · record_incident_update · link_incident_batch · unlink_incident_batch · suggest_incident_batches · set_safety_settings【不收】:
--   它们是 DEFINER,自己查码(module.safety.edit / module.safety.view),员工就是要调它们。
--   business_days_after · next_incident_code【不收】:一支只读公共假期表的算术、一支只读的取号函数(与 next_ncr_code 一样)。
REVOKE EXECUTE ON FUNCTION public.guard_incident_kind_code() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_update_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_incident_batch_write() FROM authenticated;
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q14 · Q16):巡检与环境监测的四支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_inspection_template_write(清单与检查项只经函数写、清单不许删)· guard_inspection_record_write(巡检 / 结果 / 发现 / 关闭交了就不改、
--   只经函数写、发现只挂在不合格的那一项上)· guard_environmental_parameter_code(限值成对、用过的代号冻住)· guard_environmental_result_write
--   (结果只追加、只经函数写、采样日不在未来)。
--   save_inspection_template · record_inspection_run · record_inspection_finding · close_inspection_finding · raise_inspection_finding_task ·
--   record_environmental_result【不收】:它们是 DEFINER,自己查码(module.safety.edit / module.safety.view),员工就是要调它们。
--   next_inspection_code【不收】:一支只读的取号函数(与 next_incident_code 一样)。
REVOKE EXECUTE ON FUNCTION public.guard_inspection_template_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_inspection_record_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_environmental_parameter_code() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_environmental_result_write() FROM authenticated;
-- MES-8a(2026-10-16,MES-8 Step 0 Q2 · Q5 · Q7):三支触发器函数与一支内层 —— 没有调用者检查,靠的就是调不到。
--   guard_supplier_scorecard_review_write(评审只追加)· guard_supplier_statement_write(签发了的对账单只许被取代)·
--   guard_supplier_statement_issue_write(签发档只追加)·
--   supplier_grade_advice_internal(等级建议的那一份实现;create_purchase_order 调它,对外的是 supplier_grade_advice,查 module.suppliers.view)。
--   supplier_scorecard_measures · supplier_scorecard_preview · record_supplier_review · set_supplier_score_settings · supplier_grade_advice ·
--   supplier_statement_data · issue_supplier_statement · record_supplier_statement_issue【不收】:它们是 DEFINER,自己查码。
--   supplier_scorecard_measure_keys · supplier_scorecard_grade · next_supplier_statement_code【不收】:纯函数 / 取号,不读不写别人的东西。
REVOKE EXECUTE ON FUNCTION public.guard_supplier_scorecard_review_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_supplier_statement_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_supplier_statement_issue_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.supplier_grade_advice_internal(uuid, jsonb, numeric) FROM authenticated;
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q10 · Q12 · Q14–Q17):两支触发器函数 —— 没有调用者检查,靠的就是调不到。
--   guard_compliance_pack_write(冻下来的包只许被取代)· guard_compliance_pack_issue_write(签发档只追加)。
--   inbound_batch_margin · inventory_metal_exposure · compliance_pack_data · freeze_compliance_pack · record_compliance_pack_issue ·
--   set_compliance_settings · compliance_pack_month_status【不收】:它们是 DEFINER,自己查码。
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_write() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_compliance_pack_issue_write() FROM authenticated;
-- MES-8b-2(2026-10-17,MES-8 Step 0 Q19 · Q20):本刀没有要收的函数 —— floor_board · set_floor_board_settings · session_is_floor_display_only 是 DEFINER,
--   自己查码(session_is_floor_display_only 只读调用者自己的授权,所以对每一个登录的人开放);floor_board_arms 是纯函数,不读任何表。

-- ════════════════════════════════════════════════════════════════════════════
-- MES-9a(2026-10-19,MES-9 Step 0 Q2 · Q3 · Q11 · Q27,Tim):【供应商门户】—— 三类函数,三种授法。
-- ════════════════════════════════════════════════════════════════════════════
-- ① 门户会话调的(portal_me · portal_export_my_data):【只】授 supplier_portal。authenticated 与 service_role 从第 31 行那一句拿到的收回 ——
--    一个员工会话(或 hook 被关掉之后拿着 authenticated 令牌的门户账号)调它们是 42501,门户看得见地停下(Q11)。
--    supplier_portal 能执行的每一支都在 db/portal-grants-baseline.tsv 里(判词八,两侧逐条相等);fixture 275 对其中每一支跑两家供应商。
REVOKE EXECUTE ON FUNCTION public.portal_me() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_export_my_data() FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_me() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_export_my_data() TO supplier_portal;
-- ② 内层判据 portal_require_link:谁都不授 —— 只由 ① 在它们自己的 DEFINER 体内调用(属主身份)。
REVOKE EXECUTE ON FUNCTION public.portal_require_link() FROM authenticated, service_role;
-- ③ access token hook:只授 supabase_auth_admin(Supabase Auth 调它的那个身份)。它对每一个人的每一次签发都跑,
--    authenticated / anon / service_role 都没有理由调它。
REVOKE EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) TO supabase_auth_admin;
-- 员工那一侧的(portal_user_create_link · portal_user_revoke · portal_contact_anonymise · portal_actor_labels · set_account_setting)
--   照第 31 行授给 authenticated —— 它们是 DEFINER,自己查码(action.manage_portal_users / action.manage_permissions)或会话(auth.uid())。
-- ④ MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q22):供应商看得见什么 —— 四支,同 ① 的授法:【只】授 supplier_portal。
--    portal_documents · portal_deliveries(清单,只读)· portal_document_open(写调用者自己的一行下载记录,交出路径与哈希)·
--    portal_can_read_object(storage.objects 上那条 TO supplier_portal 的读策略的判据 —— 策略以调用者身份求值,所以门户角色要执行得到它)。
--    fixture 276 对其中每一支跑两家供应商;判词八逐条比基线。
REVOKE EXECUTE ON FUNCTION public.portal_documents() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_deliveries() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_document_open(text, uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_can_read_object(text, text) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_documents() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_deliveries() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_document_open(text, uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_can_read_object(text, text) TO supplier_portal;
-- ⑤ MES-9c(2026-10-20,MES-9 Step 0 §5 · Q19 · V39):门户交证书 —— 五支,同 ① 的授法:【只】授 supplier_portal。
--    portal_certificates(清单与 V39)· portal_submission_begin(先按 V39 判,登记一行 uploading)· portal_submission_finish(字节到了 → 等审核)·
--    portal_submission_abandon(没传成 → 收回)· portal_can_upload_object(portal-uploads 上两条 TO supplier_portal 策略的判据)。
--    fixture 277 对其中每一支跑两家供应商;判词八逐条比基线。员工审核那两支(portal_submission_accept · _reject)照第 31 行授给
--    authenticated —— DEFINER,自己查 module.suppliers.edit(Q19)。
REVOKE EXECUTE ON FUNCTION public.portal_certificates() FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_begin(text, text, text, bigint, text, date, date) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_finish(uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_abandon(uuid) FROM authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_can_upload_object(text, text) FROM authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_certificates() TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_begin(text, text, text, bigint, text, date, date) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_finish(uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_submission_abandon(uuid) TO supplier_portal;
GRANT EXECUTE ON FUNCTION public.portal_can_upload_object(text, text) TO supplier_portal;

-- ════════════════════════════════════════════════════════════════════════════
-- F16(MES-7b-2,2026-10-16,Tim):【视图一律不可写】—— 收回 anon / authenticated(与 PUBLIC)在 public 里【每一张视图】上的
--   INSERT · UPDATE · DELETE · TRUNCATE。
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么】平台的默认权限把 arwdDxtm 授给每一个新建的关系,视图也一样;而一张【简单】的属主权限视图是可以自动更新的 ——
--   写穿它,对基表用的是【视图属主】的权限,RLS 不按调用者判。MES-7b-1 量到 163 张视图对 authenticated 带着写授权
--   (MES7B1-VIEW-DEFAULT-WRITE-GRANTS);MES-7b-2 在线上以一个不持任何码的一次性账号量:45 张视图收下了一句零行的写
--   (db/scripts/2026-10-16-mes7b2-view-writes.mjs)。应用与 db/ 里没有一处写穿视图(F16 第 2 步的勘察,交回报告里逐条列着)。
-- 【为什么住在这个文件里】这个文件在重建的最后一步跑(视图都建好了),而 db/apply_migration.sh 在【每一支迁移的同一个事务里】再跑它一遍 ——
--   于是"以后的视图也拿不到写授权"不靠任何人记得:一支迁移建了一张新视图,它提交的那一刻这一段已经把写授权收回了。
--   ★ 那正是委托书"默认权限也要改"那一句要的结果。PostgreSQL 的 ALTER DEFAULT PRIVILEGES 分不出视图与表(对象类型只有 TABLES 一种),
--     在线上把它改成"不授写"会让【以后的每一张新表】也拿不到 authenticated 的写 —— 而 303 份表镜像里 273 份靠的就是那条默认授权,
--     重建库(prelude 照旧按默认授)与线上会在每一张新表上悄悄分开。所以本刀【不改】默认权限,改用这一段 + gate 的 viewwrite 断言
--     (线上与重建两侧都问:任何一张视图对 anon / authenticated 带写授权就红)。
-- 【幂等】对一张没有写授权的视图 REVOKE 是空操作;跑两遍不改任何 relacl。
DO $f16$
DECLARE
    v record;
BEGIN
    FOR v IN SELECT c.oid::regclass AS rel
               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind = 'v'
              ORDER BY c.relname LOOP
        EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON %s FROM PUBLIC, anon, authenticated', v.rel);
    END LOOP;
END
$f16$;

-- ★ SYSTEM-MAP-2(2026-10-27):self_approval_allows 是 forbid_self_approval 的判据(从它搬出来的),经 self_leg /
--   self_approval_exception 去问(两者都已收回)—— 与它们同一条理由收回。waiting_decisions / waiting_mine /
--   waiting_decision_reach 【不收】:它们是 SECURITY DEFINER,只答【调用者自己】(auth.uid() / current_user_employee()),
--   operations_now(属主视图)调用 waiting_decisions,而视图里的函数按读者判 EXECUTE。
REVOKE EXECUTE ON FUNCTION public.self_approval_allows(uuid, uuid, text, uuid) FROM authenticated;

-- GOLIVE-2(Tim 2026-10-30 Q5):结算的算术只由 record_sale_settlement(SECURITY DEFINER,先问 module.customers.edit,不持 data.view_prices
--   时把六样钱读成受限)调用。它自己是 SECURITY INVOKER、没有价格码的判断 —— 留着 authenticated 的 EXECUTE,任何登录用户都能直接调它,
--   绕过 sales_settlements_masked 拿到结算金额(app / lib 里没有任何一处调它)。收回之后它照常在 record_sale_settlement 的函数体里以属主身份跑。
REVOKE EXECUTE ON FUNCTION public.sale_settlement_compute(uuid, uuid, uuid) FROM authenticated;

SELECT 'PROOF|B|postgres|' || json_build_object(
  'new_code_holders', (SELECT COALESCE(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code), 'none')
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                    WHERE rp.permission_code IN ('action.manage_esg','data.view_whistleblowing','data.view_whistleblowing_escalated')),
  'grants_total', (SELECT count(*) FROM public.role_permissions),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t),
  'new_tables', (SELECT COALESCE(string_agg(relname, ',' ORDER BY relname), 'none') FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ('esg_settings','grid_emission_factors','required_trainings','company_policies','whistleblowing_reports','whistleblowing_updates','incident_days_lost_corrections')),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'incidents', (SELECT count(*) FROM public.incidents), 'training_records', (SELECT count(*) FROM public.training_records),
  'approvals', (SELECT approvals_enabled FROM public.finance_settings),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM public.ingest_settings))::text;
SELECT 'PROOF|B|postgres|settings ' || (SELECT count(*) FROM public.esg_settings) || ' row, hours=' || COALESCE((SELECT standard_hours_per_day::text FROM public.esg_settings), 'NULL')
  || ' · factors=' || (SELECT count(*) FROM public.grid_emission_factors) || ' · exclusions=' || (SELECT count(*) FROM public.change_log_exclusions())
  || ' · coverage_gaps=' || jsonb_array_length(public.change_log_coverage_gaps() -> 'gaps');
RESET ROLE;
SELECT set_config('request.jwt.claims', json_build_object('sub', ('634c00f9-c3a9-4444-9eed-b624cb6a2a93'), 'role', 'authenticated')::text, true) \g /dev/null
SELECT 'PROOF|B|cfo|session uid ' || COALESCE(auth.uid()::text, 'NULL');
SET LOCAL ROLE authenticated;
SELECT 'PROOF|B|cfo|rates ' || (SELECT count(*) FROM public.esg_safety_rates(EXTRACT(year FROM now())::int)) || ' rows · injury_visible=' || COALESCE((SELECT bool_and(injury_visible)::text FROM public.esg_safety_rates(EXTRACT(year FROM now())::int)), 'none') || ' · ytd_state=' || (SELECT hours_state FROM public.esg_safety_rates(EXTRACT(year FROM now())::int) WHERE month IS NULL);
SELECT 'PROOF|B|cfo|readable(escalated)=' || public.whistleblowing_report_readable(true) || ' readable(plain)=' || public.whistleblowing_report_readable(false);
SELECT 'PROOF|B|cfo|report_rows=' || (SELECT count(*) FROM public.whistleblowing_report_rows) || ' scope2_bills=' || (SELECT count(*) FROM public.esg_scope2_bills()) || ' my_concerns=' || (SELECT count(*) FROM public.my_concerns()) || ' policies=' || (SELECT count(*) FROM public.company_policy_rows);
RESET ROLE;
RESET ROLE;
SELECT set_config('request.jwt.claims', json_build_object('sub', ((SELECT ur.user_id::text FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id WHERE r.code = 'cco' AND ur.revoked_at IS NULL ORDER BY ur.user_id LIMIT 1)), 'role', 'authenticated')::text, true) \g /dev/null
SELECT 'PROOF|B|cco|session uid ' || COALESCE(auth.uid()::text, 'NULL');
SET LOCAL ROLE authenticated;
SELECT 'PROOF|B|cco|readable(escalated)=' || public.whistleblowing_report_readable(true) || ' readable(plain)=' || public.whistleblowing_report_readable(false);
RESET ROLE;
RESET ROLE;
SELECT set_config('request.jwt.claims', json_build_object('sub', ((SELECT ur.user_id::text FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id WHERE r.code = 'admin' AND ur.revoked_at IS NULL ORDER BY ur.user_id LIMIT 1)), 'role', 'authenticated')::text, true) \g /dev/null
SELECT 'PROOF|B|admin|session uid ' || COALESCE(auth.uid()::text, 'NULL');
SET LOCAL ROLE authenticated;
SELECT 'PROOF|B|admin|readable(escalated)=' || public.whistleblowing_report_readable(true) || ' readable(plain)=' || public.whistleblowing_report_readable(false);
DO $a$ BEGIN PERFORM public.esg_set_standard_hours(25); RAISE NOTICE 'PROOF|B|admin|set_standard_hours(25) returned (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|admin|set_standard_hours(25) refused %', SQLERRM; END $a$;
RESET ROLE;
RESET ROLE;
SELECT set_config('request.jwt.claims', json_build_object('sub', ('c8116e6c-80db-4a16-be12-24fb6ce6859d'), 'role', 'authenticated')::text, true) \g /dev/null
SELECT 'PROOF|B|warehouse|session uid ' || COALESCE(auth.uid()::text, 'NULL');
SET LOCAL ROLE authenticated;
DO $w$ BEGIN PERFORM public.esg_set_grid_factor(2024, 0.4, 'x'); RAISE NOTICE 'PROOF|B|warehouse|set_grid_factor returned (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|warehouse|set_grid_factor refused %', SQLERRM; END $w$;
SELECT 'PROOF|B|warehouse|rates injury_visible=' || COALESCE((SELECT bool_or(injury_visible)::text FROM public.esg_safety_rates(EXTRACT(year FROM now())::int)), 'none') || ' · report_rows=' || (SELECT count(*) FROM public.whistleblowing_report_rows);
RESET ROLE;
ROLLBACK;
SELECT 'PROOF|C|after rollback|new_tables=' || COALESCE((SELECT string_agg(relname, ',') FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ('esg_settings','grid_emission_factors','required_trainings','company_policies','whistleblowing_reports','whistleblowing_updates','incident_days_lost_corrections')), 'none') || ' new_codes=' || (SELECT count(*) FROM public.permissions WHERE code IN ('action.manage_esg','data.view_whistleblowing','data.view_whistleblowing_escalated'));

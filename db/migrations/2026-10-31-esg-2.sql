-- db/migrations/2026-10-31-esg-2.sql
-- ESG-2(v1.4.86)—— Scope 2 与电网排放因子、误工事故频率、培训合规、公司制度登记簿与举报登记簿。Tim 2026-10-30(SYSTEM-MAP-4 Q1)与 2026-10-31 Q1–Q15。
--   由 db/scripts/build_esg2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】
--   ① 三个新码:action.manage_esg(admin · cco · cfo,Q9)· data.view_whistleblowing(cco)· data.view_whistleblowing_escalated(cfo,Q13)。
--      两个举报码都不授 admin(Q13 的例外,docs/role-matrix.md §13)。别的角色、任何账号的角色一个都不动。
--   ② 七张新表:esg_settings(标准日工时,单行,空)· grid_emission_factors(一年一个、带历史,空 —— Q1)· required_trainings ·
--      company_policies · whistleblowing_reports · whistleblowing_updates · incident_days_lost_corrections;training_records 加一列 required_training_id。
--   ③ 十八支函数(两支判据 + 十六支读 / 写)与三张视图(company_policy_rows · whistleblowing_report_rows 新建;incident_rows 换掉 days_lost 的算法、
--      末尾加两列)。
--   ④ 五张新表进变更记录;两张举报表登记为豁免(带理由,change_log_exclusions 换一版)。
-- 【不做什么】不碰审批开关、hook、任何存储桶与存储策略、任何账号;不改任何既有表的行;require_calibrated_since 保持空;不设任何值(因子与工时都留空,Q1 · Q4)。
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):没有 —— 新对象旧应用不读;incident_rows 只在末尾加列、days_lost 在没有更正时与原来同值;
--   training_records 多一列,旧应用的插入不写它(可空)。
-- 镜像(同一个提交):db/tables/{七张新表,training_records,permissions,role_permissions}.sql · db/functions/ 上面那十八支与 change_log_exclusions ·
--   db/views/{company_policy_rows,whistleblowing_report_rows,incident_rows,zzz_change_log_triggers}.sql · db/seeds/{eleven,seven}-roles-2026-10-31.sql。
-- 运行期配置的表:esg_settings(新建,引导一行、值为空 —— 引导默认值是对的:不猜一个 8)。
BEGIN;

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

COMMIT;

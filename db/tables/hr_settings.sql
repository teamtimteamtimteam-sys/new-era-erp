-- db/tables/hr_settings.sql
-- HR 的可配置门槛:医疗报销额度、是否按月折算、每周工作天数、结转月数。单行配置表。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 写入策略是特意开的(module.hr.edit 的 UPDATE;刻意不给 insert/delete —— 单行固定,值要可调)。working_days_per_week 直接进假期补偿公式。
-- 所以【线上与本文件不一致是正常的,不是漂移】,check_mirrors.py 不把本表与线上比对。
-- 它只保证镜像这一套自己首尾相顾(本文件引用到的码/科目都存在于对应的种子里)。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE public.hr_settings (
    id                     boolean PRIMARY KEY DEFAULT true CHECK (id),
    medical_annual_limit_sgd numeric NOT NULL DEFAULT 1000,
    medical_pro_rate_for_joiners boolean NOT NULL DEFAULT true,
    -- 补偿日薪的算法基数。MOM 对月薪员工的"一日工资"定义是:
    --     12 × 月薪 ÷ (52 × 每周工作天数)
    -- 每周 5 天时得 12/(52×5) = 1/21.667。这里存【每周工作天数】而不是存 21.75,
    -- 因为前者是 MOM 公式里的那个参数,后者只是它在 5 天工作制下的近似值。
    working_days_per_week  numeric NOT NULL DEFAULT 5 CHECK (working_days_per_week > 0),
    -- 结转的年假在授予年度之后多少个月失效
    carry_forward_months   integer NOT NULL DEFAULT 12,
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid DEFAULT auth.uid(),
    -- ── PDPA-1 追加 ──────────────────────────────────────────────────────────
    -- 【可空,而且刻意没有 DEFAULT】离职之后个人数据还留多少个月 —— 这是一个
    -- 【法律问题】(《雇佣法》与 CPF 各有最短保留年限),这套系统不替人回答。
    -- anonymise_employee() 在它为空时按名拒绝 PDPA_RETENTION_PERIOD_NOT_SET。
    -- **一个默认值在这里等于让一个数字替人做出法律表态。** 见 docs/pdpa.md 第二节。
    personal_data_retention_months integer
        CHECK (personal_data_retention_months IS NULL OR personal_data_retention_months > 0)
);

CREATE TRIGGER trg_hr_settings_updated_at
    BEFORE UPDATE ON public.hr_settings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.hr_settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "hr_settings select by permission"
    ON public.hr_settings AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "hr_settings update by permission"
    ON public.hr_settings AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));

INSERT INTO public.hr_settings (id) VALUES (true);

COMMENT ON COLUMN public.hr_settings.personal_data_retention_months IS
    '离职之后,员工个人数据还保留多少个月 —— 到期即可匿名化(PDPA 的"目的结束后不再保留")。

**可空,而且【没有默认值】,这是刻意的。** 这是一个法律问题:新加坡《雇佣法》与
公积金各有各的最短保留年限,而这套系统不该替人回答。`anonymise_employee` 在它为空时
**按名拒绝运行** —— 一个默认值在这里等于让一个数字替人做出法律表态。
Tim 正在拿这个答案;拿到之前这条路是关着的,而它关着的事实是看得见的。';

-- ============================================================================

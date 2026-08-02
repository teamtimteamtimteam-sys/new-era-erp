-- db/tables/leave_types.sql
-- 假别目录。【配置,不是枚举】—— 天数、是否需要医生证明、是否累积,全是行里的值。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 界面上可以改(app/hr/leave/types/actions.ts:25 的 update)。
-- 所以【线上与本文件不一致是正常的,不是漂移】,check_mirrors.py 不把本表与线上比对。
-- 它只保证镜像这一套自己首尾相顾(本文件引用到的码/科目都存在于对应的种子里)。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE public.leave_types (
    code                           text PRIMARY KEY,
    name_en                        text NOT NULL,
    name_zh                        text NOT NULL,
    description_en                 text,
    description_zh                 text,
    is_paid                        boolean NOT NULL DEFAULT true,
    -- is_accrued:只有会累积成余额的假别为 true(目前只有年假)。
    -- 病假之类是"每年一个上限",不结转、不补偿,因此不是 accrued。
    is_accrued                     boolean NOT NULL DEFAULT false,
    default_days_per_year          numeric,
    -- null = 从不需要证明。年假 null;病假 3(手册的"3 天内凭诚信")。
    requires_certificate_after_days numeric,
    requires_approval              boolean NOT NULL DEFAULT true,
    allows_half_day                boolean NOT NULL DEFAULT true,
    -- 【记录但无法强制】—— employees 表没有性别列,见文件末尾的缺口说明。
    gender_restriction             text CHECK (gender_restriction IN ('female','male') OR gender_restriction IS NULL),
    is_active                      boolean NOT NULL DEFAULT true,
    sort_order                     integer NOT NULL DEFAULT 0,
    notes                          text,
    created_at                     timestamptz NOT NULL DEFAULT now(),
    created_by                     uuid DEFAULT auth.uid(),
    updated_at                     timestamptz NOT NULL DEFAULT now(),
    updated_by                     uuid DEFAULT auth.uid()
);

CREATE TRIGGER trg_leave_types_updated_at
    BEFORE UPDATE ON public.leave_types
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.leave_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_types select by permission"
    ON public.leave_types AS PERMISSIVE FOR SELECT TO authenticated
    -- 假别目录人人可读:每个员工都要知道有哪些假可以请
    USING (true);
CREATE POLICY "leave_types insert by permission"
    ON public.leave_types AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_types update by permission"
    ON public.leave_types AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_types delete by permission"
    ON public.leave_types AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 播种。【法定数字来源:新加坡人力部(MOM)/ Made For Families,2026-08 查证】
-- ⚠️ 全部需要 Tim 核对;非法定项标注为【公司政策·占位】。
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.leave_types
    (code, name_en, name_zh, description_en, description_zh,
     is_paid, is_accrued, default_days_per_year, requires_certificate_after_days,
     requires_approval, allows_half_day, gender_restriction, sort_order, notes) VALUES

-- 年假:天数【不来自这里】,来自 leave_accrual_rates(办公室 24 / 现场 18 天每年,按月累积)。
-- default_days_per_year 留空,免得两处数字打架。
('annual', 'Annual Leave', '年假',
 'Paid annual leave. Earned monthly; the rate comes from leave_accrual_rates, not this table.',
 '带薪年假。按月累积;费率取自 leave_accrual_rates,不取自本表。',
 true, true, NULL, NULL, true, true, NULL, 10,
 'Entitlement source: leave_accrual_rates (office 24 / shopfloor 18 days per year, accrued monthly). Statutory minimum under the Employment Act is 7 days rising to 14 with service — the company figure is well above it.'),

-- 病假(门诊):MOM 法定 14 天(服务满 6 个月)。
-- requires_certificate_after_days = 3 是【公司的诚信制】:3 天以内不需医生证明。
-- 注意这比法定更宽松 —— 法定上病假本就需要证明,公司选择前 3 天不查。
('sick', 'Sick Leave (Outpatient)', '病假(门诊)',
 'Paid outpatient sick leave. Up to 3 days per calendar year on trust; a medical certificate is required beyond that.',
 '带薪门诊病假。每公历年 3 天以内凭诚信,超过则需医生证明。',
 true, false, 14, 3, true, true, NULL, 20,
 'MOM: 14 days paid outpatient sick leave for employees with at least 6 months service (pro-rated below that). The 3-day certificate-free allowance is company policy, more generous than statute.'),

-- 住院假:MOM 法定 60 天,【含】上面的 14 天门诊。
('hospitalisation', 'Hospitalisation Leave', '住院假',
 'Paid hospitalisation leave. Requires a medical certificate or hospitalisation record.',
 '带薪住院假,需医生证明或住院记录。',
 true, false, 60, 0, true, false, NULL, 30,
 'MOM: up to 60 days paid hospitalisation leave, INCLUSIVE of the 14 outpatient days — not additional to them.'),

-- 产假:16 周 = 112 个日历日。
-- ⚠️ 产假按【日历周】计,不是工作日 —— calculate_leave_days 的工作日口径不适用,
--    HR 按实际起止日期录入即可。
('maternity', 'Maternity Leave', '产假',
 'Government-Paid Maternity Leave, 16 weeks. Taken in calendar weeks, not working days.',
 '政府支付产假 16 周。按日历周计,不按工作日。',
 true, false, 112, NULL, true, false, 'female', 40,
 'MOM/Made For Families: 16 weeks GPML for a Singapore citizen child (12 weeks otherwise). 112 = 16 calendar weeks. Eligibility (citizenship of child, service length) is checked by HR at approval — deliberately not encoded.'),

-- 陪产假:4 周 = 28 个日历日(2025-04 起由 2 周加倍为 4 周,已强制)。
('paternity', 'Paternity Leave', '陪产假',
 'Government-Paid Paternity Leave, 4 weeks. Taken in calendar weeks.',
 '政府支付陪产假 4 周。按日历周计。',
 true, false, 28, NULL, true, false, 'male', 50,
 'MOM: 4 weeks GPPL, mandatory since 1 April 2025 (doubled from 2 weeks). 28 = 4 calendar weeks. Eligibility checked by HR at approval.'),

-- 共享育儿假:10 周(2026-04-01 及以后出生的孩子);此前为 6 周。
('shared_parental', 'Shared Parental Leave', '共享育儿假',
 'Shared Parental Leave, a pool shared between parents. 10 weeks for children born on or after 1 April 2026.',
 '父母共享的育儿假额度。2026 年 4 月 1 日及以后出生的孩子为 10 周。',
 true, false, 70, NULL, true, false, NULL, 60,
 'MOM: SPL pool is 10 weeks for children born on/after 1 Apr 2026 (6 weeks for those born on/after 1 Apr 2025). 70 = 10 calendar weeks. How the pool is split between parents is agreed outside this system.'),

-- 育儿假:6 天(新加坡籍子女,7 岁以下)。
('childcare', 'Childcare Leave', '育儿假',
 'Government-Paid Childcare Leave, 6 days per year per parent.',
 '政府支付育儿假,每位家长每年 6 天。',
 true, false, 6, NULL, true, true, NULL, 70,
 'MOM: 6 days per parent per year where the child is a Singapore citizen under 7. Non-citizen child is 2 days. Eligibility depends on the child''s citizenship and age — HR checks this at approval; deliberately NOT encoded here.'),

-- 延长育儿假:2 天(子女 7–12 岁)。
('extended_childcare', 'Extended Childcare Leave', '延长育儿假',
 'Extended Childcare Leave, 2 days per year per parent for a child aged 7 to 12.',
 '延长育儿假,子女 7–12 岁,每位家长每年 2 天。',
 true, false, 2, NULL, true, true, NULL, 80,
 'MOM: 2 days per parent per year, child aged 7–12 and a Singapore citizen. Eligibility checked by HR at approval.'),

-- 婴儿看护假:12 天【无薪】(2024-01 起由 6 天增至 12 天)。
('infant_care', 'Unpaid Infant Care Leave', '婴儿看护假(无薪)',
 'Unpaid infant care leave, 12 days per year per parent while the child is under 2.',
 '无薪婴儿看护假,子女未满 2 岁,每位家长每年 12 天。',
 false, false, 12, NULL, true, true, NULL, 90,
 'MOM: raised from 6 to 12 days per parent per year on 1 January 2024. Child must be a Singapore citizen under 2. UNPAID. Eligibility checked by HR at approval.'),

('unpaid', 'Unpaid Leave', '无薪假',
 'Unpaid leave, by arrangement.',
 '无薪假,另行商定。',
 false, false, NULL, NULL, true, true, NULL, 100,
 'No statutory entitlement. Days are whatever is agreed case by case.'),

-- 以下三项【不是法定假】,数字是占位值,必须由员工手册确认。
('compassionate', 'Compassionate Leave', '恩恤假',
 'Compassionate leave on the death of an immediate family member.',
 '直系亲属过世的恩恤假。',
 true, false, 3, NULL, true, false, NULL, 110,
 '⚠️ NOT statutory in Singapore — 3 days is a PLACEHOLDER pending confirmation from the staff handbook.'),

('marriage', 'Marriage Leave', '婚假',
 'Marriage leave.',
 '婚假。',
 true, false, 3, NULL, true, false, NULL, 120,
 '⚠️ NOT statutory in Singapore — 3 days is a PLACEHOLDER pending confirmation from the staff handbook.'),

('examination', 'Examination Leave', '考试假',
 'Paid leave for approved course examinations.',
 '经批准的课程考试假。',
 true, false, 2, NULL, true, true, NULL, 130,
 '⚠️ NOT statutory in Singapore — 2 days is a PLACEHOLDER pending confirmation from the staff handbook.');

-- ============================================================================

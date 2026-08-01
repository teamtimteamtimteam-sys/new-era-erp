-- db/migrations/2026-08-02-hr2a-leave-and-claims.sql
-- HR cut 2a:请假管理与医疗报销(数据库层)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【余额是算出来的,永远不存】
--   授予是账的贷方(leave_grants),消耗是借方(leave_consumption),余额是两者之和。
--   与库存流水、与总账是同一套纪律:存下来的余额一定会和它所汇总的记录漂移,
--   而在这里,漂移会在【某个人离职那天】变成一个错误的补偿天数 —— 那时候已经晚了。
--
-- 【结转与"先用旧的"是本切最容易做反的地方】
--   规则:未休年假结转,并在【授予年度之后 12 个月】失效(2026 年的剩余,2027-12-31 到期)。
--   因此消耗必须【按到期日从早到晚】扣减,否则结转来的天数会先烂掉,而当年的还留着 ——
--   对员工是净损失。这条规则实现在 decide_leave_request 里,并由 fixture 逐条证明。
--
-- 【所有规则都是可配置的数据,不是代码里的常量】
--   假期类型、天数、是否需要医生证明、医疗报销额度与按月折算与否 —— 全部是表里的行。
--   Tim 预期会调这些,调的时候不该需要发一次版。
--
-- ⚠️ 【下面播下的法定数字需要 Tim 逐条确认】。每一条都注明了来源与查证日期;
--   非法定的(恩恤假、婚假、考试假)是【占位值】,必须由员工手册确认。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ============================================================================
-- B1. leave_types —— 配置,不是枚举
-- ============================================================================
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

-- 年假:天数【不来自这里】,来自 employees.annual_leave_days(办公室 24 / 现场 18)。
-- default_days_per_year 留空,免得两处数字打架。
('annual', 'Annual Leave', '年假',
 'Paid annual leave. Entitlement comes from the employee record, not this table.',
 '带薪年假。天数取自员工档案,不取自本表。',
 true, true, NULL, NULL, true, true, NULL, 10,
 'Entitlement source: employees.annual_leave_days (office 24 / shopfloor 18). Statutory minimum under the Employment Act is 7 days rising to 14 with service — the company figure is well above it.'),

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
-- B2. public_holidays
-- ============================================================================
CREATE TABLE public.public_holidays (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    holiday_date date NOT NULL,
    name_en      text NOT NULL,
    name_zh      text NOT NULL,
    country      text NOT NULL DEFAULT 'SG',
    is_active    boolean NOT NULL DEFAULT true,
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid()
);

CREATE UNIQUE INDEX idx_public_holidays_live
    ON public.public_holidays (holiday_date, country) WHERE is_active;

CREATE TRIGGER trg_public_holidays_updated_at
    BEFORE UPDATE ON public.public_holidays
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.public_holidays ENABLE ROW LEVEL SECURITY;
-- 【任何登录用户可读】—— 每个人都需要知道哪天不上班
CREATE POLICY "public_holidays select by permission"
    ON public.public_holidays AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "public_holidays insert by permission"
    ON public.public_holidays AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "public_holidays update by permission"
    ON public.public_holidays AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "public_holidays delete by permission"
    ON public.public_holidays AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- 【2026 年新加坡宪报公布的公共假期】(MOM 官方,2026-08 查证)。
-- 11 个法定假日 + 3 个"逢周日顺延周一"的补假 = 14 个日期。
-- ⚠️【往后年份由 Tim 自己补】—— 农历与回历日期不去计算,那要靠官方公布。
INSERT INTO public.public_holidays (holiday_date, name_en, name_zh, notes) VALUES
    ('2026-01-01', 'New Year''s Day',      '元旦',        'Thursday'),
    ('2026-02-17', 'Chinese New Year',     '农历新年',    'Tuesday (day 1)'),
    ('2026-02-18', 'Chinese New Year',     '农历新年',    'Wednesday (day 2)'),
    ('2026-03-21', 'Hari Raya Puasa',      '开斋节',      'Saturday — lunar, confirmed by the authorities'),
    ('2026-04-03', 'Good Friday',          '耶稣受难日',  'Friday'),
    ('2026-05-01', 'Labour Day',           '劳动节',      'Friday'),
    ('2026-05-27', 'Hari Raya Haji',       '哈芝节',      'Wednesday — lunar, confirmed by the authorities'),
    ('2026-05-31', 'Vesak Day',            '卫塞节',      'Sunday'),
    ('2026-06-01', 'Vesak Day (in lieu)',  '卫塞节补假',  'Monday in lieu of Sunday 31 May'),
    ('2026-08-09', 'National Day',         '国庆日',      'Sunday'),
    ('2026-08-10', 'National Day (in lieu)','国庆日补假', 'Monday in lieu of Sunday 9 Aug'),
    ('2026-11-08', 'Deepavali',            '屠妖节',      'Sunday'),
    ('2026-11-09', 'Deepavali (in lieu)',  '屠妖节补假',  'Monday in lieu of Sunday 8 Nov'),
    ('2026-12-25', 'Christmas Day',        '圣诞节',      'Friday');

-- ============================================================================
-- B7a. hr_settings —— 可配置的门槛,单行配置表
-- ============================================================================
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
    updated_by             uuid DEFAULT auth.uid()
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

-- ============================================================================
-- B3. leave_grants —— 账的贷方
-- ============================================================================
CREATE TABLE public.leave_grants (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     uuid NOT NULL REFERENCES public.employees (id),
    leave_type_code text NOT NULL REFERENCES public.leave_types (code),
    leave_year      integer NOT NULL,
    days            numeric NOT NULL CHECK (days > 0),
    granted_on      date NOT NULL,
    -- 【expires_on 是"先用旧的"的依据】。当年度的 entitlement 授予到【次年年底】失效,
    -- 这就是那条"结转后 12 个月失效"的规则落在数据上的样子。
    -- null = 永不失效(目前没有这样的授予,留给日后)。
    expires_on      date,
    grant_type      text NOT NULL CHECK (grant_type IN ('entitlement','carry_forward','adjustment','pro_rata')),
    -- 结转授予指向它的来源,于是"这 19 天是从哪来的"查得到
    source_grant_id uuid REFERENCES public.leave_grants (id),
    notes           text,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid()
);

CREATE INDEX idx_leave_grants_employee ON public.leave_grants (employee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_leave_grants_type ON public.leave_grants (leave_type_code);
CREATE INDEX idx_leave_grants_expiry ON public.leave_grants (expires_on) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_leave_grants_updated_at
    BEFORE UPDATE ON public.leave_grants
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.leave_grants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_grants select by permission"
    ON public.leave_grants AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "leave_grants select own rows"
    ON public.leave_grants AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "leave_grants insert by permission"
    ON public.leave_grants AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_grants update by permission"
    ON public.leave_grants AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_grants delete by permission"
    ON public.leave_grants AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ============================================================================
-- B4. leave_requests
-- ============================================================================
CREATE TABLE public.leave_requests (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code            text NOT NULL UNIQUE,
    employee_id     uuid NOT NULL REFERENCES public.employees (id),
    leave_type_code text NOT NULL REFERENCES public.leave_types (code),
    start_date      date NOT NULL,
    end_date        date NOT NULL,
    start_half_day  boolean NOT NULL DEFAULT false,
    end_half_day    boolean NOT NULL DEFAULT false,
    -- days 由 submit_leave_request 用 calculate_leave_days 算出,【不采信调用方传入的值】
    days            numeric NOT NULL CHECK (days > 0),
    reason          text,
    certificate_ref text,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','rejected','cancelled')),
    decided_at      timestamptz,
    decided_by      uuid,
    decision_notes  text,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid(),
    CONSTRAINT leave_requests_date_order CHECK (end_date >= start_date)
);

CREATE INDEX idx_leave_requests_employee ON public.leave_requests (employee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_leave_requests_status ON public.leave_requests (status);
CREATE INDEX idx_leave_requests_start ON public.leave_requests (start_date);

CREATE TRIGGER trg_leave_requests_updated_at
    BEFORE UPDATE ON public.leave_requests
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.leave_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_requests select by permission"
    ON public.leave_requests AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
-- 自助:自己的申请自己看得见(权限 cut 4 的行级模式)
CREATE POLICY "leave_requests select own rows"
    ON public.leave_requests AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "leave_requests insert by permission"
    ON public.leave_requests AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_requests update by permission"
    ON public.leave_requests AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_requests delete by permission"
    ON public.leave_requests AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ============================================================================
-- B5. leave_consumption —— 账的借方
-- ============================================================================
-- 【这里就是"先用旧的"落在数据上的地方】,也是余额之所以【说得清】而不只是【算得对】的原因:
-- 每一天的假都记着它是从哪一笔授予里扣的。
--
-- 【取消已批准的申请怎么记】:写一条 entry_type='release' 的【新行】,而不是删行、
-- 也不是改行的状态。理由:
--   * 本表是仅追加的(与库存流水、总账同一纪律),改状态就得开 UPDATE,不可变性没了;
--   * days 的 CHECK 是 > 0,负数行会破坏这个约束,而这个约束本身是有价值的;
--   * 追加一行 release 让"批了又撤"这件事在账上【看得见】—— 删行或改状态都会让它消失。
-- 已消耗 = Σ(draw) − Σ(release)。
CREATE TABLE public.leave_consumption (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    leave_request_id uuid NOT NULL REFERENCES public.leave_requests (id) ON DELETE RESTRICT,
    leave_grant_id   uuid NOT NULL REFERENCES public.leave_grants (id),
    entry_type       text NOT NULL DEFAULT 'draw' CHECK (entry_type IN ('draw','release')),
    days             numeric NOT NULL CHECK (days > 0),
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid()
);

CREATE INDEX idx_leave_consumption_request ON public.leave_consumption (leave_request_id);
CREATE INDEX idx_leave_consumption_grant ON public.leave_consumption (leave_grant_id);

CREATE OR REPLACE FUNCTION public.reject_leave_consumption_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'LEAVE_CONSUMPTION_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_leave_consumption_immutable
    BEFORE UPDATE OR DELETE ON public.leave_consumption
    FOR EACH ROW EXECUTE FUNCTION public.reject_leave_consumption_mutation();

ALTER TABLE public.leave_consumption ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_consumption select by permission"
    ON public.leave_consumption AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "leave_consumption insert by permission"
    ON public.leave_consumption AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));

-- ============================================================================
-- B7. medical_claims
-- ============================================================================
CREATE TABLE public.medical_claims (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,
    employee_id    uuid NOT NULL REFERENCES public.employees (id),
    claim_date     date NOT NULL,
    claim_year     integer NOT NULL,
    amount_sgd     numeric NOT NULL CHECK (amount_sgd > 0),
    description    text,
    receipt_ref    text,
    status         text NOT NULL DEFAULT 'submitted'
                   CHECK (status IN ('submitted','approved','rejected','paid')),
    decided_at     timestamptz,
    decided_by     uuid,
    decision_notes text,
    -- 【付款方式是 Tim 的运营决定】:走薪资代发,还是单独付款并入账为费用。
    -- 本切【不自动过账】—— 这一列留着,等他定了再把两边挂上。
    expense_id     uuid REFERENCES public.expenses (id),
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid()
);

CREATE INDEX idx_medical_claims_employee ON public.medical_claims (employee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_medical_claims_year ON public.medical_claims (claim_year);

CREATE TRIGGER trg_medical_claims_updated_at
    BEFORE UPDATE ON public.medical_claims
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.medical_claims ENABLE ROW LEVEL SECURITY;
CREATE POLICY "medical_claims select by permission"
    ON public.medical_claims AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "medical_claims select own rows"
    ON public.medical_claims AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "medical_claims insert by permission"
    ON public.medical_claims AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "medical_claims update by permission"
    ON public.medical_claims AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "medical_claims delete by permission"
    ON public.medical_claims AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ============================================================================
-- 编号:无缝序号,与既有 next_*_code 同一套做法
-- ============================================================================
CREATE OR REPLACE FUNCTION public.next_leave_request_code(p_date date DEFAULT CURRENT_DATE)
RETURNS text LANGUAGE plpgsql AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('leave_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM leave_requests WHERE code LIKE 'LV-' || v_year::text || '-%';
    RETURN 'LV-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

CREATE OR REPLACE FUNCTION public.next_medical_claim_code(p_date date DEFAULT CURRENT_DATE)
RETURNS text LANGUAGE plpgsql AS $function$
DECLARE v_year integer := EXTRACT(YEAR FROM p_date)::integer; v_seq integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('medical_claim_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM medical_claims WHERE code LIKE 'MC-' || v_year::text || '-%';
    RETURN 'MC-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ============================================================================
-- B6. 函数
-- ============================================================================

-- ---------------------------------------------------------------- 工作日计算
-- 【不建模轮班】。现场是三班倒的话,"周六是不是工作日"就因人而异,那需要排班表。
-- 目前一律按周一至周五 + 公共假期扣除来算;若日后要按排班计假,那是另一次改动,
-- 会牵动 leave_requests.days 的口径,不是在这个函数里加个参数就完事的。
CREATE OR REPLACE FUNCTION public.calculate_leave_days(
    p_start date, p_end date,
    p_start_half boolean DEFAULT false,
    p_end_half boolean DEFAULT false
)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT GREATEST(
        (SELECT count(*)
         FROM generate_series(p_start, p_end, interval '1 day') d
         WHERE EXTRACT(ISODOW FROM d) < 6
           AND NOT EXISTS (
               SELECT 1 FROM public_holidays h
               WHERE h.holiday_date = d::date AND h.country = 'SG' AND h.is_active))::numeric
        - CASE WHEN p_start_half THEN 0.5 ELSE 0 END
        - CASE WHEN p_end_half THEN 0.5 ELSE 0 END,
        0);
$function$;

-- ---------------------------------------------------------------- 年假授予
-- 【按月折算的取整规则:四舍五入到 0.5 天】。
-- 理由:0.5 天是【消耗的最小单位】(leave_types.allows_half_day)。若折算出 12.37 天,
-- 那 0.37 天永远请不出来,也永远补偿不掉 —— 一个取不出的余额不是余额,是账面噪音。
-- 取到 0.5 让"授予的每一天都能被用掉"。
CREATE OR REPLACE FUNCTION public.grant_annual_leave(
    p_employee_id uuid, p_leave_year integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_months integer;
    v_days   numeric;
    v_type   text := 'annual';
    v_grant  record;
    v_start  date := make_date(p_leave_year, 1, 1);
    v_end    date := make_date(p_leave_year, 12, 31);
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT id, code, hire_date, annual_leave_days, employment_status
    INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    IF EXISTS (SELECT 1 FROM leave_grants g
               WHERE g.employee_id = p_employee_id AND g.leave_type_code = v_type
                 AND g.leave_year = p_leave_year AND g.grant_type IN ('entitlement','pro_rata')
                 AND g.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'GRANT_EXISTS|%', p_leave_year;
    END IF;

    IF v_emp.hire_date > v_end THEN
        RAISE EXCEPTION 'HIRED_AFTER_YEAR|%', p_leave_year;
    END IF;

    -- 年中入职:按【完整服务月数 ÷ 12】折算。入职当月计为完整的一个月。
    IF v_emp.hire_date > v_start THEN
        v_months := 12 - (EXTRACT(MONTH FROM v_emp.hire_date)::integer - 1);
        v_days := round((v_emp.annual_leave_days::numeric * v_months / 12.0) * 2) / 2;
    ELSE
        v_months := 12;
        v_days := v_emp.annual_leave_days::numeric;
    END IF;

    IF v_days <= 0 THEN RAISE EXCEPTION 'NO_ENTITLEMENT|%', p_leave_year; END IF;

    INSERT INTO leave_grants (employee_id, leave_type_code, leave_year, days, granted_on,
                              -- 【当年度授予到次年年底失效】= 结转 12 个月的规则
                              expires_on, grant_type, notes)
    VALUES (p_employee_id, v_type, p_leave_year, v_days, GREATEST(v_start, v_emp.hire_date),
            make_date(p_leave_year + 1, 12, 31),
            CASE WHEN v_months = 12 THEN 'entitlement' ELSE 'pro_rata' END,
            CASE WHEN v_months = 12 THEN NULL
                 ELSE format('Pro-rated: %s of 12 months from hire date %s', v_months, v_emp.hire_date) END)
    RETURNING * INTO v_grant;

    RETURN jsonb_build_object(
        'grant_id', v_grant.id, 'employee_code', v_emp.code, 'leave_year', p_leave_year,
        'months_of_service', v_months, 'entitlement_days', v_emp.annual_leave_days,
        'granted_days', v_days, 'expires_on', v_grant.expires_on,
        'grant_type', v_grant.grant_type);
END;
$function$;

-- ---------------------------------------------------------------- 结转
CREATE OR REPLACE FUNCTION public.carry_forward_annual_leave(p_leave_year integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp     record;
    v_balance numeric;
    v_rows    jsonb := '[]'::jsonb;
    v_count   integer := 0;
    v_total   numeric := 0;
    v_src     uuid;
BEGIN
    PERFORM require_permission('module.hr.edit');

    FOR v_emp IN
        SELECT e.id, e.code FROM employees e
        WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'
        ORDER BY e.code
    LOOP
        -- 幂等:同一员工同一年只结转一次
        IF EXISTS (SELECT 1 FROM leave_grants g
                   WHERE g.employee_id = v_emp.id AND g.leave_type_code = 'annual'
                     AND g.grant_type = 'carry_forward' AND g.leave_year = p_leave_year + 1
                     AND g.deleted_at IS NULL) THEN
            RAISE EXCEPTION 'CARRY_FORWARD_EXISTS|%|%', v_emp.code, p_leave_year;
        END IF;

        -- 该年度授予里没被消耗掉的部分
        SELECT COALESCE(SUM(g.days), 0)
               - COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                           JOIN leave_grants src ON src.id = cf.source_grant_id
                           WHERE src.employee_id = v_emp.id AND src.leave_type_code = 'annual'
                             AND src.leave_year = p_leave_year AND cf.grant_type = 'carry_forward'
                             AND cf.deleted_at IS NULL), 0)
               - COALESCE((
                   SELECT SUM(CASE WHEN c.entry_type = 'draw' THEN c.days ELSE -c.days END)
                   FROM leave_consumption c
                   WHERE c.leave_grant_id IN (
                       SELECT g2.id FROM leave_grants g2
                       WHERE g2.employee_id = v_emp.id AND g2.leave_type_code = 'annual'
                         AND g2.leave_year = p_leave_year AND g2.deleted_at IS NULL)), 0)
        INTO v_balance
        FROM leave_grants g
        WHERE g.employee_id = v_emp.id AND g.leave_type_code = 'annual'
          AND g.leave_year = p_leave_year AND g.deleted_at IS NULL;

        IF v_balance IS NULL OR v_balance <= 0 THEN CONTINUE; END IF;

        SELECT id INTO v_src FROM leave_grants
        WHERE employee_id = v_emp.id AND leave_type_code = 'annual'
          AND leave_year = p_leave_year AND deleted_at IS NULL
        ORDER BY granted_on LIMIT 1;

        INSERT INTO leave_grants (employee_id, leave_type_code, leave_year, days, granted_on,
                                  -- 结转进 next year,并在【那一年的年底】失效 —— 即原年度之后 12 个月
                                  expires_on, grant_type, source_grant_id, notes)
        VALUES (v_emp.id, 'annual', p_leave_year + 1, v_balance,
                make_date(p_leave_year + 1, 1, 1),
                make_date(p_leave_year + 1, 12, 31),
                'carry_forward', v_src,
                format('Carried forward from %s', p_leave_year));

        v_count := v_count + 1;
        v_total := v_total + v_balance;
        v_rows := v_rows || jsonb_build_object('employee_code', v_emp.code, 'days', v_balance);
    END LOOP;

    RETURN jsonb_build_object('from_year', p_leave_year, 'into_year', p_leave_year + 1,
                              'employees', v_count, 'total_days', v_total, 'detail', v_rows);
END;
$function$;

-- ---------------------------------------------------------------- 余额(派生)
CREATE OR REPLACE FUNCTION public.leave_balance(
    p_employee_id uuid,
    p_leave_type_code text DEFAULT 'annual',
    p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_break   jsonb := '[]'::jsonb;
    v_granted numeric := 0;
    v_used    numeric := 0;
    v_expired numeric := 0;
    v_avail   numeric := 0;
    r         record;
BEGIN
    -- 自助:自己的余额自己看得见;其余要 module.hr.view
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    FOR r IN
        SELECT g.id, g.leave_year, g.days, g.granted_on, g.expires_on, g.grant_type,
               COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                         FROM leave_consumption c WHERE c.leave_grant_id = g.id), 0) AS consumed,
               -- 【已被结转走的部分】。结转是把剩余【搬到】下一年的一笔新授予里,
               -- 不是复制一份 —— 若不在这里扣掉,同样的天数会在来源授予和结转授予里
               -- 【各算一次】,余额凭空翻倍。这一条是本切最容易做错的地方之一。
               COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                         WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'
                           AND cf.deleted_at IS NULL), 0) AS carried_out
        FROM leave_grants g
        WHERE g.employee_id = p_employee_id AND g.leave_type_code = p_leave_type_code
          AND g.deleted_at IS NULL AND g.granted_on <= p_as_of
        ORDER BY g.expires_on NULLS LAST, g.granted_on
    LOOP
        v_granted := v_granted + r.days;
        v_used := v_used + r.consumed;
        -- 三种去向,任何一种都要说得出来:被用掉、被结转走、过期作废。
        IF r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0 THEN
            NULL;  -- 整笔剩余已结转走,既不可用也不算作废
        ELSIF r.expires_on IS NOT NULL AND r.expires_on < p_as_of THEN
            v_expired := v_expired + (r.days - r.consumed - r.carried_out);
        ELSE
            v_avail := v_avail + (r.days - r.consumed - r.carried_out);
        END IF;
        v_break := v_break || jsonb_build_object(
            'grant_id', r.id, 'leave_year', r.leave_year, 'grant_type', r.grant_type,
            'days', r.days, 'consumed', r.consumed, 'carried_forward_out', r.carried_out,
            'remaining', r.days - r.consumed - r.carried_out,
            'expires_on', r.expires_on,
            'status', CASE WHEN r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0
                                THEN 'carried_forward'
                           WHEN r.expires_on IS NOT NULL AND r.expires_on < p_as_of
                                THEN 'expired' ELSE 'active' END);
    END LOOP;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'leave_type_code', p_leave_type_code, 'as_of', p_as_of,
        'granted', v_granted, 'consumed', v_used, 'expired', v_expired, 'available', v_avail,
        'breakdown', v_break);
END;
$function$;

-- ---------------------------------------------------------------- 提交申请
CREATE OR REPLACE FUNCTION public.submit_leave_request(
    p_employee_id uuid,
    p_leave_type_code text,
    p_start date,
    p_end date,
    p_start_half boolean DEFAULT false,
    p_end_half boolean DEFAULT false,
    p_reason text DEFAULT NULL,
    p_certificate_ref text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_type   record;
    v_days   numeric;
    v_taken  numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_code   text;
    v_req    record;
    v_clash  text;
BEGIN
    -- 【本人或 HR】。自助提交的界面是下一切的事,但函数现在就允许 ——
    -- 表达方式:要么持有 module.hr.edit,要么 p_employee_id 就是调用者自己的员工档案。
    IF NOT (has_permission('module.hr.edit') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    SELECT id, code, employment_status INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = p_leave_type_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'LEAVE_TYPE_NOT_FOUND|%', p_leave_type_code; END IF;
    IF NOT v_type.is_active THEN RAISE EXCEPTION 'LEAVE_TYPE_INACTIVE|%', p_leave_type_code; END IF;

    -- 【试用期不得请年假】—— 但假期照常累积(授予在 grant_annual_leave 里已经发生),
    -- 转正之后整笔余额自然就可用了,不需要任何补授动作。
    IF v_type.is_accrued AND v_emp.employment_status = 'probation' THEN
        RAISE EXCEPTION 'PROBATION_NO_ANNUAL_LEAVE';
    END IF;

    -- 【性别限制记录了但无法强制】:employees 没有性别列,见文件末尾的缺口说明。
    -- 这里【不猜】—— 产假/陪产假的适用性由 HR 在审批时判断。

    v_days := calculate_leave_days(p_start, p_end, p_start_half, p_end_half);
    IF v_days <= 0 THEN RAISE EXCEPTION 'NO_WORKING_DAYS|%|%', p_start, p_end; END IF;

    SELECT code INTO v_clash FROM leave_requests
    WHERE employee_id = p_employee_id AND deleted_at IS NULL
      AND status IN ('pending','approved')
      AND daterange(start_date, end_date, '[]') && daterange(p_start, p_end, '[]')
    LIMIT 1;
    IF v_clash IS NOT NULL THEN RAISE EXCEPTION 'OVERLAPPING_REQUEST|%', v_clash; END IF;

    -- 医生证明:本年度【已请】的该类假天数 + 本次 > 门槛 时必须给证明。
    -- 语义说明:门槛是"免证明的额度",所以 taken=3、门槛=3、再请 1 天就要证明。
    IF v_type.requires_certificate_after_days IS NOT NULL
       AND (p_certificate_ref IS NULL OR btrim(p_certificate_ref) = '') THEN
        SELECT COALESCE(SUM(r.days), 0) INTO v_taken
        FROM leave_requests r
        WHERE r.employee_id = p_employee_id AND r.leave_type_code = p_leave_type_code
          AND r.deleted_at IS NULL AND r.status IN ('pending','approved')
          AND EXTRACT(YEAR FROM r.start_date) = EXTRACT(YEAR FROM p_start);
        IF v_taken + v_days > v_type.requires_certificate_after_days THEN
            RAISE EXCEPTION 'CERTIFICATE_REQUIRED|%|%', v_taken, v_type.requires_certificate_after_days;
        END IF;
    END IF;

    -- 累积型:先看余额够不够(真正的扣减在审批时发生)
    IF v_type.is_accrued THEN
        v_bal := leave_balance(p_employee_id, p_leave_type_code, p_start);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_days THEN
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%', v_avail, v_days;
        END IF;
    END IF;

    v_code := next_leave_request_code(p_start);
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date,
                                start_half_day, end_half_day, days, reason, certificate_ref)
    VALUES (v_code, p_employee_id, p_leave_type_code, p_start, p_end,
            p_start_half, p_end_half, v_days, p_reason, p_certificate_ref)
    RETURNING * INTO v_req;

    RETURN jsonb_build_object('request_id', v_req.id, 'code', v_req.code,
                              'employee_code', v_emp.code, 'leave_type_code', p_leave_type_code,
                              'days', v_days, 'status', v_req.status);
END;
$function$;

-- ---------------------------------------------------------------- 审批
CREATE OR REPLACE FUNCTION public.decide_leave_request(
    p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req    record;
    v_type   record;
    v_need   numeric;
    v_take   numeric;
    v_bal    jsonb;
    v_avail  numeric;
    g        record;
    v_used   jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;
    IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING|%', v_req.status; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = v_req.leave_type_code;

    IF NOT p_approve THEN
        UPDATE leave_requests SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid()
        WHERE id = p_request_id;
        RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','rejected');
    END IF;

    IF v_type.is_accrued THEN
        -- 提交到审批之间别人可能已经消耗掉了,所以这里【重新验一次】
        v_bal := leave_balance(v_req.employee_id, v_req.leave_type_code, v_req.start_date);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_req.days THEN
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%', v_avail, v_req.days;
        END IF;

        v_need := v_req.days;
        -- ══════════════════════════════════════════════════════════════════
        -- 【先用旧的】:按 expires_on 从早到晚扣。
        -- 这是本切最容易做反的一条 —— 反过来的话,结转来的天数会先过期烂掉,
        -- 而当年的还好好留着,对员工是净损失。NULLS LAST 让"永不过期"的授予排最后。
        -- ══════════════════════════════════════════════════════════════════
        FOR g IN
            SELECT gr.id, gr.days, gr.expires_on, gr.leave_year, gr.grant_type,
                   gr.days
                   - COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                               FROM leave_consumption c WHERE c.leave_grant_id = gr.id), 0)
                   -- 已结转走的部分不能再从这里扣,否则同一天会被用两次
                   - COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                               WHERE cf.source_grant_id = gr.id AND cf.grant_type = 'carry_forward'
                                 AND cf.deleted_at IS NULL), 0) AS remaining
            FROM leave_grants gr
            WHERE gr.employee_id = v_req.employee_id AND gr.leave_type_code = v_req.leave_type_code
              AND gr.deleted_at IS NULL AND gr.granted_on <= v_req.start_date
              AND (gr.expires_on IS NULL OR gr.expires_on >= v_req.start_date)
            ORDER BY gr.expires_on NULLS LAST, gr.granted_on
        LOOP
            EXIT WHEN v_need <= 0;
            IF g.remaining <= 0 THEN CONTINUE; END IF;
            v_take := LEAST(g.remaining, v_need);
            INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days)
            VALUES (p_request_id, g.id, 'draw', v_take);
            v_need := v_need - v_take;
            v_used := v_used || jsonb_build_object('grant_id', g.id, 'leave_year', g.leave_year,
                                                   'grant_type', g.grant_type,
                                                   'expires_on', g.expires_on, 'days', v_take);
        END LOOP;

        IF v_need > 0 THEN
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%', v_req.days - v_need, v_req.days;
        END IF;
    END IF;

    UPDATE leave_requests SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid()
    WHERE id = p_request_id;

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','approved',
                              'days', v_req.days, 'consumed_from', v_used);
END;
$function$;

-- ---------------------------------------------------------------- 取消
CREATE OR REPLACE FUNCTION public.cancel_leave_request(
    p_request_id uuid, p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req  record;
    c      record;
    v_rel  jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;

    IF NOT (has_permission('module.hr.edit') OR v_req.employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;
    IF v_req.status = 'cancelled' THEN RAISE EXCEPTION 'ALREADY_CANCELLED|%', v_req.code; END IF;
    IF v_req.status = 'rejected' THEN RAISE EXCEPTION 'REQUEST_REJECTED|%', v_req.code; END IF;

    -- 【释放不是删除】:对每一条 draw 追加一条等额的 release。
    -- 于是"批了 3 天,后来撤了"在账上是两行,而不是一行都没有 —— 余额算得对,也说得清。
    FOR c IN
        SELECT leave_grant_id,
               SUM(CASE WHEN entry_type='draw' THEN days ELSE -days END) AS net
        FROM leave_consumption WHERE leave_request_id = p_request_id
        GROUP BY leave_grant_id HAVING SUM(CASE WHEN entry_type='draw' THEN days ELSE -days END) > 0
    LOOP
        INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days, notes)
        VALUES (p_request_id, c.leave_grant_id, 'release', c.net,
                COALESCE(p_reason, 'Request cancelled'));
        v_rel := v_rel || jsonb_build_object('grant_id', c.leave_grant_id, 'days_released', c.net);
    END LOOP;

    UPDATE leave_requests SET status='cancelled', decided_at=now(), decided_by=auth.uid(),
           decision_notes=COALESCE(p_reason, decision_notes), updated_by=auth.uid()
    WHERE id = p_request_id;

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code,
                              'status','cancelled', 'released', v_rel);
END;
$function$;

-- ---------------------------------------------------------------- 离职补偿
-- 【明确不过账】。实际发放走的是外包薪资服务商,系统只给一个【参考金额】;
-- 若这里再记一笔分录,同一笔钱就会在总账里出现两次。
CREATE OR REPLACE FUNCTION public.compute_leave_encashment(
    p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   record;
    v_bal   jsonb;
    v_days  numeric;
    v_gross numeric;
    v_dpw   numeric;
    v_daily numeric;
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, legal_name INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    v_bal := leave_balance(p_employee_id, 'annual', p_as_of);
    v_days := (v_bal->>'available')::numeric;

    -- 最近一个【已过账】期间的应发工资当作月薪基数
    SELECT pl.gross_pay INTO v_gross
    FROM payroll_lines pl JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
    WHERE pl.employee_id = p_employee_id AND pp.status = 'posted' AND pp.deleted_at IS NULL
    ORDER BY pp.period_month DESC LIMIT 1;

    SELECT working_days_per_week INTO v_dpw FROM hr_settings WHERE id;

    -- 【日薪口径】用 MOM 对月薪员工的定义:12 × 月薪 ÷ (52 × 每周工作天数)。
    -- 每周 5 天时相当于月薪 ÷ 21.667。选它而不是"21.75"是因为 21.75 只是这个公式
    -- 在 5 天工作制下的一个近似;把每周天数存成配置,公式对 5.5 天制也照样成立。
    v_daily := CASE WHEN v_gross IS NULL THEN NULL
                    ELSE round((12.0 * v_gross) / (52.0 * v_dpw), 2) END;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code, 'as_of', p_as_of,
        'unused_days', v_days,
        'monthly_gross_basis', v_gross,
        'daily_rate', v_daily,
        'daily_rate_formula', format('12 x monthly gross / (52 x %s working days per week)', v_dpw),
        'indicative_amount', CASE WHEN v_daily IS NULL THEN NULL ELSE round(v_daily * v_days, 2) END,
        -- 【这一面旗子是有意放在返回值里的】:调用方看得见"这只是参考,没有入账"
        'journal_posted', false,
        'note', 'Indicative only. Payment is made by the outsourced payroll provider; no journal entry is created by this system.',
        'balance_detail', v_bal);
END;
$function$;

-- ---------------------------------------------------------------- 医疗报销
-- 【按月折算规则】:全年额度 × 当年完整服务月数 ÷ 12,四舍五入到【整元】。
-- 取整到元而不是到分:这是一个报销上限,不是一笔要对账的金额,给到分没有意义,
-- 而且"你今年可以报 500 元"比"500.04 元"更像一句能说出口的话。
CREATE OR REPLACE FUNCTION public.medical_claim_balance(
    p_employee_id uuid, p_year integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_set    record;
    v_months integer := 12;
    v_limit  numeric;
    v_used   numeric;
BEGIN
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    SELECT id, code, hire_date INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    SELECT * INTO v_set FROM hr_settings WHERE id;

    IF v_set.medical_pro_rate_for_joiners AND EXTRACT(YEAR FROM v_emp.hire_date)::integer = p_year THEN
        v_months := 12 - (EXTRACT(MONTH FROM v_emp.hire_date)::integer - 1);
    END IF;
    v_limit := round(v_set.medical_annual_limit_sgd * v_months / 12.0, 0);

    SELECT COALESCE(SUM(amount_sgd), 0) INTO v_used
    FROM medical_claims
    WHERE employee_id = p_employee_id AND claim_year = p_year
      AND deleted_at IS NULL AND status IN ('approved','paid');

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'employee_code', v_emp.code, 'year', p_year,
        'annual_limit_sgd', v_set.medical_annual_limit_sgd,
        'months_of_service', v_months,
        'pro_rated_limit_sgd', v_limit,
        'claimed_sgd', v_used,
        'remaining_sgd', v_limit - v_used);
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_medical_claim(
    p_employee_id uuid, p_claim_date date, p_amount_sgd numeric,
    p_description text DEFAULT NULL, p_receipt_ref text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_emp record; v_code text; v_claim record; v_year integer;
BEGIN
    IF NOT (has_permission('module.hr.edit') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;
    SELECT id, code INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF p_amount_sgd IS NULL OR p_amount_sgd <= 0 THEN RAISE EXCEPTION 'AMOUNT_INVALID'; END IF;

    v_year := EXTRACT(YEAR FROM p_claim_date)::integer;
    v_code := next_medical_claim_code(p_claim_date);
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd,
                                description, receipt_ref)
    VALUES (v_code, p_employee_id, p_claim_date, v_year, p_amount_sgd, p_description, p_receipt_ref)
    RETURNING * INTO v_claim;

    RETURN jsonb_build_object('claim_id', v_claim.id, 'code', v_claim.code,
                              'employee_code', v_emp.code, 'amount_sgd', p_amount_sgd,
                              'claim_year', v_year, 'status', v_claim.status);
END;
$function$;

-- 【批准时不自动记费用】。报销可能走薪资代发,也可能单独付款 ——
-- 走薪资的话它已经在薪资分录里了,这里再记一笔就是重复入账。
-- 究竟走哪条是 Tim 的运营决定;定了之后用 medical_claims.expense_id 把两边挂起来。
CREATE OR REPLACE FUNCTION public.decide_medical_claim(
    p_claim_id uuid, p_approve boolean, p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_claim record; v_bal jsonb; v_remaining numeric;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
    IF v_claim.status <> 'submitted' THEN RAISE EXCEPTION 'CLAIM_NOT_SUBMITTED|%', v_claim.status; END IF;

    IF NOT p_approve THEN
        UPDATE medical_claims SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','rejected');
    END IF;

    v_bal := medical_claim_balance(v_claim.employee_id, v_claim.claim_year);
    v_remaining := (v_bal->>'remaining_sgd')::numeric;
    IF v_claim.amount_sgd > v_remaining THEN
        RAISE EXCEPTION 'CLAIM_EXCEEDS_LIMIT|%|%', v_remaining, v_claim.amount_sgd;
    END IF;

    UPDATE medical_claims SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','approved',
                              'amount_sgd', v_claim.amount_sgd,
                              'remaining_after', v_remaining - v_claim.amount_sgd,
                              -- 与补偿一样,把"没有入账"写进返回值,免得调用方以为记过账了
                              'expense_posted', false,
                              'note', 'No expense is posted. Reimbursement route (payroll vs separate payment) is an operational decision; link it via medical_claims.expense_id once chosen.');
END;
$function$;

-- ============================================================================
-- B8. 视图
-- ============================================================================
-- 自助:自己的累积型假别余额
CREATE VIEW public.my_leave_balance WITH (security_invoker = off) AS
SELECT
    e.id AS employee_id, e.code AS employee_code,
    lt.code AS leave_type_code, lt.name_en, lt.name_zh,
    COALESCE(SUM(g.days), 0) AS granted,
    COALESCE(SUM(cons.net), 0) AS consumed,
    COALESCE(SUM(CASE WHEN g.expires_on IS NOT NULL AND g.expires_on < CURRENT_DATE
                      THEN g.days - COALESCE(cons.net, 0) ELSE 0 END), 0) AS expired,
    COALESCE(SUM(CASE WHEN g.expires_on IS NULL OR g.expires_on >= CURRENT_DATE
                      THEN g.days - COALESCE(cons.net, 0) ELSE 0 END), 0) AS available
FROM employees e
JOIN leave_types lt ON lt.is_accrued AND lt.is_active
LEFT JOIN leave_grants g ON g.employee_id = e.id AND g.leave_type_code = lt.code AND g.deleted_at IS NULL
LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END), 0)
         + COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                     WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'
                       AND cf.deleted_at IS NULL), 0) AS net
    FROM leave_consumption c WHERE c.leave_grant_id = g.id
) cons ON true
WHERE e.id = current_user_employee() AND e.deleted_at IS NULL
GROUP BY e.id, e.code, lt.code, lt.name_en, lt.name_zh;

GRANT SELECT ON public.my_leave_balance TO authenticated;

-- 团队请假日历:HR 看全部,员工看自己的
CREATE VIEW public.leave_calendar WITH (security_invoker = off) AS
SELECT
    r.id AS request_id, r.code, r.employee_id, e.code AS employee_code, e.legal_name,
    e.department_id, r.leave_type_code, lt.name_en AS leave_type_en, lt.name_zh AS leave_type_zh,
    r.start_date, r.end_date, r.start_half_day, r.end_half_day, r.days, r.status
FROM leave_requests r
JOIN employees e ON e.id = r.employee_id
JOIN leave_types lt ON lt.code = r.leave_type_code
WHERE r.deleted_at IS NULL
  AND r.status IN ('pending','approved')
  AND (has_permission('module.hr.view') OR r.employee_id = current_user_employee());

GRANT SELECT ON public.leave_calendar TO authenticated;

CREATE VIEW public.medical_claim_status WITH (security_invoker = off) AS
SELECT
    mc.id AS claim_id, mc.code, mc.employee_id, e.code AS employee_code, e.legal_name,
    mc.claim_date, mc.claim_year, mc.amount_sgd, mc.description, mc.receipt_ref,
    mc.status, mc.decided_at, mc.expense_id,
    (mc.expense_id IS NOT NULL) AS linked_to_expense
FROM medical_claims mc
JOIN employees e ON e.id = mc.employee_id
WHERE mc.deleted_at IS NULL
  AND (has_permission('module.hr.view') OR mc.employee_id = current_user_employee());

GRANT SELECT ON public.medical_claim_status TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 【已知缺口 —— 需要 Tim 决定】
--
-- 1.【employees 没有性别列】。leave_types.gender_restriction 记下了产假=female、
--    陪产假=male,但【没有任何地方可以据此校验】,所以 submit_leave_request
--    有意不做这个检查(而不是猜一个来源)。目前产假/陪产假的适用性由 HR 在审批时人工判断。
--    要真正强制,需要在 employees 上加一列(那是个人数据,应当同时落进 data.view_identity
--    的遮蔽范围),这是一次独立的改动。
--
-- 2.【育儿假等的资格没有编码】。childcare / extended_childcare / infant_care /
--    maternity / shared_parental 的资格取决于子女的公民身份与年龄 —— 系统里没有子女数据。
--    这里只记录标准额度,资格由 HR 审批时判断,已在各条 notes 里写明。
--
-- 3.【轮班未建模】。calculate_leave_days 一律按周一至周五扣公共假期。现场若是轮班制,
--    这个口径会不准。要按排班计假需要排班表,那是另一次改动。
--
-- 4.【医疗报销的付款路径未定】。见 decide_medical_claim 的注释。
-- ════════════════════════════════════════════════════════════════════════════

NOTIFY pgrst, 'reload schema';

COMMIT;

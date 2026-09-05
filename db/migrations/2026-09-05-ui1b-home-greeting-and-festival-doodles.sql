-- db/migrations/2026-09-05-ui1b-home-greeting-and-festival-doodles.sql
-- ════════════════════════════════════════════════════════════════════════════
-- UI-1b(2026-09-05)· 首页:一个彩色字标、一行问候语、一套节日画机制
-- ════════════════════════════════════════════════════════════════════════════
--
-- 这一支做四件事,而它们共用一个破窗,所以在【同一笔事务】里:
--   ① home_greetings   —— 72 句问候语。改一句不该需要一次部署。
--   ② festival_doodles —— 23 个节日 + 算好的窗口。**与 public_holidays 分开。**
--   ③ employees.greeting_name —— 只为 Sandra 一行而加,理由见下。
--      连同它的【列授权】与【_masked 视图】—— 三样在同一支里,WO-1a 那一课。
--   ④ hr_alerts 多一支 festival_doodles_exhausted —— 窗口见底之前叫住人。
--
-- 外加两处【数据订正】,各自独立成立:
--   · Sandra Yap 的 greeting_name = 'Sand'(Tim 手定,推导不出来);
--   · Choo Er Teh 的 preferred_name 从 'Chooer' 改成 'Choo Er' —— 那是一处
--     录入错误,与本刀无关也仍然是错的,而它印在 ActorName / TopNav / /me /
--     组织架构图上。Tim 裁定在本刀一并订正。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【②:为什么另起一张表,而不是给 public_holidays 加一个开关】★★
-- ════════════════════════════════════════════════════════════════════════════
-- C-2 当时被要求"把假日表设计成两个消费方共用"。**那条指示是错的,Tim 已推翻。**
-- 23 个节日里只有 10 个是新加坡公共假期。共用一张表意味着:**谁为了让首页出现
-- 一张万圣节的画而加了一行,就同时把那天变成了非工作日** —— 每个人的年假计算、
-- 每张考勤表、以及 is_business_day()(FX 回溯那条规矩的判据)全都跟着变。
-- **一个公共假期是【工作日事实】;一张节日画是【装饰】。**
-- C-2 的 holiday_key / is_in_lieu 留着,一点没浪费。两张表不交叉引用。
-- 同一段更正也写进了 db/tables/public_holidays.sql —— 那里原本写着
-- 「UI-1 的节日 logo 读它」,那句话从今天起是假的。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【③:遮蔽表加列 = 三样东西,一支迁移】★★(AGENTS.md「Adding a column to
-- a masked table」;WO-1a 把它拆成三支,每一支单看都完整,而闸红了两轮)
--   1. ALTER TABLE … ADD COLUMN
--   2. GRANT SELECT (…) —— 列清单授权【不会】自动扩展到后加的列
--   3. employees_masked 追加同一列 —— colgrant 的判据是
--      (granted OR in_view) AND (has_view → in_view),employees 有伴生视图,
--      所以【必须】在视图里,授不授权都一样。
-- db/preflight_migration.py 的 masked 行会在这支跑起来【之前】检查这一点。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- ① home_greetings
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.home_greetings (
    -- ★【id 是【可读的自然键】,不是 uuid】★ 它会被写进浏览器的 cookie
    --   (上一句是哪一句),而 uuid 每次重建都不一样 —— 那会让一份从仓库重建
    --   出来的库与线上对同一句话给出不同的 id。`morning-04` 重建一万次都一样,
    --   而且在 cookie 里、在 data-home-greeting 属性里都读得懂。
    id          text PRIMARY KEY CHECK (id ~ '^[a-z_]+-[0-9]{2}$'),
    slot        text NOT NULL CHECK (slot IN ('early_morning','morning','midday','afternoon','evening','late_night')),
    -- ★★【只有英文,而这是【裁定】,不是漏了 —— 不许"顺手补上中文"】★★
    --   Tim 的裁定(UI-1b,2026-09-05):**一个 zh 语言的读者看到英文问候语,
    --   那就是预期状态。** 先例是 kpi_score_rubric:band_en/band_zh 成对,而
    --   evidence_standard_en / management_action_en / veto_rule_en /
    --   review_cadence_en 【只有英文】,因为原始文本就是英文的。
    --   **也不许加一个空的 line_zh 列"留着以后填"** —— Tim 的原话:
    --   一个空列是一句 schema 替没人许下的承诺。
    --   真要中文,那是一次带着 72 句译文的裁定,不是一次列变更。
    line_en     text NOT NULL CHECK (btrim(line_en) <> ''),
    -- ★【没有 {name} 的一句话,是一句谁也没问候到的话】★ 而它不会报错,
    --   只会安静地少一个人名 —— 所以这条约束在库里,不在代码里。
    CONSTRAINT home_greetings_names_someone CHECK (line_en LIKE '%{name}%'),
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_home_greetings_slot ON public.home_greetings (slot) WHERE is_active;

CREATE TRIGGER trg_home_greetings_updated_at
    BEFORE UPDATE ON public.home_greetings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.home_greetings ENABLE ROW LEVEL SECURITY;
-- 【任何登录用户可读】首页每个人都会打开,而问候语是说给他听的。
-- 与 public_holidays / kpi_score_rubric 同一条判据。
CREATE POLICY "home_greetings select all"
    ON public.home_greetings AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- 【写入归设置】改一句问候语是一次系统文案调整,不属于任何业务模块。
CREATE POLICY "home_greetings insert by permission"
    ON public.home_greetings AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "home_greetings update by permission"
    ON public.home_greetings AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions')) WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "home_greetings delete by permission"
    ON public.home_greetings AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'));

-- ── 种子:Tim 批准的 72 句原文 ──────────────────────────────────────────
INSERT INTO public.home_greetings (id, slot, line_en) VALUES
    ('early_morning-01', 'early_morning', 'Good morning, {name}.'),
    ('early_morning-02', 'early_morning', 'Early start, {name}.'),
    ('early_morning-03', 'early_morning', 'Morning, {name} — the plant is waking up.'),
    ('early_morning-04', 'early_morning', 'First one in, {name}?'),
    ('early_morning-05', 'early_morning', 'Morning, {name}. Coffee first.'),
    ('early_morning-06', 'early_morning', 'A quiet hour, {name}. Use it well.'),
    ('early_morning-07', 'early_morning', 'Good morning, {name}. Fresh page today.'),
    ('early_morning-08', 'early_morning', 'Morning, {name} — nothing has gone wrong yet.'),
    ('early_morning-09', 'early_morning', 'Up early, {name}. That counts for something.'),
    ('early_morning-10', 'early_morning', 'Morning, {name}. Let''s see what today brings.'),
    ('early_morning-11', 'early_morning', 'Good morning, {name}. Take it steady.'),
    ('early_morning-12', 'early_morning', 'Early light, {name}.'),
    ('morning-01', 'morning', 'Good morning, {name}.'),
    ('morning-02', 'morning', 'Morning, {name}. Deep in it already?'),
    ('morning-03', 'morning', 'Hello, {name}. Good hour for the hard thing.'),
    ('morning-04', 'morning', 'Morning, {name} — this is when the day is most yours.'),
    ('morning-05', 'morning', 'Hi, {name}. One thing at a time.'),
    ('morning-06', 'morning', 'Good morning, {name}. The quiet part is over.'),
    ('morning-07', 'morning', 'Morning, {name}. Still plenty of day left.'),
    ('morning-08', 'morning', 'Hello, {name}. Pick the difficult one first.'),
    ('morning-09', 'morning', 'Morning, {name} — you''re ahead of the afternoon.'),
    ('morning-10', 'morning', 'Hi, {name}. Steady progress counts.'),
    ('morning-11', 'morning', 'Good morning, {name}. No rush.'),
    ('morning-12', 'morning', 'Morning, {name}.'),
    ('midday-01', 'midday', 'Lunch, {name}? The work will wait.'),
    ('midday-02', 'midday', 'Midday, {name}. Eat something.'),
    ('midday-03', 'midday', 'Hello, {name}. Take the break.'),
    ('midday-04', 'midday', '{name}, the batches can spare you an hour.'),
    ('midday-05', 'midday', 'Half the day done, {name}.'),
    ('midday-06', 'midday', 'Lunchtime, {name}. Step away from the screen.'),
    ('midday-07', 'midday', 'Hi, {name}. Don''t skip it again.'),
    ('midday-08', 'midday', 'Midday, {name}. Food, then the rest.'),
    ('midday-09', 'midday', '{name}, even the plant stops for lunch.'),
    ('midday-10', 'midday', 'Halfway, {name}. Refuel.'),
    ('midday-11', 'midday', 'Hello, {name}. Eat first, decide after.'),
    ('midday-12', 'midday', 'Lunch break, {name}.'),
    ('afternoon-01', 'afternoon', 'Good afternoon, {name}.'),
    ('afternoon-02', 'afternoon', 'Afternoon, {name}. The long stretch.'),
    ('afternoon-03', 'afternoon', 'Hello, {name}. Still going?'),
    ('afternoon-04', 'afternoon', 'Afternoon, {name} — a good time to finish things, not start them.'),
    ('afternoon-05', 'afternoon', 'Hi, {name}. Clear one thing off the list.'),
    ('afternoon-06', 'afternoon', 'Good afternoon, {name}. Nearly through.'),
    ('afternoon-07', 'afternoon', 'Afternoon, {name}. Water helps.'),
    ('afternoon-08', 'afternoon', 'Hello, {name}. The quiet stretch before the end.'),
    ('afternoon-09', 'afternoon', 'Afternoon, {name} — small things add up now.'),
    ('afternoon-10', 'afternoon', 'Hi, {name}. Keep it moving.'),
    ('afternoon-11', 'afternoon', 'Good afternoon, {name}. Almost there.'),
    ('afternoon-12', 'afternoon', 'Afternoon, {name}.'),
    ('evening-01', 'evening', 'Good evening, {name}.'),
    ('evening-02', 'evening', 'Evening, {name}. Winding down?'),
    ('evening-03', 'evening', 'Hello, {name}. Long enough for one day.'),
    ('evening-04', 'evening', 'Evening, {name} — tomorrow will still be there.'),
    ('evening-05', 'evening', 'Hi, {name}. Finish the one, leave the rest.'),
    ('evening-06', 'evening', 'Good evening, {name}. You''ve done enough.'),
    ('evening-07', 'evening', 'Evening, {name}. Time to close the laptop soon.'),
    ('evening-08', 'evening', 'Hello, {name}. The day is nearly yours again.'),
    ('evening-09', 'evening', 'Evening, {name} — go home at some point.'),
    ('evening-10', 'evening', 'Hi, {name}. Last stretch.'),
    ('evening-11', 'evening', 'Good evening, {name}. Wrap it up gently.'),
    ('evening-12', 'evening', 'Evening, {name}.'),
    ('late_night-01', 'late_night', 'Still up, {name}?'),
    ('late_night-02', 'late_night', 'Late, {name}. It can wait until morning.'),
    ('late_night-03', 'late_night', 'Hello, {name}. Nothing here is urgent enough for this hour.'),
    ('late_night-04', 'late_night', '{name}, sleep is also part of the work.'),
    ('late_night-05', 'late_night', 'Late night, {name}. Be kind to tomorrow.'),
    ('late_night-06', 'late_night', 'Still here, {name}. Don''t make it a habit.'),
    ('late_night-07', 'late_night', 'Hello, {name}. Save it and go to bed.'),
    ('late_night-08', 'late_night', '{name}, the plant is asleep. You could be too.'),
    ('late_night-09', 'late_night', 'Late, {name}. Tomorrow-you will thank you.'),
    ('late_night-10', 'late_night', 'Still working, {name}? One more, then stop.'),
    ('late_night-11', 'late_night', 'Hello, {name}. This will look easier at nine.'),
    ('late_night-12', 'late_night', 'Late, {name}. Go rest.');


-- ════════════════════════════════════════════════════════════════════════════
-- ② festival_doodles
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.festival_doodles (
    -- 与 public_holidays.holiday_key 【同一种拼法】,而【不是同一个键空间】——
    -- 两张表各自表达自己的事实,不交叉引用(见抬头)。产物文件名就是它:
    -- public/brand/festivals/<holiday_key>.webp,代码里没有第二张映射表。
    holiday_key   text PRIMARY KEY CHECK (holiday_key ~ '^[a-z][a-z0-9-]*$'),
    name_en       text NOT NULL CHECK (btrim(name_en) <> ''),
    -- 【这一栏成对,而问候语那张表不成对 —— 两者不矛盾】节日名会进 <img alt>,
    -- 一个 zh 读者的读屏软件念出「圣诞节」是对的;而 72 句问候语是 Tim 写的
    -- 英文原文,翻译它是另一次裁定。见 db/tables/home_greetings.sql。
    name_zh       text NOT NULL CHECK (btrim(name_zh) <> ''),
    festival_date date NOT NULL,
    -- ★★【存【算好的日期】,不存规则】★★ Tim 的三条特例本身就不规则
    -- (圣诞提前 3 天一直到元旦前一天、元旦当天起 3 天、农历新年提前 3 天整窗 7 天),
    -- 而下一个节日可能又要一条它自己的。**存规则要改代码,存日期只要改一行。**
    window_start  date NOT NULL,
    window_end    date NOT NULL,
    is_active     boolean NOT NULL DEFAULT true,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid DEFAULT auth.uid(),
    CONSTRAINT festival_doodles_window_ordered CHECK (window_start <= window_end),
    -- ★【节日那天必须【在】它自己的窗口里】★ 三条特例全部满足它,而一条
    --   把节日排在窗口外面的行,是一次录入错误 —— 它不会报错,只会让画在
    --   错的日子出现。所以判据在库里。
    CONSTRAINT festival_doodles_date_inside CHECK (window_start <= festival_date AND festival_date <= window_end)
);

CREATE INDEX idx_festival_doodles_window ON public.festival_doodles (window_start, window_end) WHERE is_active;

CREATE TRIGGER trg_festival_doodles_updated_at
    BEFORE UPDATE ON public.festival_doodles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.festival_doodles ENABLE ROW LEVEL SECURITY;
-- 【任何登录用户可读】首页每个人都会打开。
CREATE POLICY "festival_doodles select all"
    ON public.festival_doodles AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "festival_doodles insert by permission"
    ON public.festival_doodles AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "festival_doodles update by permission"
    ON public.festival_doodles AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions')) WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "festival_doodles delete by permission"
    ON public.festival_doodles AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'));

-- ── 种子:23 个节日,窗口按 Tim 的三条特例 + 一条通则算好 ──────────────
INSERT INTO public.festival_doodles
    (holiday_key, name_en, name_zh, festival_date, window_start, window_end) VALUES
    ('world-ev-day', 'World EV Day', '世界电动车日', DATE '2026-09-09', DATE '2026-09-08', DATE '2026-09-09'),
    ('mid-autumn-festival', 'Mid-Autumn Festival', '中秋节', DATE '2026-09-25', DATE '2026-09-24', DATE '2026-09-25'),
    ('childrens-day', 'Children''s Day', '儿童节', DATE '2026-10-02', DATE '2026-10-01', DATE '2026-10-02'),
    ('halloween', 'Halloween', '万圣节', DATE '2026-10-31', DATE '2026-10-30', DATE '2026-10-31'),
    ('deepavali', 'Deepavali', '屠妖节', DATE '2026-11-08', DATE '2026-11-07', DATE '2026-11-08'),
    ('thanksgiving-day', 'Thanksgiving Day', '感恩节', DATE '2026-11-26', DATE '2026-11-25', DATE '2026-11-26'),
    ('christmas-day', 'Christmas Day', '圣诞节', DATE '2026-12-25', DATE '2026-12-22', DATE '2026-12-31'),
    ('new-years-day', 'New Year''s Day', '元旦', DATE '2027-01-01', DATE '2027-01-01', DATE '2027-01-03'),
    ('chinese-new-year', 'Chinese New Year', '农历新年', DATE '2027-02-06', DATE '2027-02-03', DATE '2027-02-09'),
    ('valentines-day', 'Valentine''s Day', '情人节', DATE '2027-02-14', DATE '2027-02-13', DATE '2027-02-14'),
    ('international-womens-day', 'International Women''s Day', '国际妇女节', DATE '2027-03-08', DATE '2027-03-07', DATE '2027-03-08'),
    ('hari-raya-puasa', 'Hari Raya Puasa', '开斋节', DATE '2027-03-10', DATE '2027-03-09', DATE '2027-03-10'),
    ('global-recycling-day', 'Global Recycling Day', '全球回收日', DATE '2027-03-18', DATE '2027-03-17', DATE '2027-03-18'),
    ('good-friday', 'Good Friday', '耶稣受难日', DATE '2027-03-26', DATE '2027-03-25', DATE '2027-03-26'),
    ('easter-sunday', 'Easter Sunday', '复活节', DATE '2027-03-28', DATE '2027-03-27', DATE '2027-03-28'),
    ('earth-day', 'Earth Day', '世界地球日', DATE '2027-04-22', DATE '2027-04-21', DATE '2027-04-22'),
    ('labour-day', 'Labour Day', '劳动节', DATE '2027-05-01', DATE '2027-04-30', DATE '2027-05-01'),
    ('mothers-day', 'Mother''s Day', '母亲节', DATE '2027-05-09', DATE '2027-05-08', DATE '2027-05-09'),
    ('hari-raya-haji', 'Hari Raya Haji', '哈芝节', DATE '2027-05-17', DATE '2027-05-16', DATE '2027-05-17'),
    ('vesak-day', 'Vesak Day', '卫塞节', DATE '2027-05-20', DATE '2027-05-19', DATE '2027-05-20'),
    ('fathers-day', 'Father''s Day', '父亲节', DATE '2027-06-20', DATE '2027-06-19', DATE '2027-06-20'),
    ('national-day', 'National Day', '国庆日', DATE '2027-08-09', DATE '2027-08-08', DATE '2027-08-09'),
    ('hungry-ghost-festival', 'Hungry Ghost Festival', '中元节', DATE '2027-08-16', DATE '2027-08-15', DATE '2027-08-16');


-- ════════════════════════════════════════════════════════════════════════════
-- ③ employees.greeting_name —— 列 + 授权 + 遮蔽视图,三样在一起
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.employees ADD COLUMN greeting_name text;

COMMENT ON COLUMN public.employees.greeting_name IS
    'UI-1b:首页问候语里怎么称呼这个人。取值顺序 greeting_name ?? preferred_name ?? legal_name。★ 不要复用 preferred_name ★ —— 那是全站显示名(ActorName / TopNav / /me / 组织架构图),把 Sandra Yap 的 preferred_name 改成「Sand」会让组织架构图与每一条审计留痕上她都叫 Sand。一句问候语的昵称,不该改写一个人在系统里的名字。';

-- 【列清单授权不会自动扩展到后加的列】—— 这一句漏了,这一列就是"写得进、读不出",
-- 而页面会拿到 42501。它不敏感(一个昵称),所以照常授权。
GRANT SELECT (greeting_name) ON public.employees TO authenticated;

-- 【遮蔽视图必须跟着追加】colgrant:employees 有 _masked 伴生 → 每一列都必须在里面。
CREATE OR REPLACE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    preferred_name,
    department_id,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- **列名保持 job_title**,是为了不惊动这张视图的下游读者 ——
    -- 它回答的仍然是同一个问题(这个人的头衔是什么),只是真源换了。
    (SELECT p.title FROM positions p WHERE p.id = employees.position_id) AS job_title,
    manager_id,
    employment_type,
    work_category,
    hire_date,
    probation_end_date,
    employment_status,
    separation_date,
    separation_type,
    separation_notes,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date,
    work_pass_expiry_date,
    user_id,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    confirmation_date,
        CASE
            WHEN has_permission('data.view_pay'::text) OR id = current_user_employee() THEN monthly_salary
            ELSE NULL::numeric
        END AS monthly_salary,
    monthly_salary_set,
    review_exempt,
        CASE
            WHEN deleted_at IS NULL THEN annual_leave_rate_per_year(id)
            ELSE NULL::numeric
        END AS annual_leave_rate_days,
        CASE
            WHEN deleted_at IS NULL THEN accrued_annual_leave(id)
            ELSE NULL::numeric
        END AS annual_leave_accrued_days,
        CASE
            WHEN deleted_at IS NULL THEN (leave_balance_internal(id, 'annual'::text) ->> 'available'::text)::numeric
            ELSE NULL::numeric
        END AS annual_leave_available_days,
    anonymised_at,
    anonymised_by,
    -- KPI-1:新列加在【末尾】—— CREATE OR REPLACE VIEW 只允许末尾追加列。
    -- 【它必须出现在这张视图里】employees 是遮蔽表,而 colgrant 那道闸要求它的
    -- 每一列要么被列授权、要么出现在 _masked 里(WO-1a 那一课)。
    position_id,
    -- UI-1b:同 position_id —— employees 是遮蔽表,colgrant 要求每一列要么被列授权、
    -- 要么出现在这张视图里(WO-1a 那一课)。greeting_name 两样都做了:它不敏感。
    greeting_name
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

-- my_profile 也追加同一列 —— 首页问候语读的就是这张视图。
CREATE OR REPLACE VIEW public.my_profile WITH (security_invoker = off) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- 列名保持 job_title,是为了让 /me 那一格与它的历史记录读起来仍然是同一件事
    -- (employment_history.job_title 是那一天的文本快照,这里是"今天的")。
    pos.title AS job_title,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    annual_leave_rate_per_year(e.id) AS annual_leave_rate_days,
    accrued_annual_leave(e.id) AS annual_leave_accrued_days,
    (leave_balance_internal(e.id, 'annual'::text) ->> 'available'::text)::numeric AS annual_leave_available_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_no,
    e.work_pass_issue_date,
    e.work_pass_expiry_date,
    e.identity_no,
    e.work_email,
    e.work_phone,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    mgr.legal_name AS manager_name,
    mgr.code AS manager_code,
    COALESCE(tr.cnt, 0::bigint) AS training_count,
    pp.code AS latest_payroll_code,
    pp.period_month AS latest_payroll_month,
    -- KPI-1:【新列加在末尾】—— CREATE OR REPLACE VIEW 只允许在末尾追加列,
    -- 中间插一列要 DROP + 重建,而这张视图有下游读者。
    pos.code AS position_code,
    -- UI-1b:【新列加在末尾】—— CREATE OR REPLACE VIEW 只允许末尾追加。
    -- 首页问候语读的就是这一行(lib/homeGreeting.ts:getHomeGreeting)。
    e.greeting_name
   FROM employees e
     LEFT JOIN positions pos ON pos.id = e.position_id
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT count(*) AS cnt
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
     LEFT JOIN LATERAL ( SELECT p.code,
            p.period_month
           FROM payroll_lines pl
             JOIN payroll_periods p ON p.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND p.status = 'posted'::text AND p.deleted_at IS NULL
          ORDER BY p.period_month DESC
         LIMIT 1) pp ON true
  WHERE e.id = current_user_employee() AND e.deleted_at IS NULL;

-- ════════════════════════════════════════════════════════════════════════════
-- ④ hr_alerts:多一支 festival_doodles_exhausted
--    ★ 新增一支就要补两个语言 ★ —— scripts/check-i18n.mjs 从【本视图】现读
--      alert_type 的字面量集合,少一句构建就红。已补:
--      messages/en.ts / messages/zh.ts 的 hr.alertType.festival_doodles_exhausted。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE VIEW public.hr_alerts WITH (security_invoker = off) AS
 SELECT alert_type,
    severity,
    employee_id,
    employee_code,
    employee_name,
    subject,
    due_date,
    days_remaining
   FROM ( SELECT 'work_pass_expiry'::text AS alert_type,
                CASE
                    WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
                    WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            COALESCE(e.work_pass_type, 'Work pass'::text) AS subject,
            e.work_pass_expiry_date AS due_date,
            e.work_pass_expiry_date - CURRENT_DATE AS days_remaining
           FROM employees e
          WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND e.work_pass_expiry_date IS NOT NULL AND (e.work_pass_expiry_date - CURRENT_DATE) <= 90 AND (e.work_pass_expiry_date - CURRENT_DATE) >= '-30'::integer
        UNION ALL
         SELECT 'probation_ending'::text AS alert_type,
                CASE
                    WHEN (e.probation_end_date - CURRENT_DATE) <= 14 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Probation'::text AS subject,
            e.probation_end_date AS due_date,
            e.probation_end_date - CURRENT_DATE AS days_remaining
           FROM employees e
          WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date >= CURRENT_DATE AND (e.probation_end_date - CURRENT_DATE) <= 30 AND NOT (EXISTS ( SELECT 1
                   FROM performance_reviews r
                  WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'confirm'::text)) AND NOT (EXISTS ( SELECT 1
                   FROM performance_reviews u
                  WHERE u.employee_id = e.id AND u.review_type = 'probation'::text AND (u.status = ANY (ARRAY['draft'::text, 'self_review'::text, 'submitted'::text]))))
        UNION ALL
         SELECT 'probation_review_underway'::text AS alert_type,
            'warning'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Probation review in progress'::text AS subject,
            e.probation_end_date AS due_date,
            e.probation_end_date - CURRENT_DATE AS days_remaining
           FROM employees e
             JOIN performance_reviews u ON u.employee_id = e.id AND u.review_type = 'probation'::text AND (u.status = ANY (ARRAY['draft'::text, 'self_review'::text, 'submitted'::text]))
          WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text
        UNION ALL
         SELECT 'probation_overdue'::text AS alert_type,
            'expired'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Probation ended without a decision'::text AS subject,
            e.probation_end_date AS due_date,
            e.probation_end_date - CURRENT_DATE AS days_remaining
           FROM employees e
          WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND e.probation_end_date IS NOT NULL AND e.probation_end_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM performance_reviews r
                  WHERE r.employee_id = e.id AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome IS NOT NULL))
        UNION ALL
         SELECT 'probation_not_confirmed'::text AS alert_type,
            'expired'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Probation not confirmed — separation is a manual decision'::text AS subject,
            COALESCE(e.probation_end_date, r.approved_at::date) AS due_date,
            COALESCE(e.probation_end_date, r.approved_at::date) - CURRENT_DATE AS days_remaining
           FROM employees e
             JOIN performance_reviews r ON r.employee_id = e.id
          WHERE e.deleted_at IS NULL AND e.employment_status = 'probation'::text AND r.review_type = 'probation'::text AND (r.status = ANY (ARRAY['approved'::text, 'acknowledged'::text])) AND r.probation_outcome = 'not_confirm'::text
        UNION ALL
         SELECT 'salary_not_set'::text AS alert_type,
                CASE
                    WHEN e.employment_status = 'notice'::text THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            'Monthly fixed gross not set — leave encashment cannot be computed'::text AS subject,
            NULL::date AS due_date,
            NULL::integer AS days_remaining
           FROM employees e
          WHERE e.deleted_at IS NULL AND (e.employment_status = ANY (ARRAY['probation'::text, 'active'::text, 'notice'::text])) AND NOT e.monthly_salary_set
        UNION ALL
         SELECT 'review_no_reviewer'::text AS alert_type,
            'critical'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            COALESCE(c.name, 'Probation review'::text) || ' — no reviewer assigned'::text AS subject,
            c.due_date,
            c.due_date - CURRENT_DATE AS days_remaining
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
             LEFT JOIN review_cycles c ON c.id = r.cycle_id
          WHERE r.reviewer_employee_id IS NULL AND (r.status <> ALL (ARRAY['approved'::text, 'acknowledged'::text, 'void'::text])) AND e.deleted_at IS NULL
        UNION ALL
         SELECT 'review_cycle_overdue'::text AS alert_type,
            'critical'::text AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            c.name AS subject,
            c.due_date,
            c.due_date - CURRENT_DATE AS days_remaining
           FROM performance_reviews r
             JOIN review_cycles c ON c.id = r.cycle_id
             JOIN employees e ON e.id = r.employee_id
          WHERE c.deleted_at IS NULL AND c.status = 'open'::text AND c.due_date < CURRENT_DATE AND (r.status = ANY (ARRAY['draft'::text, 'self_review'::text]))
        UNION ALL
         SELECT 'cpf_due'::text AS alert_type,
                CASE
                    WHEN (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date < CURRENT_DATE THEN 'expired'::text
                    WHEN ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 3 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            NULL::uuid AS employee_id,
            p.code AS employee_code,
            'CPF'::text AS employee_name,
            'CPF contribution unpaid — due 14th of the following month, late payment attracts interest'::text AS subject,
            (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date AS due_date,
            (date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE AS days_remaining
           FROM payroll_periods p
          WHERE p.deleted_at IS NULL AND p.status = 'posted'::text AND p.cpf_paid_at IS NULL AND (COALESCE(p.employer_cpf_total, 0::numeric) + COALESCE(p.employee_cpf_total, 0::numeric)) > 0::numeric AND ((date_trunc('month'::text, p.period_month::timestamp with time zone) + '1 mon 13 days'::interval)::date - CURRENT_DATE) <= 7
        UNION ALL
         SELECT 'training_expiry'::text AS alert_type,
                CASE
                    WHEN t.expiry_date < CURRENT_DATE THEN 'expired'::text
                    WHEN (t.expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            e.id AS employee_id,
            e.code AS employee_code,
            e.legal_name AS employee_name,
            t.training_name AS subject,
            t.expiry_date AS due_date,
            t.expiry_date - CURRENT_DATE AS days_remaining
           FROM training_records t
             JOIN employees e ON e.id = t.employee_id
          WHERE t.deleted_at IS NULL AND e.deleted_at IS NULL AND e.employment_status <> 'separated'::text AND t.expiry_date IS NOT NULL AND (t.expiry_date - CURRENT_DATE) <= 90 AND (t.expiry_date - CURRENT_DATE) >= '-30'::integer
        UNION ALL
         SELECT 'holiday_calendar_missing'::text AS alert_type,
            'expired'::text AS severity,
            NULL::uuid AS employee_id,
            ''::text AS employee_code,
            ''::text AS employee_name,
            EXTRACT(year FROM CURRENT_DATE)::text AS subject,
            CURRENT_DATE AS due_date,
            0 AS days_remaining
          WHERE NOT (EXISTS ( SELECT 1
                   FROM public_holidays h
                  WHERE h.is_active AND h.country = 'SG'::text AND EXTRACT(year FROM h.holiday_date) = EXTRACT(year FROM CURRENT_DATE)))
        UNION ALL
         SELECT 'holiday_calendar_next_year'::text AS alert_type,
                CASE
                    WHEN EXTRACT(month FROM CURRENT_DATE) = 12::numeric THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            NULL::uuid AS employee_id,
            ''::text AS employee_code,
            ''::text AS employee_name,
            (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::text AS subject,
            make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) AS due_date,
            make_date((EXTRACT(year FROM CURRENT_DATE) + 1::numeric)::integer, 1, 1) - CURRENT_DATE AS days_remaining
          WHERE EXTRACT(month FROM CURRENT_DATE) >= 10::numeric AND NOT (EXISTS ( SELECT 1
                   FROM public_holidays h
                  WHERE h.is_active AND h.country = 'SG'::text AND EXTRACT(year FROM h.holiday_date) = (EXTRACT(year FROM CURRENT_DATE) + 1::numeric)))
        UNION ALL
        -- ★★【UI-1b:节日画的窗口要用完了】★★
        --   首页那 23 张节日画的最后一个窗口在 2027-08-16 结束。之后首页安静地
        --   画回平日字标 —— **那是对的,不是失败**。但【必须有人在那之前被叫住】。
        --
        --   【复用这一条通道,不另造一条】它与 holiday_calendar_next_year 是同一
        --   形状:一份【一次录一批】的日历,快要见底了。Tim 接受随之而来的代价 ——
        --   只有拿得到 module.hr.view 的人看得见它;而实际上"给假日表补下一年的人"
        --   与"给节日画补下一批的人"是同一个人。
        --
        --   【为什么 max_end 在【过去】时它仍然响】60 天的门槛写的是 <= 60,不是
        --   BETWEEN 0 AND 60。**窗口真的用完之后 days_remaining 变成负数,而这条
        --   告警必须继续响** —— 一条在问题真正发生的那天安静下来的告警,
        --   正是本仓库反复在修的那一类。
         SELECT 'festival_doodles_exhausted'::text AS alert_type,
                CASE
                    WHEN (x.max_end - CURRENT_DATE) <= 14 THEN 'critical'::text
                    ELSE 'warning'::text
                END AS severity,
            NULL::uuid AS employee_id,
            ''::text AS employee_code,
            ''::text AS employee_name,
            x.max_end::text AS subject,
            x.max_end AS due_date,
            x.max_end - CURRENT_DATE AS days_remaining
           FROM ( SELECT max(fd.window_end) AS max_end
                   FROM festival_doodles fd
                  WHERE fd.is_active) x
          WHERE x.max_end IS NOT NULL AND (x.max_end - CURRENT_DATE) <= 60
        UNION ALL
         SELECT 'system_start_not_set'::text AS alert_type,
            'expired'::text AS severity,
            NULL::uuid AS employee_id,
            ''::text AS employee_code,
            ''::text AS employee_name,
            ''::text AS subject,
            CURRENT_DATE AS due_date,
            0 AS days_remaining
          WHERE NOT (EXISTS ( SELECT 1
                   FROM finance_settings s
                  WHERE s.system_start_date IS NOT NULL))) a
  WHERE has_permission('module.hr.view'::text);

-- ════════════════════════════════════════════════════════════════════════════
-- ⑤ 两处数据订正 —— 各自独立成立,而它们【不是同一件事】
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【为什么只种一行 greeting_name】实测线上六个账号,五个用
--   preferred_name ?? legal_name 就已经是 Tim 要的那个名字:
--     Tim(legal_name)· Vince · Phua · Fu Sheng ✓,Choo Er 见下。
--   **推导不出来的只有 Sandra Yap → Sand。**
--   委托书原文写的是「六个都推导不出来」,而那句话只对一个人成立 —— 量过了。
UPDATE public.employees
   SET greeting_name = 'Sand'
 WHERE legal_name = 'Sandra Yap' AND deleted_at IS NULL;

-- 【这一条【不是】问候语的事,它是一处录入错误】'Chooer' 不是任何人的名字。
--   它印在 ActorName.tsx:79、TopNav.tsx:161、app/me/page.tsx:202、
--   app/hr/org/page.tsx:90 —— 也就是审计留痕、顶栏、个人档案与组织架构图。
--   修好它是对的,与本刀无关;而修好之后,她的问候语顺带就对了,
--   于是【不需要】给她也种一行 greeting_name。
UPDATE public.employees
   SET preferred_name = 'Choo Er'
 WHERE legal_name = 'Choo Er Teh' AND preferred_name = 'Chooer' AND deleted_at IS NULL;

COMMIT;

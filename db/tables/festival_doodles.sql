-- db/tables/festival_doodles.sql
-- 首页字标在节日窗口里换成的那 23 张画,以及各自的窗口。
--
-- NOTE: introduced by db/migrations/2026-09-05-ui1b-home-greeting-and-festival-doodles.sql.
-- First-run script (plain CREATEs).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- ★★【为什么它【不是】 public_holidays 的一列 —— 这条要写在最上面】★★
--
-- C-2 当时被要求"把假日表设计成两个消费方共用"。**那条指示是错的,Tim 已推翻
-- (UI-1b,2026-09-05)。**
--
-- 23 个节日里只有 **10 个**是新加坡公共假期。共用一张表意味着:
-- **谁为了让首页出现一张万圣节的画而加了一行,就同时把那天变成了非工作日** ——
-- 于是每个人的年假计算、每张考勤表、以及 is_business_day()(它还是 FX 回溯那条
-- 规矩的判据)全都跟着变。
--
-- > **一个公共假期是一件【工作日事实】;一张节日画是【装饰】。不该共用一行。**
--
-- C-2 的 holiday_key 与 is_in_lieu 【留着】,一点没浪费 —— 跨年份稳定的身份
-- 本来就有用。某个节日碰巧也是公共假期,那是一次巧合:**两张表各记各的,
-- 不交叉引用。**
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG】加一个节日 = 丢一张图进源目录、跑一次
-- scripts/build-festival-doodles.mjs、在这张表里加一行。**一行代码都不用改。**
-- 所以线上与本文件不一致是正常的,check_mirrors.py 不逐行比对它。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【两处首尾相接,那是相邻,不是重叠 —— 记在这里免得被当成 bug 报上来】
--   圣诞 12-31 结束 → 元旦 01-01 开始;耶稣受难日 03-26 结束 → 复活节 03-27 开始。
--   中间没有一天是平日字标。
-- 【将来真的重叠了谁赢】短窗口 > 晚开始 > holiday_key 升序。判据在
--   lib/festivalDoodle.ts,理由在 docs/information-architecture.md §20。
-- 【最后一个窗口 2027-08-16 结束】到期前有人会被叫住:db/views/hr_alerts.sql
--   的 festival_doodles_exhausted 一支,60 天 warning、14 天 critical。

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

-- db/tables/public_holidays.sql
-- 公共假期。任何登录用户可读(谁都要知道哪天不上班),写入归 hr 模块。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 界面上可以增删改(app/hr/leave/types/actions.ts:37-47)。
-- 所以【线上与本文件不一致是正常的,不是漂移】,check_mirrors.py 不把本表与线上比对。
-- 它只保证镜像这一套自己首尾相顾(本文件引用到的码/科目都存在于对应的种子里)。
-- ═══════════════════════════════════════════════════════════════════════════

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
    updated_by   uuid DEFAULT auth.uid(),
    -- ★★ 下面两列是 C-2 用 ALTER 加的,所以它们在线上排在【最后】★★
    --   镜像必须照线上的 ordinal order 写(AGENTS.md:ALTER-added columns stay at the end)。
    -- ★ C-2:跨年份稳定的身份。日期年年在动(农历、回历),而"今天是不是农历
    --   新年"这个问题每年要得到同一个答案 —— 所以问的是这个键,不是日期,
    --   也不是显示名(`Vesak Day` 与 `Vesak Day (in lieu)` 已经不是同一串字)。
    --   工作日计算读 holiday_date。
    --
    -- ★★【更正(UI-1b,2026-09-05):这里原本写着「UI-1 的节日 logo 读它」——
    --      那句话【从今天起是假的】,而【必须连理由一起写下来】】★★
    --   节日 logo 读的是 **public.festival_doodles**,一张【另外的表】。
    --   C-2 当时被要求"把这张表设计成两个消费方共用",那条指示是错的,Tim 已推翻。
    --
    --   【为什么必须分开 —— 不写下这条,下一个读者会热心地把它们并回去】
    --   UI-1b 那 23 个节日里,**只有 10 个是新加坡公共假期**。共用一张表意味着:
    --   **谁为了让首页出现一张万圣节的画而在这里加了一行,就同时把 10 月 31 日
    --   变成了非工作日** —— 于是每一个人的年假计算变了、每一张考勤表变了,
    --   连 is_business_day() 都变了(它还是 FX 回溯那条规矩的判据)。
    --
    --   > **一个公共假期是一件【工作日事实】;一张节日画是【装饰】。**
    --
    --   holiday_key 与 is_in_lieu 【留着】,一点没浪费 —— 跨年份稳定的身份本来
    --   就有用。某个节日碰巧也是公共假期,那是一次巧合:两张表各记各的,
    --   **不交叉引用**。
    holiday_key  text NOT NULL CHECK (holiday_key ~ '^[a-z][a-z0-9-]*$'),
    -- ★ 补假与被补的那天【共用同一个 holiday_key】—— 只看键分不出哪一行是补的
    is_in_lieu   boolean NOT NULL DEFAULT false
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
INSERT INTO public.public_holidays (holiday_date, name_en, name_zh, holiday_key, is_in_lieu, notes) VALUES
    ('2026-01-01', 'New Year''s Day',      '元旦',        'new-year',         false, 'Thursday'),
    ('2026-02-17', 'Chinese New Year',     '农历新年',    'chinese-new-year', false, 'Tuesday (day 1)'),
    ('2026-02-18', 'Chinese New Year',     '农历新年',    'chinese-new-year', false, 'Wednesday (day 2)'),
    ('2026-03-21', 'Hari Raya Puasa',      '开斋节',      'hari-raya-puasa',  false, 'Saturday — lunar, confirmed by the authorities'),
    ('2026-04-03', 'Good Friday',          '耶稣受难日',  'good-friday',      false, 'Friday'),
    ('2026-05-01', 'Labour Day',           '劳动节',      'labour-day',       false, 'Friday'),
    ('2026-05-27', 'Hari Raya Haji',       '哈芝节',      'hari-raya-haji',   false, 'Wednesday — lunar, confirmed by the authorities'),
    ('2026-05-31', 'Vesak Day',            '卫塞节',      'vesak-day',        false, 'Sunday'),
    ('2026-06-01', 'Vesak Day (in lieu)',  '卫塞节补假',  'vesak-day',        true,  'Monday in lieu of Sunday 31 May'),
    ('2026-08-09', 'National Day',         '国庆日',      'national-day',     false, 'Sunday'),
    ('2026-08-10', 'National Day (in lieu)','国庆日补假', 'national-day',     true,  'Monday in lieu of Sunday 9 Aug'),
    ('2026-11-08', 'Deepavali',            '屠妖节',      'deepavali',        false, 'Sunday'),
    ('2026-11-09', 'Deepavali (in lieu)',  '屠妖节补假',  'deepavali',        true,  'Monday in lieu of Sunday 8 Nov'),
    ('2026-12-25', 'Christmas Day',        '圣诞节',      'christmas',        false, 'Friday');

-- 【2027 年新加坡宪报公布的公共假期】—— MOM 新闻稿《Public Holidays for 2027》,
-- 2026-06-18 发布;C-2 于 2026-09-05 取用。
-- 11 个法定假日 + 1 个"逢周日顺延周一"的补假(农历新年落在 2 月 7 日周日)= 12 个日期。
-- ⚠【农历与回历日期不去计算】—— 与 2026 那一批同一条规矩:等官方公布。
INSERT INTO public.public_holidays (holiday_date, name_en, name_zh, holiday_key, is_in_lieu, notes) VALUES
    ('2027-01-01', 'New Year''s Day',        '元旦',       'new-year',         false, 'Friday'),
    ('2027-02-06', 'Chinese New Year',       '农历新年',   'chinese-new-year', false, 'Saturday (day 1)'),
    ('2027-02-07', 'Chinese New Year',       '农历新年',   'chinese-new-year', false, 'Sunday (day 2)'),
    ('2027-02-08', 'Chinese New Year (in lieu)', '农历新年补假', 'chinese-new-year', true, 'Monday in lieu of Sunday 7 Feb — gazetted by MOM'),
    ('2027-03-10', 'Hari Raya Puasa',        '开斋节',     'hari-raya-puasa',  false, 'Wednesday — lunar, confirmed by the authorities'),
    ('2027-03-26', 'Good Friday',            '耶稣受难日', 'good-friday',      false, 'Friday'),
    ('2027-05-01', 'Labour Day',             '劳动节',     'labour-day',       false, 'Saturday'),
    ('2027-05-17', 'Hari Raya Haji',         '哈芝节',     'hari-raya-haji',   false, 'Monday — lunar, confirmed by the authorities'),
    ('2027-05-20', 'Vesak Day',              '卫塞节',     'vesak-day',        false, 'Thursday'),
    ('2027-08-09', 'National Day',           '国庆日',     'national-day',     false, 'Monday'),
    ('2027-10-28', 'Deepavali',              '屠妖节',     'deepavali',        false, 'Thursday'),
    ('2027-12-25', 'Christmas Day',          '圣诞节',     'christmas',        false, 'Saturday');

COMMENT ON COLUMN public.public_holidays.holiday_key IS
    'C-2:【跨年份稳定的身份】。日期年年在动(农历、回历),而"今天是不是农历新年"这个问题每年要得到同一个答案 —— 所以问的是这个键,不是日期,也不是显示名(`Vesak Day` 与 `Vesak Day (in lieu)` 已经不是同一串字,而手打的名字还会多一个空格)。**UI-1 的节日 logo 读它;工作日计算继续读 holiday_date。一张表两个读者 —— 两份假期清单是两套系统开始对"今天是哪天"各执一词的方式。**';
COMMENT ON COLUMN public.public_holidays.is_in_lieu IS
    'C-2:这一行是不是【补假】(逢周日顺延的那个周一)。补假与被补的那天**共用同一个 holiday_key** —— 它们是同一个节日,所以只看键分不出来。逢周日补周一这条规矩在本仓库里一直是【数据】不是逻辑:官方公布哪天补就存哪天,不去推算。';

-- ============================================================================

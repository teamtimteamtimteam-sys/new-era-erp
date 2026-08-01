-- db/tables/public_holidays.sql
-- 公共假期。任何登录用户可读(谁都要知道哪天不上班),写入归 hr 模块。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

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

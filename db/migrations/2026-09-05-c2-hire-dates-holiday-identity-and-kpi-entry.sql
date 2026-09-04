-- db/migrations/2026-09-05-c2-hire-dates-holiday-identity-and-kpi-entry.sql
-- ════════════════════════════════════════════════════════════════════════════
-- C-2(2026-09-05)· 发六个账号之前的最后一刀
-- ════════════════════════════════════════════════════════════════════════════
--
-- 三件事,一支迁移:
--   ① 四个占位员工档案变成事实(入职日 / 居留身份 / 职位),清掉占位备注;
--   ② 公共假期长出【跨年份稳定的身份】,并载入 2027(MOM 2026-06-18 已公布);
--   ③ KPI 月度录入所缺的那几样:反馈字段、关口锁、打分刻度表、六个月周期、
--      以及九月那一批条目。
--
-- ★★【本刀勘察推翻的两条前提,写在这里,因为它们改变了这支迁移做什么】★★
--   (a)【四个人的假期余额并没有算错】accrued_annual_leave_detail 从
--       date_trunc('month', hire_date) 起累积,而 2026-09-04 与 2026-09-01
--       是同一个月 —— 两者算出来的余额【逐位相同】(今天 0 天,12-31 时 8 天)。
--       所以下面那四条 UPDATE 修的是【档案的正确性】,不是一个正在算错的数。
--       委托原文写着"那四个人的假期余额现在是错的";它不是。
--   (b)【零头月怎么取整,树里早就答了】同一支函数的抬头写着
--       「入职当月算整月;某个月要满了才计入」—— 9 月 15 日入职的人拿整个 9 月,
--       而那一个月要到 10 月 1 日才计入。规则已存在、已有理由,本刀不新造一条。
--
-- ★【Tim Chen 的 residency_status 本刀【不写】,这是一次按名的停止】★
--   Tim 给的是 EP(Employment Pass)。本列的词汇表是 citizen / pr / work_pass,
--   而 EP 在这套模型里【是一种 work pass】(residency_status='work_pass' +
--   work_pass_type='EP')。词汇不缺。**缺的是 employees_work_pass_shape 要的
--   work_pass_expiry_date** —— 一个我没有的日期。给一张准证编一个到期日,
--   会让 hr_alerts 的 work_pass_expiry 那一支照着一个假日期去提醒或不提醒。
--   所以这一格留空,并在报告里点名要 Tim 补。**宁可空着,不可编。**
--
-- ★【破窗】本刀 code first / migrate last:界面(/hr/kpi/score、假期表单)
--   已经写完并与本支同一次提交。窗口 = 本支 COMMIT → 部署 success。
--
-- NOTE: mirrors updated in the same commit —— db/tables/public_holidays.sql,
--       db/tables/kpi_entries.sql, db/tables/kpi_cycles.sql,
--       db/tables/kpi_score_rubric.sql(新), db/functions/score_kpi_entry.sql。

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- ① 六个人 —— 占位值变成事实
-- ════════════════════════════════════════════════════════════════════════════

-- 【入职日】Tim 的裁定:四个占位行写 2026-09-01。
--   ★ Choo Er(2026-08-01)与 Tim(2026-08-11)【不动】★ —— 勘察发现它们不是
--   占位值,而改动它们会让两人各少掉一个月的累积(24/12 = 2 天)。
UPDATE public.employees
   SET hire_date = DATE '2026-09-01'
 WHERE code IN ('EMP-2026-0003', 'EMP-2026-0004', 'EMP-2026-0005', 'EMP-2026-0006');

-- 【居留身份】Tim 供数。Fu Sheng = pr;三位 citizen。
--   Choo Er 已是 work_pass,不动;Tim Chen 见抬头,本刀不写。
UPDATE public.employees SET residency_status = 'citizen'
 WHERE code IN ('EMP-2026-0003', 'EMP-2026-0004', 'EMP-2026-0005');
UPDATE public.employees SET residency_status = 'pr'
 WHERE code = 'EMP-2026-0006';

-- 【职位】KPI 绑在职位上,不绑在人上(规格 §8.1)。positions.source_incumbent_name
--   本来就逐个点着这六个人的名字,所以这个映射不是猜的。
--   ★ Cheng Siong Phua → CTO:他的【系统角色】是 operations,【职位】是 CTO。
--     两者是两件事 —— 职位决定他被考核哪五条,角色决定他看得见什么。
--     Tim 已裁定:两者不必一致,也都不算错。
UPDATE public.employees e SET position_id = p.id
  FROM public.positions p
 WHERE p.code = 'MD'      AND e.code = 'EMP-2026-0003';
UPDATE public.employees e SET position_id = p.id
  FROM public.positions p
 WHERE p.code = 'CCO'     AND e.code = 'EMP-2026-0004';
UPDATE public.employees e SET position_id = p.id
  FROM public.positions p
 WHERE p.code = 'CTO'     AND e.code = 'EMP-2026-0005';
UPDATE public.employees e SET position_id = p.id
  FROM public.positions p
 WHERE p.code = 'LEAD-WH' AND e.code = 'EMP-2026-0006';

-- 【清掉占位备注】★ 一句写着"占位值"的备注留在一个真值旁边,比没有备注更坏 ★
--   —— 下一个读到它的人会不相信那个已经是事实的值。
UPDATE public.employees
   SET notes = 'C-2 2026-09-05:入职日、居留身份与职位已由 Tim 确认为事实。'
             || 'work_category 与 employment_type 一并确认(Fu Sheng = shopfloor,其余 office;六人皆 full_time,均不在试用期)。'
 WHERE code IN ('EMP-2026-0003', 'EMP-2026-0004', 'EMP-2026-0005', 'EMP-2026-0006');

DO $$
DECLARE v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM employees
     WHERE code IN ('EMP-2026-0003','EMP-2026-0004','EMP-2026-0005','EMP-2026-0006')
       AND (hire_date <> DATE '2026-09-01' OR position_id IS NULL
            OR residency_status IS NULL OR notes LIKE '%占位%');
    IF v_n > 0 THEN
        RAISE EXCEPTION 'C-2 ①:% 行没有变成事实(入职日/职位/居留身份/备注)', v_n;
    END IF;
    -- ★ 反向断言:没被点名的两行【不许】被动到 ★
    PERFORM 1 FROM employees WHERE code = 'EMP-2026-0001' AND hire_date = DATE '2026-08-01';
    IF NOT FOUND THEN RAISE EXCEPTION 'C-2 ①:Choo Er 的入职日被动了 —— 它不是占位值'; END IF;
    PERFORM 1 FROM employees WHERE code = 'EMP-2026-0002' AND hire_date = DATE '2026-08-11';
    IF NOT FOUND THEN RAISE EXCEPTION 'C-2 ①:Tim 的入职日被动了 —— 它不是占位值'; END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- ② 公共假期 —— 一张表,两个读者
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★【为什么要一个 holiday_key,而 name_en 不够用】★★
--   UI-1(排在发号之后)要在节日换一版 logo,它问的问题是
--   「今天是不是农历新年」。而农历新年【每年的日期都不一样】,
--   所以它不能问日期;它也不能问名字 —— `Vesak Day` 与 `Vesak Day (in lieu)`
--   已经不是同一串字,而 2027 年 Tim 手打的那一行可能写成 `Chinese New Year `
--   (多一个空格)或 `CNY`。**字符串比较会安静地答错。**
--   所以身份是一个显式的键,而不是一个碰巧稳定的显示名。
--
-- ★【它【不】为 UI-1 建任何东西】★ 本刀只建表与工作日这一侧的用法。
--   UI-1 将来读的是:SELECT holiday_key FROM public_holidays
--                    WHERE holiday_date = CURRENT_DATE AND is_active。
--   那一句写在 docs 里,代码里一行都不留 —— 为一个还没开工的刀留坑,
--   会得到一个没有人验证过的接口。
--
-- ★【is_in_lieu 与 holiday_key 是两件事】★ 补假与被补的那天【共用同一个键】
--   (它们是同一个节日),所以只看键分不出哪一行是补的。逢周日顺延周一这条规矩
--   在本仓库里一直是【数据】而不是逻辑(2026 年的三行补假就是这么存的),
--   本刀不改这个决定 —— 官方公布哪天补,就存哪天,不去推算。
ALTER TABLE public.public_holidays
    ADD COLUMN holiday_key text,
    ADD COLUMN is_in_lieu  boolean NOT NULL DEFAULT false;

-- 回填 2026 的十四行(它们是本刀之前唯一的数据)
UPDATE public.public_holidays SET holiday_key = CASE
    WHEN name_en LIKE 'New Year%'        THEN 'new-year'
    WHEN name_en LIKE 'Chinese New Year%' THEN 'chinese-new-year'
    WHEN name_en LIKE 'Hari Raya Puasa%' THEN 'hari-raya-puasa'
    WHEN name_en LIKE 'Good Friday%'     THEN 'good-friday'
    WHEN name_en LIKE 'Labour Day%'      THEN 'labour-day'
    WHEN name_en LIKE 'Hari Raya Haji%'  THEN 'hari-raya-haji'
    WHEN name_en LIKE 'Vesak Day%'       THEN 'vesak-day'
    WHEN name_en LIKE 'National Day%'    THEN 'national-day'
    WHEN name_en LIKE 'Deepavali%'       THEN 'deepavali'
    WHEN name_en LIKE 'Christmas%'       THEN 'christmas'
END,
is_in_lieu = (name_en LIKE '%(in lieu)%')
WHERE holiday_key IS NULL;

-- ★ 回填不许留下 NULL —— 一个匹配不上的名字要当场炸,而不是变成一个空键。
DO $$
DECLARE v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM public_holidays WHERE holiday_key IS NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'C-2 ②:% 行的 holiday_key 没能从 name_en 认出来 —— 请逐行补,不要放它过去', v_n;
    END IF;
END $$;

ALTER TABLE public.public_holidays
    ALTER COLUMN holiday_key SET NOT NULL,
    ADD CONSTRAINT public_holidays_key_shape
        CHECK (holiday_key ~ '^[a-z][a-z0-9-]*$');

COMMENT ON COLUMN public.public_holidays.holiday_key IS
    'C-2:【跨年份稳定的身份】。日期年年在动(农历、回历),而"今天是不是农历新年"这个问题每年要得到同一个答案 —— 所以问的是这个键,不是日期,也不是显示名(`Vesak Day` 与 `Vesak Day (in lieu)` 已经不是同一串字,而手打的名字还会多一个空格)。**UI-1 的节日 logo 读它;工作日计算继续读 holiday_date。一张表两个读者 —— 两份假期清单是两套系统开始对"今天是哪天"各执一词的方式。**';
COMMENT ON COLUMN public.public_holidays.is_in_lieu IS
    'C-2:这一行是不是【补假】(逢周日顺延的那个周一)。补假与被补的那天**共用同一个 holiday_key** —— 它们是同一个节日,所以只看键分不出来。逢周日补周一这条规矩在本仓库里一直是【数据】不是逻辑:官方公布哪天补就存哪天,不去推算。';

-- 【2027 年新加坡公共假期】—— MOM 新闻稿《Public Holidays for 2027》,
-- 2026-06-18 发布;本刀于 2026-09-05 取用。
-- 11 个法定假日 + 1 个"逢周日顺延周一"的补假 = 12 个日期。
-- ⚠ 农历与回历日期【不去计算】——那要靠官方公布,与 2026 那一批同一条规矩。
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

DO $$
DECLARE v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM public_holidays
     WHERE EXTRACT(year FROM holiday_date) = 2027 AND is_active;
    IF v_n <> 12 THEN
        RAISE EXCEPTION 'C-2 ②:2027 年应当有 12 个假日,实得 %', v_n;
    END IF;
    -- ★ 工作日计算必须【看得见】新载入的那一年 —— 断言一条,不是相信它
    IF is_business_day(DATE '2027-02-08') THEN
        RAISE EXCEPTION 'C-2 ②:2027-02-08 是补假,却仍被算成工作日';
    END IF;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- ③ KPI 月度录入
-- ════════════════════════════════════════════════════════════════════════════

-- ③-a 【第三样东西:反馈】Tim 的裁定:她录三样 —— 分数、证据、反馈。
--     evidence_note 回答"凭什么是这个分",feedback_note 回答"要跟他说什么"。
--     把两者挤进一个字段,等于让复盘时分不出证据与建议。
ALTER TABLE public.kpi_entries ADD COLUMN feedback_note text;
COMMENT ON COLUMN public.kpi_entries.feedback_note IS
    'C-2:给这个人的【反馈】—— 与 evidence_note 分开的一格。evidence_note 回答「凭什么是这个分」(事实),feedback_note 回答「要跟他说什么」(判断与建议)。**挤进同一个字段的话,复盘时没有人分得出哪一句是证据、哪一句是意见** —— 与 score_kind 把 computed 和 judged 分开是同一条理由。';

-- ③-b ★★【锁 ≠ 关:一个 flag 干两件事,就一定有一件干不对】★★
--     线上今天只有 kpi_cycles.status='closed',而它【同时】做两件事:
--       · score_kpi_entry 拒绝写入(冻结);
--       · my_kpi_entries 把分数放出来给本人看(揭晓)。
--     Tim 的裁定是「一个月在它的关口锁上之前一直可改」+「M3 锁住 1–3 月」。
--     用一个 flag 表达不了:为了冻结而 close,会把分数提前揭晓给每个人;
--     不 close,则第 1、2 个月永远冻不住。
--     所以【拆成两个概念】:locked_at 冻结,status='closed' 揭晓。
ALTER TABLE public.kpi_cycles
    ADD COLUMN locked_at timestamptz,
    ADD COLUMN locked_by uuid,
    ADD CONSTRAINT kpi_cycles_lock_shape
        CHECK (locked_at IS NULL OR locked_by IS NOT NULL);
COMMENT ON COLUMN public.kpi_cycles.locked_at IS
    'C-2:这个月被关口【锁住】的时刻 —— 锁住之后分数不能再改。★**锁与关是两件事**★:`locked_at` 冻结打分,`status=''closed''` 才把分数对本人揭晓(my_kpi_entries)。原本只有 status 一个 flag,而它同时做这两件事 —— 于是「为了冻结而 close」会把分数提前揭晓给所有人,「不 close」则前两个月永远冻不住。Tim 的裁定(2026-09-05):**M3 关口锁住第 1–3 个月,不是只锁第 3 个月** —— 一道过后还能靠改第 1 个月推翻的关口,不是关口。';

-- ③-c 【打分刻度与封顶规则 —— 是数据,不是文案】
--     与公共假期同一条论证:打分的规则必须能【不发版】就改正。
--     写死在 messages/*.ts 里的话,改一个档位的措辞要走一次部署。
CREATE TABLE public.kpi_score_rubric (
    score                integer PRIMARY KEY CHECK (score BETWEEN 0 AND 5),
    band_en              text NOT NULL CHECK (btrim(band_en) <> ''),
    band_zh              text NOT NULL CHECK (btrim(band_zh) <> ''),
    -- 原表第六页那四栏,逐格原文
    evidence_standard_en text NOT NULL,
    management_action_en text NOT NULL,
    -- ★ 这一栏是那条封顶规则本身 —— 它对【每一档】都成立,所以它在每一行上
    veto_rule_en         text NOT NULL,
    review_cadence_en    text NOT NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_kpi_score_rubric_updated_at
    BEFORE UPDATE ON public.kpi_score_rubric
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.kpi_score_rubric ENABLE ROW LEVEL SECURITY;
-- 【任何登录用户可读】被打分的人有权知道这把尺长什么样 —— 与 public_holidays
-- 同一条判据:一条所有人都被它约束的规则,不该只有打分的人看得见。
CREATE POLICY "kpi_score_rubric select all"
    ON public.kpi_score_rubric AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "kpi_score_rubric insert by permission"
    ON public.kpi_score_rubric AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "kpi_score_rubric update by permission"
    ON public.kpi_score_rubric AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "kpi_score_rubric delete by permission"
    ON public.kpi_score_rubric AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

COMMENT ON TABLE public.kpi_score_rubric IS
    'C-2:0–5 打分刻度与安全/监管否决 —— 原表第六页逐格转录。★**它是【数据】不是文案**★:与公共假期同一条论证,打分的规则必须能不发版就改正(module.hr.edit 可改)。★**否决那一栏落在每一行上,因为它对每一档都成立**★ —— 原表把「Does not override a major safety/regulatory breach」写在 5 分那一行、把「Any unauthorized operation = 0」写在 1 分那一行,而它们说的是同一条规矩的不同侧面。屏幕上把它贴在每一档旁边,是为了让打分的人在【按下 4 分的那一刻】看见它,而不是记得它。';
COMMENT ON COLUMN public.kpi_score_rubric.veto_rule_en IS
    'C-2:原表第六页 `Critical safety/regulatory override` 那一栏的原文。★**封顶是一个【动作】,不是一个分数**★ —— kpi_entries.override_cap 与 override_reason 才是它的落点,而原始分留在行上,所以事后分得清「本来就 2 分」与「被封到 2 分」。';

INSERT INTO public.kpi_score_rubric
    (score, band_en, band_zh, evidence_standard_en, management_action_en, veto_rule_en, review_cadence_en) VALUES
(5, 'Outstanding / materially ahead', '优异 / 显著超前',
    '≥100% of target plus positive stretch outcome',
    'Recognise; capture best practice',
    'Does not override a major safety/regulatory breach',
    'Monthly / formal at M3 & M6'),
(4, 'Fully achieved', '完全达成',
    '95–99% of target or target achieved with minor timing variance',
    'Maintain; close minor gaps',
    'Major breach can cap score at 0–2 depending on severity',
    'Monthly / formal at M3 & M6'),
(3, 'Mostly achieved', '基本达成',
    '90–94% of target',
    'Corrective action required',
    'Critical control gap should reduce score',
    'Monthly / formal at M3 & M6'),
(2, 'Partially achieved', '部分达成',
    '80–89% of target',
    'Management recovery plan',
    'Critical control gap may cap at 2',
    'Monthly / formal at M3 & M6'),
(1, 'Materially behind', '显著落后',
    '70–79% of target',
    'Escalate with named recovery owner/date',
    'Any unauthorized operation = 0',
    'Weekly until recovered'),
(0, 'Failed / unacceptable', '未达成 / 不可接受',
    '<70% of target or major compliance/safety failure',
    'Immediate escalation and recovery plan',
    'Unauthorized battery processing/receipt where prohibited = 0',
    'Immediate');

-- ③-d ★【收紧那扇门】★ score_kpi_entry 长出 feedback_note,并认 locked_at。
--     ★ DROP + CREATE,不是 CREATE OR REPLACE ★:参数表变了就是另一个签名,
--       CREATE OR REPLACE 会留下【两个】同名函数(FIN-21 那次漂移),
--       而 preflight_migration.py 正是为了拒绝这件事才存在。
--       它认得本文件里出现在 CREATE 之前的 DROP,所以这是它放行的那条路。
DROP FUNCTION public.score_kpi_entry(uuid, integer, text, text, text, integer, text);

CREATE OR REPLACE FUNCTION public.score_kpi_entry(
    p_entry_id uuid,
    p_score integer,
    p_score_kind text DEFAULT 'judged'::text,
    p_evidence_note text DEFAULT NULL::text,
    p_feedback_note text DEFAULT NULL::text,
    p_computed_basis text DEFAULT NULL::text,
    p_override_cap integer DEFAULT NULL::integer,
    p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_e     kpi_entries%ROWTYPE;
    v_cycle kpi_cycles%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_e FROM kpi_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KPI_ENTRY_NOT_FOUND|%', p_entry_id; END IF;
    SELECT * INTO v_cycle FROM kpi_cycles WHERE id = v_e.cycle_id;

    -- ★★【锁在前,关在后 —— 两道分开的门,两句分开的话】★★
    --   锁是关口按下的冻结(M3 锁 1–3 月);关是"这个月结束了,分数对本人揭晓"。
    --   一个被锁住的月份说"被关口锁了",而不是"已经关了" —— 后者会让人以为
    --   去重开周期就能改,而那不是这里发生的事。
    IF v_cycle.locked_at IS NOT NULL THEN
        RAISE EXCEPTION 'KPI_CYCLE_LOCKED|%|%', v_cycle.name, COALESCE(v_cycle.gate, '')
          USING HINT = '这个月已被关口锁住 —— 一道过后还能靠改那个月推翻的关口,不是关口。要改先解锁,那一步会留痕';
    END IF;
    IF v_cycle.status = 'closed' THEN
        RAISE EXCEPTION 'KPI_CYCLE_CLOSED|%', v_cycle.name
          USING HINT = '这个周期已经关了 —— 改一个关掉的周期里的分数是在改历史,要改先重开周期,那一步会留痕';
    END IF;

    IF p_score IS NULL OR p_score < 0 OR p_score > 5 THEN
        RAISE EXCEPTION 'KPI_SCORE_OUT_OF_RANGE|%', COALESCE(p_score::text, 'null')
          USING HINT = '打分是 0–5 的整数(原表第六页逐档定义了 5/4/3/2/1/0,没有小数档)';
    END IF;
    IF p_score_kind IS NULL OR p_score_kind NOT IN ('judged','computed') THEN
        RAISE EXCEPTION 'KPI_SCORE_KIND_INVALID|%', COALESCE(p_score_kind, 'null')
          USING HINT = '一个分数要说出它是【算出来的】还是【人判的】—— 两者可靠性差着一个数量级,而屏幕上必须长得不一样(规格 §10.2)';
    END IF;
    IF p_score_kind = 'computed'
       AND NULLIF(btrim(COALESCE(p_computed_basis, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_COMPUTED_NEEDS_BASIS|%', v_e.kpi_ref
          USING HINT = '标成【算出来的】就要写清它算的是什么(哪几次盘点、哪张账龄、截至哪一天)—— 否则 computed 只是一个更好看的标签';
    END IF;
    IF p_override_cap IS NOT NULL
       AND NULLIF(btrim(COALESCE(p_override_reason, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_OVERRIDE_NEEDS_REASON|%', v_e.kpi_ref
          USING HINT = '安全/监管否决要写明是哪一件事(原表:major breach 可封到 0–2、unauthorized operation = 0)—— 没有理由的封顶,事后与一次低分长得一模一样';
    END IF;
    IF p_override_cap IS NOT NULL AND (p_override_cap < 0 OR p_override_cap > 5) THEN
        RAISE EXCEPTION 'KPI_SCORE_OUT_OF_RANGE|%', p_override_cap; END IF;

    UPDATE kpi_entries
       SET score = p_score,
           score_kind = p_score_kind,
           computed_basis = NULLIF(btrim(COALESCE(p_computed_basis, '')), ''),
           evidence_note = NULLIF(btrim(COALESCE(p_evidence_note, '')), ''),
           feedback_note = NULLIF(btrim(COALESCE(p_feedback_note, '')), ''),
           override_cap = p_override_cap,
           override_reason = NULLIF(btrim(COALESCE(p_override_reason, '')), ''),
           scored_by = auth.uid(), scored_at = now(),
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_entry_id;

    RETURN jsonb_build_object(
        'entry_id', p_entry_id,
        'kpi_ref', v_e.kpi_ref,
        'score', p_score,
        'score_kind', p_score_kind,
        'effective_score', LEAST(p_score, COALESCE(p_override_cap, 5)),
        'capped', (p_override_cap IS NOT NULL AND p_override_cap < p_score),
        'weighted', round(LEAST(p_score, COALESCE(p_override_cap, 5))::numeric / 5 * v_e.weight_pct, 2));
END;
$function$;

COMMENT ON FUNCTION public.score_kpi_entry(uuid, integer, text, text, text, text, integer, text) IS
'KPI-1 / C-2:给一条 KPI 打 0–5 分,并收下【证据】与【反馈】两段话。**分数必须说出自己是 judged 还是 computed**(规格 §10.2 是设计要求不是可选项),而**标成 computed 就必须写出它算的是什么** —— 否则 computed 只是一个更好看的标签。**安全/监管否决是【封顶】不是【分数】**(原表第六页):score 与 override_cap 都留着,于是事后分得清「他本来就只有 2 分」与「他被封到 2 分」。生效分 = LEAST(score, cap),由视图算,不另存。★**C-2 加的那道门:locked_at**★ —— 锁与关是两件事,锁冻结打分、关才对本人揭晓分数;被锁住的月份抛 KPI_CYCLE_LOCKED 而不是 KPI_CYCLE_CLOSED,因为「重开周期」不是解决它的办法。';

-- ③-e 【六个周期 —— 数据,不是一块建周期的界面】
--     九月是第一个月(六个人的入职日都是 2026-09-01),所以
--     M3 = 2026-11,M6 = 2027-02 —— 与原表自己的 `Sep26toFeb27` 对得上。
--     due_date 是【告知性的】:Tim 裁定频率归 Sandra,代码不强制任何节奏。
INSERT INTO public.kpi_cycles (name, period_start, period_end, due_date, status, gate, notes) VALUES
('2026-09', '2026-09-01', '2026-09-30', '2026-10-31', 'open', NULL,
 'C-2:考核第 1 个月。六个人的入职日都是 2026-09-01,所以九月是第一个月。'),
('2026-10', '2026-10-01', '2026-10-31', '2026-11-30', 'open', NULL, 'C-2:考核第 2 个月。'),
('2026-11', '2026-11-01', '2026-11-30', '2026-12-31', 'open', 'M3',
 'C-2:考核第 3 个月,★M3 关口★。锁上它时,第 1–3 个月一起锁(Tim 2026-09-05)。'),
('2026-12', '2026-12-01', '2026-12-31', '2027-01-31', 'open', NULL, 'C-2:考核第 4 个月。'),
('2027-01', '2027-01-01', '2027-01-31', '2027-02-28', 'open', NULL, 'C-2:考核第 5 个月。'),
('2027-02', '2027-02-01', '2027-02-28', '2027-03-31', 'open', 'M6',
 'C-2:考核第 6 个月,★M6 关口★。锁上它时,第 4–6 个月一起锁(Tim 2026-09-05)。');

-- ③-f 【九月那一批条目】—— 六个人各五条,从各自职位的模板【复制】。
--     ★ 走 assign_position_kpis,不在这里手写 INSERT ★:复制的语义(抄哪些字段、
--       权重合计必须 100、模板为空要拒绝、已生成要按名拒)全长在那支函数里。
--       在迁移里另写一份 INSERT,就是第二份实现,而两份一定会漂开。
--     ★ 它要 module.hr.edit,而 psql 里 auth.uid() 是空的 ★ —— 所以这里
--       按 fixture 146 的同一条路,把会话身份设成【Tim 自己的账号】:
--       他是 admin(持 module.hr.edit),而且这支迁移确实是他在跑。
--       set_config(..., true) 是事务局部的,提交后不残留。
DO $$
DECLARE
    v_uid   uuid;
    v_cycle uuid;
    v_emp   record;
    v_n     integer;
BEGIN
    SELECT user_id INTO v_uid FROM employees
     WHERE code = 'EMP-2026-0002' AND user_id IS NOT NULL AND deleted_at IS NULL;
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'C-2 ③-f:找不到 Tim 的账号 —— 生成条目要一个持 module.hr.edit 的身份,不能匿名跑';
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    SELECT id INTO v_cycle FROM kpi_cycles WHERE name = '2026-09';
    IF v_cycle IS NULL THEN RAISE EXCEPTION 'C-2 ③-f:2026-09 这个周期没建出来'; END IF;

    FOR v_emp IN
        SELECT id, code FROM employees
         WHERE code LIKE 'EMP-2026-%' AND deleted_at IS NULL AND position_id IS NOT NULL
         ORDER BY code
    LOOP
        PERFORM assign_position_kpis(v_emp.id, v_cycle);
    END LOOP;

    -- ★ 六个人 × 五条 = 三十条。少一条都要当场炸,而不是留一张缺角的表。
    SELECT count(*) INTO v_n FROM kpi_entries WHERE cycle_id = v_cycle;
    IF v_n <> 30 THEN
        RAISE EXCEPTION 'C-2 ③-f:九月应当生成 30 条(6 人 × 5),实得 %', v_n;
    END IF;
    SELECT count(DISTINCT employee_id) INTO v_n FROM kpi_entries WHERE cycle_id = v_cycle;
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'C-2 ③-f:九月应当覆盖 6 个人,实得 %', v_n;
    END IF;
END $$;

-- ── 收尾断言:本刀新增的那几样,逐条点名 ────────────────────────────────────
DO $$
DECLARE v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM kpi_score_rubric;
    IF v_n <> 6 THEN RAISE EXCEPTION 'C-2:打分刻度应当有 6 档(0–5),实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM kpi_cycles WHERE deleted_at IS NULL;
    IF v_n <> 6 THEN RAISE EXCEPTION 'C-2:应当有 6 个周期,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM kpi_cycles WHERE gate IS NOT NULL;
    IF v_n <> 2 THEN RAISE EXCEPTION 'C-2:应当正好两道关口(M3/M6),实得 %', v_n; END IF;
    -- 新函数确实收得下 feedback,而且【只有一个签名】(没退化成重载)
    SELECT count(*) INTO v_n FROM pg_proc WHERE proname = 'score_kpi_entry';
    IF v_n <> 1 THEN RAISE EXCEPTION 'C-2:score_kpi_entry 有 % 个签名 —— DROP 没生效就是一次重载', v_n; END IF;
END $$;

COMMIT;

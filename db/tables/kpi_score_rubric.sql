-- db/tables/kpi_score_rubric.sql
-- C-2:0–5 打分刻度与安全/监管否决 —— 原表第六页逐格转录。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- ★ 与 public_holidays 同一条论证:**打分的规则必须能【不发版】就改正。**
--   写死在 messages/*.ts 里的话,改一个档位的措辞要走一次部署 —— 而这是一条
--   六个人都被它约束的规则。module.hr.edit 可改;线上与本文件不一致是正常的。
--   check_mirrors.py 因此不把本表与线上逐行比对(见 RUNTIME_CONFIG_TABLES)。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ★★【否决那一栏落在【每一行】上,因为它对每一档都成立】★★
--   原表把「Does not override a major safety/regulatory breach」写在 5 分那一行、
--   把「Any unauthorized operation = 0」写在 1 分那一行 —— 它们说的是同一条规矩
--   的不同侧面。屏幕上把它贴在每一档旁边,是为了让打分的人在【按下 4 分的
--   那一刻】看见它,而不是记得它。
--
-- ★【封顶是一个【动作】,不是一个分数】★ 本表只是那条规矩的【文本】;
--   它的落点是 kpi_entries.override_cap + override_reason,而原始分留在行上,
--   所以事后分得清「本来就 2 分」与「被封到 2 分」。
--
-- 【读:任何登录用户】被打分的人有权知道这把尺长什么样 —— 与 public_holidays
-- 同一条判据:一条所有人都被它约束的规则,不该只有打分的人看得见。
--
-- NOTE: introduced by db/migrations/2026-09-05-c2-hire-dates-holiday-identity-and-kpi-entry.sql.
-- First-run script (plain CREATEs).

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

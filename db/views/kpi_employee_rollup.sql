-- db/views/kpi_employee_rollup.sql
-- KPI-1:Associate Roll-up —— 原表第四页。**派生,不另存**(规格 §9.1)。
--
-- 原表那两列本来就是公式:
--   `Weighted score achieved` = `=SUM('Asspcoate KPIs'!J5:J9)`
--   `Performance %`           = `=IF(C5=0,"",D5/C5)`
-- 而每条 KPI 的加权分在原表里是 `=IF(I5="","",I5/5*C5)` —— 也就是 分/5 × 权重。
-- 本视图逐字照这个算,不另发明。
--
-- ★【生效分 = LEAST(分, 封顶)】★ 安全/监管否决是一个【封顶】动作(原表第六页):
--   「Major breach can cap score at 0–2」、「Any unauthorized operation = 0」。
--   **原始分与封顶都留在行上**,这里算的是生效分 —— 于是事后仍然分得清
--   「他本来就只有 2 分」与「他被封到 2 分」。
--
-- ★【没打分的不算 0】★ 原表的公式是 `=IF(I5="","",…)` —— 空就是空,不是零。
--   本视图跟着它:`scored_count` 与 `kpi_count` 分开报,
--   于是"五条打了两条"与"五条都打了但分低"在屏幕上分得开。
--   **把没打分的当成 0,是把"还没评"读成"评了个不及格"** ——
--   与 lib/permissions.ts 存在的理由(null ≠ 0)是同一条。

CREATE VIEW public.kpi_employee_rollup WITH (security_invoker = off) AS
 SELECT k.cycle_id,
    cy.name AS cycle_name,
    cy.gate,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name,
    p.code AS position_code,
    p.title AS position_title,
    count(*) AS kpi_count,
    count(*) FILTER (WHERE k.score IS NOT NULL) AS scored_count,
    count(*) FILTER (WHERE k.score_kind = 'computed') AS computed_count,
    count(*) FILTER (WHERE k.score_kind = 'judged') AS judged_count,
    count(*) FILTER (WHERE k.override_cap IS NOT NULL) AS capped_count,
    count(*) FILTER (WHERE k.is_provisional) AS provisional_count,
    sum(k.weight_pct) AS weight_total,
    -- 加权分 = Σ(生效分 / 5 × 权重),只算【打过分的】那些行
    round(COALESCE(sum(
        LEAST(k.score, COALESCE(k.override_cap, 5))::numeric / 5 * k.weight_pct
    ) FILTER (WHERE k.score IS NOT NULL), 0), 2) AS weighted_score_achieved,
    -- Performance % —— 原表 =IF(C5=0,"",D5/C5)。分母是【打过分的那些行的权重和】,
    -- 不是 100:五条打了两条时,拿 100 做分母会把"还没评"读成"没做到"。
    CASE WHEN COALESCE(sum(k.weight_pct) FILTER (WHERE k.score IS NOT NULL), 0) = 0
         THEN NULL
         ELSE round(
             COALESCE(sum(LEAST(k.score, COALESCE(k.override_cap, 5))::numeric / 5 * k.weight_pct)
                      FILTER (WHERE k.score IS NOT NULL), 0)
             / sum(k.weight_pct) FILTER (WHERE k.score IS NOT NULL) * 100, 1)
    END AS performance_pct
   FROM kpi_entries k
     JOIN employees e ON e.id = k.employee_id
     JOIN positions p ON p.id = k.source_position_id
     JOIN kpi_cycles cy ON cy.id = k.cycle_id
  WHERE has_permission('module.hr.view'::text)
    AND has_permission('data.view_reviews'::text)
  GROUP BY k.cycle_id, cy.name, cy.gate, e.id, e.code, e.legal_name, p.code, p.title;

COMMENT ON VIEW public.kpi_employee_rollup IS
'KPI-1:Associate Roll-up(原表第四页),**派生不另存**(§9.1)。逐字照原表的公式算:每条加权分 = 分/5 × 权重(`=IF(I5="","",I5/5*C5)`),合计 = SUM,Performance % = D5/C5。**生效分 = LEAST(分, 封顶)** —— 安全/监管否决是一个封顶动作(原表第六页),而原始分与封顶都留在行上,所以事后分得清「本来就 2 分」与「被封到 2 分」。★**没打分的不算 0**★:原表公式就是 `=IF(I5="","",…)`,空是空不是零;`scored_count` 与 `kpi_count` 分开报,performance% 的分母是【打过分那些行的权重和】而不是 100 —— 五条打了两条时拿 100 做分母,会把"还没评"读成"没做到",与 lib/permissions.ts 存在的理由(null ≠ 0)同一条。';

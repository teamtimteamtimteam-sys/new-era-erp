-- db/views/my_kpi_entries.sql
-- KPI-1:【本人】看自己这个周期被考核的那五条 —— /me 上那块自助面板读的就是它。
--
-- ★★【它与 review_goals 那条自评可见性策略【刻意不同】,而差别要说清楚】★★
--   `review_goals` 有一条 SELECT 策略:本人只在评估 `approved`/`acknowledged`
--   之后才看得见自己的目标行。理由是**自评过程中的草稿不该被当事人看到**。
--   **KPI 条目不是那种东西**:它是「你这个周期被考核的是哪五条、标准是什么」——
--   那是【期初就该让人知道】的事,藏起来才是错的。
--   所以本人【始终】看得见自己的条目与目标。
--
--   ★ 而【分数】不同:一个还没定稿的分数被当事人提前看到,
--     与自评草稿被看到是同一件事。所以本视图在周期 `closed` 之前
--     **把分数一族整列压成 NULL**,并用 `score_visible` 说出"为什么现在没有分"——
--     **不是留白**:一个空着的分数与一个"还没打"的分数长得一样,
--     而人会把前者读成"我得了 0 分"。
--
-- 【属主权限】它 join kpi_entries + kpi_cycles + positions,而本人这条路
--   不该要求 data.view_reviews(那是 HR 看别人的门)。谓词写进视图体:
--   employee_id = current_user_employee()。

CREATE VIEW public.my_kpi_entries WITH (security_invoker = off) AS
 SELECT k.id,
    k.cycle_id,
    cy.name AS cycle_name,
    cy.status AS cycle_status,
    cy.gate,
    cy.period_start,
    cy.period_end,
    cy.due_date,
    p.code AS position_code,
    p.title AS position_title,
    k.kpi_ref,
    k.title,
    k.weight_pct,
    k.target_text,
    k.evidence_source,
    k.is_provisional,
    k.provisional_note,
    k.org_codes,
    k.source_template_version,
    -- ★ 分数只在周期关掉之后才对本人可见 —— 见抬头
    (cy.status = 'closed') AS score_visible,
    CASE WHEN cy.status = 'closed' THEN k.score END AS score,
    CASE WHEN cy.status = 'closed' THEN k.score_kind END AS score_kind,
    CASE WHEN cy.status = 'closed' THEN k.computed_basis END AS computed_basis,
    CASE WHEN cy.status = 'closed' THEN k.evidence_note END AS evidence_note,
    CASE WHEN cy.status = 'closed' THEN k.override_cap END AS override_cap,
    CASE WHEN cy.status = 'closed' THEN k.override_reason END AS override_reason
   FROM kpi_entries k
     JOIN kpi_cycles cy ON cy.id = k.cycle_id
     JOIN positions p ON p.id = k.source_position_id
  WHERE k.employee_id = current_user_employee();

COMMENT ON VIEW public.my_kpi_entries IS
    'KPI-1:本人看自己被考核的那五条(/me 的自助面板)。★**与 review_goals 那条自评可见性策略刻意不同**★:那一条把自评正文压到 approved/acknowledged 之后才可见,因为**自评草稿不该被当事人看到**;而 KPI 条目是「你这个周期被考核的是哪五条」—— 期初就该让人知道,藏起来才是错的,所以条目与目标【始终】可见。★**但分数不同**★:一个还没定稿的分数被提前看到,与自评草稿被看到是同一件事,所以周期 closed 之前分数一族整列压成 NULL,并由 `score_visible` 说出为什么现在没有分 —— **不是留白**,因为一个空着的分数与"打了 0 分"长得一样。';

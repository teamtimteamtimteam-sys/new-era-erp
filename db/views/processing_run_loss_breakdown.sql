-- db/views/processing_run_loss_breakdown.sql
-- PROC-BUILD-1:一张加工单的损耗,分成【已解释】与【还没解释】两块。
-- **unexplained_qty 不是过磅误差** —— 它是还没有人说这部分去了哪。两者今天分不开
-- (见 processing_run_losses 的表注),而把它命名成误差会让一个记账问题看起来
-- 像一件已经查清的物理事实。
-- 【loss_qty 为空时差额是 NULL 不是 0】—— 0 会把没人记过总量读成全部解释完了。
-- MES-4a(2026-10-07):损耗只追加之后,每一类只算它更正链的末端(没被更正过的那一行)—— 撤回(更正成 0)就不算。
-- NOTE: introduced by db/migrations/2026-08-30-procbuild1-loss-categories-forms-and-saleability.sql.

CREATE VIEW public.processing_run_loss_breakdown WITH (security_invoker = true) AS
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    r.loss_qty,
    COALESCE(l.categorised_qty, 0::numeric) AS categorised_qty,
        CASE
            WHEN r.loss_qty IS NULL THEN NULL::numeric
            ELSE r.loss_qty - COALESCE(l.categorised_qty, 0::numeric)
        END AS unexplained_qty
   FROM processing_runs r
     LEFT JOIN ( SELECT l_1.run_id,
            sum(l_1.quantity) AS categorised_qty
           FROM processing_run_losses l_1
          WHERE NOT (EXISTS ( SELECT 1
                   FROM processing_run_losses x
                  WHERE x.corrects_id = l_1.id))
          GROUP BY l_1.run_id) l ON l.run_id = r.id
  WHERE r.deleted_at IS NULL;

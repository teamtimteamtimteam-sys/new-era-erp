-- db/views/processing_metal_recovery_all.sql
-- AUD-1:processing_metal_recovery 的【无判据基视图】,理由与 batch_lineage_all
-- 逐字相同 —— 属主权限替不了体内那句 has_permission(它按调用者解析)。
-- 【不授权给任何人】;对外读 processing_metal_recovery。
--
-- 语义与拆分前逐字不变:判据是每次调用的常量,挪到外层不影响这里那个
-- 按 run 分区的窗口函数(run_recovery_computable)。
--
-- PROC-WIRE-1B-ii:recovery_blocked_by 多一个取值 output_not_applicable ——
-- 状态改变型工序按定义没有产出腿,说它"产出没测过"会教人去补一份根本不存在的化验。
-- 没有工序类型的单仍然报 output_not_measured(说不出"不适用"的时候不许猜它)。
--
-- NOTE: introduced by db/migrations/2026-08-17-aud1-traceability-report.sql
-- (body lifted verbatim from processing_metal_recovery: REC-1 / PROC-1 / FIN-25 /
--  OPS-14 的全部要点都在那一份的抬头,不在这里重抄一遍).

CREATE VIEW public.processing_metal_recovery_all AS
 WITH ins AS (
         SELECT pi.run_id,
            m.metal,
            sum(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg,
                CASE
                    WHEN min(COALESCE(m.content_source, 'unknown'::text)) = max(COALESCE(m.content_source, 'unknown'::text)) THEN min(COALESCE(m.content_source, 'unknown'::text))
                    ELSE 'mixed'::text
                END AS input_source
           FROM processing_inputs pi
             JOIN LATERAL ( SELECT ibm.metal,
                    ibm.content_pct,
                    ibm.content_source
                   FROM inbound_batch_metals ibm
                  WHERE ibm.inbound_batch_id = pi.inbound_batch_id
                UNION ALL
                 SELECT obm.metal,
                    obm.content_pct,
                    obm.content_source
                   FROM output_batch_metals obm
                  WHERE obm.output_batch_id = pi.output_batch_id) m ON true
          GROUP BY pi.run_id, m.metal
        ), outs AS (
         SELECT po.run_id,
            obm.metal,
            sum(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg,
                CASE
                    WHEN min(obm.content_source) = max(obm.content_source) THEN min(obm.content_source)
                    ELSE 'mixed'::text
                END AS output_source
           FROM processing_outputs po
             JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
          GROUP BY po.run_id, obm.metal
        )
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    COALESCE(i.metal, o.metal) AS metal,
    i.input_metal_kg,
    o.output_metal_kg,
    i.metal IS NOT NULL AS input_measured,
    o.metal IS NOT NULL AS output_measured,
        CASE
            WHEN i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric THEN round(o.output_metal_kg / i.input_metal_kg * 100::numeric, 2)
            ELSE NULL::numeric
        END AS recovery_pct,
        CASE
            WHEN i.metal IS NULL THEN 'input_not_measured'::text
            -- ★ PROC-WIRE-1B-ii:【不适用】与【没测】是两句话,两种下一步动作。
            --   状态改变型工序没有产出腿 —— 没有东西可测,不是"忘了测"。
            WHEN o.metal IS NULL AND k.produces_outputs IS FALSE THEN 'output_not_applicable'::text
            WHEN o.metal IS NULL THEN 'output_not_measured'::text
            WHEN i.input_metal_kg = 0::numeric THEN 'input_measured_zero'::text
            ELSE NULL::text
        END AS recovery_blocked_by,
    i.metal IS NOT NULL AND o.metal IS NOT NULL AND o.output_metal_kg > i.input_metal_kg AS conservation_warning,
    bool_or(i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric) OVER (PARTITION BY r.id) AS run_recovery_computable,
    i.input_source,
    o.output_source
   FROM ins i
     FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
     JOIN processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
     -- 【两条都 LEFT JOIN】没有工序类型的单(线上 13 张)必须原样走到
     -- output_not_measured —— 说不出"不适用"的时候不许猜它。
     LEFT JOIN operation_types ot ON ot.code = r.operation_type_code
     LEFT JOIN operation_kinds k ON k.code = ot.kind_code
  WHERE r.status = 'committed'::text AND r.deleted_at IS NULL;

COMMENT ON VIEW public.processing_metal_recovery_all IS
    'AUD-1:processing_metal_recovery 的【无判据基视图】,理由与 batch_lineage_all 逐字相同。【不授权给任何人】;对外读 processing_metal_recovery。PROC-WIRE-1B-ii:recovery_blocked_by 多一个取值 output_not_applicable —— 状态改变型工序按定义没有产出腿,说它"产出没测过"会教人去补一份根本不存在的化验。没有工序类型的单仍然报 output_not_measured(说不出"不适用"的时候不许猜它)。';

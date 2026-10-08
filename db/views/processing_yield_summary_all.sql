-- db/views/processing_yield_summary_all.sql
-- MES-5b-1(2026-10-08,MES-0 Q60;MES-5b Step 0 Q13 · Q14 · Q15,Tim):【得率按工序 × 月 × 分组的合计】—— 基视图,不给人读。
--   一行 = (分组 × 分组键 × 工序 × 月 × 一条线)。分母 = 这一组在这道工序、这个月里【全部】消耗那几炉的投入之和(不是只算产出了
--   这一形态的那几炉 —— 一炉没产出某种形态,那一形态在它身上就是 0)。分子 = 同一组那条线之和。
--   group_kind:
--     all        —— 不分组(每一炉份额 1)
--     machine    —— processing_runs.equipment_id(空 = 没记机器,group_key 为空)
--     chemistry  —— 源头批次物料的化学体系(经 processing_run_origin_share_all 按份额分);空 = "化学体系没记"(MES-0 Q60)
--     supplier   —— 源头进料批的供应商(同上);空 = 源头是一个手工建的产出批,没有供应商
--   产出形态就是 line_key(line_kind = output),所以"按形态"不是另一种分组。
--   V37:output 那几行的 expected_yield_pct 与 below_expected(只标,不拒);给了值才判断,没给为空。
--   runs / pre_mes4a_runs:这一组这一格里有几炉、其中几炉是 MES-4a 之前记的(页面据此标"含结平之前的单")。
--   回滚的、放电的、拆去隔离的、单位不是 kg 的单都不在这里(processing_run_yield_all 只收消耗那几炉)。
--   读者:processing_yield_summary(带门;供应商的名字跟进料批自己的查看码走,Q14 · Q32)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5b1-balance-and-yield.sql.

CREATE VIEW public.processing_yield_summary_all WITH (security_invoker = off) AS
 WITH runs AS (
         SELECT DISTINCT y.run_id,
            y.operation_type_code,
            y.month,
            y.equipment_id,
            y.era_mes4a,
            y.input_qty
           FROM processing_run_yield_all y
        ), origin AS (
         SELECT s.run_id,
            s.share,
            ib.supplier_id,
            m.chemistry
           FROM processing_run_origin_share_all s
             LEFT JOIN inbound_batches ib ON s.root_kind = 'inbound'::text AND ib.id = s.root_id
             LEFT JOIN output_batches ob ON s.root_kind = 'output'::text AND ob.id = s.root_id
             LEFT JOIN materials m ON m.id = COALESCE(ib.material_id, ob.material_id)
        ), grp AS (
         SELECT 'all'::text AS group_kind,
            NULL::text AS group_key,
            r.run_id,
            1::numeric AS share
           FROM runs r
        UNION ALL
         SELECT 'machine'::text,
            r.equipment_id::text,
            r.run_id,
            1::numeric
           FROM runs r
        UNION ALL
         SELECT 'chemistry'::text,
            o.chemistry,
            o.run_id,
            sum(o.share) AS sum
           FROM origin o
          GROUP BY o.chemistry, o.run_id
        UNION ALL
         SELECT 'supplier'::text,
            o.supplier_id::text,
            o.run_id,
            sum(o.share) AS sum
           FROM origin o
          GROUP BY o.supplier_id, o.run_id
        ), den AS (
         SELECT g.group_kind,
            g.group_key,
            r.operation_type_code,
            r.month,
            sum(g.share * r.input_qty) AS input_qty,
            count(DISTINCT r.run_id) AS runs,
            count(DISTINCT r.run_id) FILTER (WHERE NOT r.era_mes4a) AS pre_mes4a_runs
           FROM grp g
             JOIN runs r ON r.run_id = g.run_id
          GROUP BY g.group_kind, g.group_key, r.operation_type_code, r.month
        ), num AS (
         SELECT g.group_kind,
            g.group_key,
            y.operation_type_code,
            y.month,
            y.line_kind,
            y.line_key,
            y.recoverable,
            sum(g.share * y.qty) AS qty
           FROM grp g
             JOIN processing_run_yield_all y ON y.run_id = g.run_id
          GROUP BY g.group_kind, g.group_key, y.operation_type_code, y.month, y.line_kind, y.line_key, y.recoverable
        )
 SELECT n.group_kind,
    n.group_key,
    n.operation_type_code,
    n.month,
    n.line_kind,
    n.line_key,
    n.recoverable,
    n.qty,
    d.input_qty,
    d.runs,
    d.pre_mes4a_runs,
        CASE
            WHEN d.input_qty > 0::numeric THEN n.qty * 100::numeric / d.input_qty
            ELSE NULL::numeric
        END AS yield_pct,
    tf.expected_yield_pct,
        CASE
            WHEN n.line_kind = 'output'::text AND tf.expected_yield_pct IS NOT NULL AND d.input_qty > 0::numeric THEN (n.qty * 100::numeric / d.input_qty) < tf.expected_yield_pct
            ELSE NULL::boolean
        END AS below_expected
   FROM num n
     JOIN den d ON d.group_kind = n.group_kind AND NOT d.group_key IS DISTINCT FROM n.group_key AND NOT d.operation_type_code IS DISTINCT FROM n.operation_type_code AND d.month = n.month
     LEFT JOIN operation_type_output_forms tf ON n.line_kind = 'output'::text AND tf.operation_type_code = n.operation_type_code AND tf.form_code = n.line_key;

COMMENT ON VIEW public.processing_yield_summary_all IS
    'MES-5b-1:得率按 分组(all / machine / chemistry / supplier)× 工序 × 月 的合计;分母是这一格全部消耗那几炉的投入,化学体系与供应商按份额分到源头批次;产出那几行带 V37 与 below_expected。基视图,不给人读。';

REVOKE ALL ON public.processing_yield_summary_all FROM authenticated, anon;

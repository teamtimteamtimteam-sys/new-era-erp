-- db/views/output_batch_chemistry_certainty_all.sql
-- MES-6b-2(2026-10-15,N38;MES-6b Step 0 Q12,Tim):output_batch_chemistry_certainty 的【无判据基视图】—— 一批产出批的来料化学有多确定。
--   沿 batch_lineage_all 走到每一张【进料叶子】(parent_kind = 'inbound',任意深度),取叶子上 chemistry_certainty_code 里【最弱】的那一个:
--     unknown_pending(认不出,等鉴定)< 未记录(没人记过,NULL)< mixed(已知是混的)< single_known(单一、已知)。
--   一个字典里将来新加、这里不认得的码排在最弱之下(rank 0),并原样报出它的码 —— 一份不认得的确定度不该被读成"已知"。
--   没有任何进料叶子(手工建的产出批、或血缘走不到进料)→ 'not_recorded',inbound_leaves = 0:来料的化学没有任何一条记录。
--   为什么要基视图:属主视图里的 has_permission 按调用者解析 —— issue_coa / coa_assemble 以属主身份读它时,调用者(持 action.issue_coa
--   的人)不一定持 module.output.view(那个码声明的查看码是"任一");所以判据挪到外层 output_batch_chemistry_certainty,内层不授给任何人
--   (与 batch_lineage_all / batch_lineage 同一个先例)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.

CREATE VIEW public.output_batch_chemistry_certainty_all WITH (security_invoker = off) AS
 WITH leaves AS (
         SELECT DISTINCT l.output_batch_id,
            l.parent_batch_id AS inbound_batch_id
           FROM batch_lineage_all l
          WHERE l.parent_kind = 'inbound'::text
        ), ranked AS (
         SELECT lv.output_batch_id,
            ib.chemistry_certainty_code,
                CASE
                    WHEN ib.chemistry_certainty_code IS NULL THEN 2
                    WHEN ib.chemistry_certainty_code = 'unknown_pending'::text THEN 1
                    WHEN ib.chemistry_certainty_code = 'mixed'::text THEN 3
                    WHEN ib.chemistry_certainty_code = 'single_known'::text THEN 4
                    ELSE 0
                END AS rank
           FROM leaves lv
             JOIN inbound_batches ib ON ib.id = lv.inbound_batch_id
        ), agg AS (
         SELECT r.output_batch_id,
            count(*)::integer AS inbound_leaves,
            count(*) FILTER (WHERE r.chemistry_certainty_code = 'single_known'::text)::integer AS leaves_single_known,
            count(*) FILTER (WHERE r.chemistry_certainty_code = 'mixed'::text)::integer AS leaves_mixed,
            count(*) FILTER (WHERE r.chemistry_certainty_code IS NULL)::integer AS leaves_not_recorded,
            count(*) FILTER (WHERE r.chemistry_certainty_code = 'unknown_pending'::text)::integer AS leaves_unknown_pending,
            min(r.rank) AS weakest_rank,
            (array_agg(r.chemistry_certainty_code ORDER BY r.rank, r.chemistry_certainty_code))[1] AS weakest_code
           FROM ranked r
          GROUP BY r.output_batch_id
        )
 SELECT ob.id AS output_batch_id,
        CASE
            WHEN a.output_batch_id IS NULL THEN 'not_recorded'::text
            WHEN a.weakest_rank = 2 THEN 'not_recorded'::text
            ELSE a.weakest_code
        END AS certainty,
    COALESCE(a.inbound_leaves, 0) AS inbound_leaves,
    COALESCE(a.leaves_single_known, 0) AS leaves_single_known,
    COALESCE(a.leaves_mixed, 0) AS leaves_mixed,
    COALESCE(a.leaves_not_recorded, 0) AS leaves_not_recorded,
    COALESCE(a.leaves_unknown_pending, 0) AS leaves_unknown_pending
   FROM output_batches ob
     LEFT JOIN agg a ON a.output_batch_id = ob.id;

COMMENT ON VIEW public.output_batch_chemistry_certainty_all IS
    'MES-6b-2(N38):每一批产出批的来料化学确定度 —— 进料叶子(batch_lineage_all,任意深度)上 chemistry_certainty_code 最弱的那一个:unknown_pending < not_recorded(NULL)< mixed < single_known;不认得的码排在最弱之下并原样报出;没有进料叶子 → not_recorded、0 张叶子。【无判据基视图,不授给任何人】—— 对外读 output_batch_chemistry_certainty。';

REVOKE ALL ON public.output_batch_chemistry_certainty_all FROM authenticated, anon;

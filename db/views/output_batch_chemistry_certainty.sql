-- db/views/output_batch_chemistry_certainty.sql
-- MES-6b-2(2026-10-15,N38;MES-6b Step 0 Q12,Tim):【一批产出批的来料化学有多确定】—— 读的就是这一张。
--   判据与 output_batches 自己的读策略逐字同一个(module.output.view):看得见这一批的人看得见它的确定度,别人一行都没有。
--   【属主权限】基视图(output_batch_chemistry_certainty_all)与它读的 batch_lineage_all 都不授给任何人 —— 叶子可能在读者读不到的进料批上,
--   而确定度是一个关于【这一批产出】的派生事实(AGENTS.md 那张表的 (a):派生的事实走属主权限,谓词写回视图体)。
--   批次页与分析证书都读它;证书在签发那一刻把它冻进快照(coa_assemble 读基视图,理由见基视图的抬头)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.

CREATE VIEW public.output_batch_chemistry_certainty WITH (security_invoker = off) AS
 SELECT output_batch_id,
    certainty,
    inbound_leaves,
    leaves_single_known,
    leaves_mixed,
    leaves_not_recorded,
    leaves_unknown_pending
   FROM output_batch_chemistry_certainty_all
  WHERE has_permission('module.output.view'::text);

COMMENT ON VIEW public.output_batch_chemistry_certainty IS
    'MES-6b-2(N38):一批产出批的来料化学确定度(最弱的进料叶子:unknown_pending < not_recorded < mixed < single_known)与各档叶子数。属主权限,谓词 = output_batches 的读策略(module.output.view)。批次页显示它,分析证书签发时冻进快照。';

GRANT SELECT ON public.output_batch_chemistry_certainty TO authenticated;
REVOKE ALL ON public.output_batch_chemistry_certainty FROM anon;

-- db/views/discharge_status_by_batch.sql
-- MES-5a-1(2026-10-08,MES-5a Step 0 Q6 · Q13,Tim):【一批料的放电核实到哪儿了】—— discharge_batch_status_all 的带门读法。
--   【名字为什么不叫 discharge_batch_status】视图的重放顺序(check_mirrors.view_replay_order)按"引用了几张别的视图"排、同数按文件名 ——
--   它不是真的拓扑排序,一张引用了一张、而被引用的那张自己也引用了一张的视图会与它打平,文件名靠前就先建、当场报"不存在"。
--   取一个排在 discharge_batch_status_all 后面的名字,而不是在这一刀里改门的工具(记在 docs/known-issues.md)。
--   门:加工、进料或产出查看码任一。放电那一炉的页面、两种批次页与新建加工单表单读它("n 个模组里核实了几个")。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE VIEW public.discharge_status_by_batch WITH (security_invoker = off) AS
 SELECT s.batch_kind,
    s.batch_id,
    s.batch_code,
    s.material_id,
    s.module_count,
    s.modules_recorded,
    s.passed,
    s.failed_redischarge,
    s.failed_quarantine,
    s.split_out,
    s.contradictions,
    s.rule_verified,
    s.latest_run_id,
    s.latest_run_code,
    s.latest_run_date,
    s.result_state,
    s.currently_verified
   FROM discharge_batch_status_all s
  WHERE has_any_permission(ARRAY['module.processing.view'::text, 'module.inbound.view'::text, 'module.output.view'::text]);

COMMENT ON VIEW public.discharge_status_by_batch IS
    'MES-5a-1:一批料的放电核实进度(模组数、通过、待再放电、待拆去隔离、已拆走、与 V9 矛盾的条数、按规则是否已核实、此刻是否开着结果状态)。带门(加工、进料或产出查看码)的属主视图。';

GRANT SELECT ON public.discharge_status_by_batch TO authenticated;
REVOKE ALL ON public.discharge_status_by_batch FROM anon;

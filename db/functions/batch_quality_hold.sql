-- db/functions/batch_quality_hold.sql
-- MES-6b-1(2026-10-15,MES-0 Q66 · G29;MES-6b Step 0 Q2 · Q21,Tim):【这一批此刻是不是在质量暂扣里 —— 是的话,被哪一张不合格报告扣着】。
--   判"被暂扣"只有这一支(流水守卫 guard_quality_hold、销售结算、配料计划的建 / 改 / 放行、批次页、提醒都读它)—— 一条规矩一份实现。
--
--   一批被暂扣,当且仅当它有一张【扣着它】的不合格报告(判据在 ncr_holds 一处,纯函数):
--     · 还开着(status = 'open')—— 不论这一批还有没有货:一批已经发走的货上开着一张客户投诉,结算照样挡住(Q4);或者
--     · 决定为 reject,而这一批【还有货】(没删、remaining_qty > 0)—— reject 不放行,暂扣留到货没了为止;出路是既有的 CFO 注销申请(Q21)。
--   别的处置(accept · accept_with_penalty · rework · downgrade)都放行。几张同时扣着时,返回最早开的那一张(opened_at、编号)。
--   不在暂扣里 → 零行。
--
--   【为什么是 INVOKER】它被两种人调:属主(流水守卫是 DEFINER;结算落库、配料计划、判定都在 DEFINER 里)—— 读全部;
--   以及一个登录的人经销售结算的预览(sale_settlement_compute 是 INVOKER)—— 那里先问过 module.output.view,而不合格报告与产出批的读策略
--   都认它,所以它不会因为读不到而把一张报告漏过去(INVOKER-JOIN-5 那一族)。不借属主的眼睛,也就不需要在函数体里再问一遍码。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.batch_quality_hold(p_inbound_batch_id uuid, p_output_batch_id uuid)
 RETURNS TABLE(ncr_id uuid, ncr_code text, batch_code text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT n.id, n.code, COALESCE(ib.code, ob.code)
      FROM nonconformance_reports n
      LEFT JOIN inbound_batches ib ON ib.id = n.inbound_batch_id
      LEFT JOIN output_batches ob ON ob.id = n.output_batch_id
     WHERE ((p_inbound_batch_id IS NOT NULL AND n.inbound_batch_id = p_inbound_batch_id)
         OR (p_output_batch_id IS NOT NULL AND n.output_batch_id = p_output_batch_id))
       AND ncr_holds(n.status, n.disposition, COALESCE(ib.deleted_at, ob.deleted_at), COALESCE(ib.remaining_qty, ob.remaining_qty))
     ORDER BY n.opened_at, n.code
     LIMIT 1
$function$

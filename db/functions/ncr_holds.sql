-- db/functions/ncr_holds.sql
-- MES-6b-1(2026-10-15,MES-0 Q66;MES-6b Step 0 Q2 · Q21,Tim):【一张不合格报告此刻扣不扣着它那一批】—— 判据只写在这里一次,而且是一支【纯】函数:
--   它只看传进来的四个值,不读任何表。于是两种读者都用得上它而不会被读规则蒙住眼:
--     · batch_quality_hold(INVOKER)以调用者的读规则读报告与批次,再问它;
--     · ncr_rows(属主视图)以属主的眼睛读批次的余量,再问它。
--   扣着 ⇔ 报告还开着;或者决定为 reject,而那一批还在(没删)、还有货(remaining_qty > 0)—— reject 不放行,暂扣留到货没了为止(Q21)。
--   别的处置(accept · accept_with_penalty · rework · downgrade)都放行。余量为空读成 0(一批没有余量缓存就是没有货)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.ncr_holds(p_status text, p_disposition text, p_batch_deleted_at timestamp with time zone, p_remaining_qty numeric)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT COALESCE(p_status = 'open'
                    OR (p_status = 'decided' AND p_disposition = 'reject'
                        AND p_batch_deleted_at IS NULL AND COALESCE(p_remaining_qty, 0) > 0), false)
$function$

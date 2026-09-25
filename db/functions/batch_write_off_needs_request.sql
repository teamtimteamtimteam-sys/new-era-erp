-- db/functions/batch_write_off_needs_request.sql
-- APR-7(2026-09-25,grilling Q1):注销这一批要不要经 CFO —— 一份判据,三个读它的人
-- (一步删的那扇门 · 提注销申请 · 两张表上的注销按钮)。
--   进料批:还有料(remaining_qty > 0,计价与否都算 —— 库存要动),或者挂着一张【已签发】的销毁证书
--           (注销会把它作废,而那张纸在供应商手里)。
--   产出批:还有料。
--   其余(空批、没有已签发证书)→ false:仓库一步删,它既不动库存也不动价值。
-- 找不到 / 已删 → NULL(调用者按自己的原话拒)。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.batch_write_off_needs_request(p_inbound_batch_id uuid, p_output_batch_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_inbound_batch_id IS NOT NULL THEN
            (SELECT ib.remaining_qty > 0
                    OR EXISTS (SELECT 1 FROM certificates_of_destruction c
                                WHERE c.inbound_batch_id = ib.id AND c.status = 'issued')
               FROM inbound_batches ib WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL)
        ELSE
            (SELECT ob.remaining_qty > 0
               FROM output_batches ob WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL)
    END
$function$;

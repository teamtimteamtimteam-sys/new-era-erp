-- db/functions/guard_batch_metals_assay_source.sql
-- ROLE-1 · Batch 2b(Batch 2b grilling Q4):**一行"出自化验"的含量只由应用化验写出来**。
--
-- 【洞】inbound_batch_metals / output_batch_metals 的写策略开在 inbound.edit / output.edit 上 ——
-- 手工录含量本来归它们(PROC-1:手工那条路把出处写成 manual、source_assay_id 清空)。
-- 可是同一条策略也放行一次直连 INSERT / UPDATE 把 content_source 写成 'assay'、
-- source_assay_id 指向任何一份化验单:不经 action.apply_assay,却让一份化验单替一个
-- 手填的数字背书。本守卫(两张表同一支):
--   · 直连写(row_security_active)的 NEW 行出处是 'assay',或带着 source_assay_id
--     → ASSAY_CONTENT_THROUGH_FUNCTION_ONLY;
--   · 手工路径(manual、source_assay_id 为空)与删除照旧。
-- 应用化验的两支函数都是 SECURITY DEFINER,本守卫看不见它们。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql.

CREATE OR REPLACE FUNCTION public.guard_batch_metals_assay_source()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF NEW.content_source = 'assay' OR NEW.source_assay_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_CONTENT_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_batch_metals_assay_source() IS
'ROLE-1 Batch 2b:直连写(row_security_active)一行 inbound_batch_metals / output_batch_metals,若 content_source = assay 或带着 source_assay_id,按名拒 ASSAY_CONTENT_THROUGH_FUNCTION_ONLY —— 出自化验的含量只由应用化验(action.apply_assay)写出。手工录入与删除照旧。INVOKER,以分出直连写与属主路径。';

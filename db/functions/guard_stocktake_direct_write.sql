-- db/functions/guard_stocktake_direct_write.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q3):**盘点的三张表没有直连写**。
--
-- 【Step 0 量出来的三扇侧门】stocktakes 与 stocktake_lines 的 INSERT / UPDATE 策略开在
-- module.stocktakes.edit 上,于是任何持它的人不经 post_stocktake 就能:
--   · 把 stocktakes.status 直接写成 posted(库存与总账一行没动,单据却说过过账);
--   · 改写 created_by(四眼那条"开单人不能过账"的腿认的就是它);
--   · 在已过账或已取消的单上加行、改行(状态检查只在屏幕的 saveCount 里)。
-- 把过账交给财务、"录过数的人不能过账"都是空话,除非这几扇门关上。
--
-- 【怎么关】两条写策略拿掉;开单走 open_stocktake、录数走 record_stocktake_count、过账走
-- post_stocktake、取消走 cancel_stocktake —— 四支都是 SECURITY DEFINER。本守卫是语句级的,
-- 零行也照样触发(SILENT-1 那一族:没有写策略时直连 UPDATE 是零行、不报错),按名拒
-- STOCKTAKE_THROUGH_FUNCTION_ONLY。属主路径(row_security_active = false)一律放行。
-- 挂在 stocktakes · stocktake_lines · stocktake_counts 三张表上(同一句话,一份定义)。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.guard_stocktake_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'STOCKTAKE_THROUGH_FUNCTION_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_stocktake_direct_write() IS
'ROLE-1 Batch 3a:stocktakes / stocktake_lines / stocktake_counts 的直连写(row_security_active,语句级,零行也触发)按名拒 STOCKTAKE_THROUGH_FUNCTION_ONLY。开单 open_stocktake、录数 record_stocktake_count(action.stocktake_count,仓库)、过账 post_stocktake(action.stocktake_post,财务)、取消 cancel_stocktake(module.stocktakes.edit)—— 四支都是 SECURITY DEFINER。';

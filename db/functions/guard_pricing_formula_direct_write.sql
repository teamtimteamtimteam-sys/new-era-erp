-- db/functions/guard_pricing_formula_direct_write.sql
-- APR-8(2026-09-26,grilling Q6):**pricing_formulas 与 pricing_formula_metals 没有直连写**。
--
-- 此前写它们的是屏幕上的直连 INSERT / UPDATE / DELETE(app/tools/pricing/formulas/actions.ts),三条写策略开在
-- module.pricing.edit 上 —— 于是 cco 一次保存就改掉了此后每一次报价、每一张新采购单抄下的承诺,没有任何人批过。
-- 三条写策略一并拿掉;公式只经函数写:submit_formula_create_request(建一张停用的)、terms_request_execute_internal
-- (CFO 批准时写进条款、启用)、deactivate_pricing_formula、delete_pricing_formula。
--
-- 【为什么还要一支语句级守卫】没有写策略时,直连 INSERT 报的是一句 RLS 原文,UPDATE / DELETE 则是【零行、不报错】
-- (SILENT-1 那一族)—— 旧的编辑页在破窗里会把一次被挡下的保存报告成成功。本守卫零行也照样触发,按名拒
-- PRICING_FORMULA_THROUGH_REQUEST_ONLY。属主路径(row_security_active = false)一律放行 —— 上面那几支 DEFINER
-- 函数与迁移、fixture 布景走的就是它。形状照 guard_journal_direct_write。
-- 两张表上原有的 enforce_write_permission('module.pricing.edit') 留着、排在本守卫之前:不持码的人仍读到
-- PERMISSION_DENIED|module.pricing.edit(他缺的是码),持码的人读到本守卫(他缺的是 CFO)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_pricing_formula_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'PRICING_FORMULA_THROUGH_REQUEST_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_pricing_formula_direct_write() IS
'APR-8:pricing_formulas 与 pricing_formula_metals 的任何直连写(row_security_active,语句级,零行也触发)按名拒 PRICING_FORMULA_THROUGH_REQUEST_ONLY。公式只经 submit_formula_create_request / submit_formula_change_request / submit_formula_reactivate_request → CFO 批准(terms_request_execute_internal),以及 cco 一步的 deactivate_pricing_formula / delete_pricing_formula。';

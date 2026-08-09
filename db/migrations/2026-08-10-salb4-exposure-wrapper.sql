-- SAL-B4:敞口算子拆成内层 + 有检查的外壳
--
-- 撞上的事实:【属主权限视图只把"表访问"换成属主身份;视图体里的函数 EXECUTE
-- 仍按当前用户查】—— 被收回的 customer_ar_exposure_base 让 operations_now 对每个
-- authenticated 读者直接报 permission denied(fixture 30/39 双双顶出来)。
--
-- 拆法(消费方各走各的门,算术仍只有一份):
--   * 内层(收回,无检查):record_output_sale 用 —— definer 函数体内的调用以属主
--     身份执行,EXECUTE 过;信用拦截因此【不依赖卖货人自己的权限】——
--     warehouse 录销售照样被限额拦,这正是管控的意义。
--   * 外壳(授出,有检查):看板臂用 —— 无 module.customers.view 的读者拿到 NULL
--     (行反正被外层权限谓词滤掉),有权限的算真数。返回 NULL 而不是 RAISE:
--     视图体里 RAISE 会把整张 operations_now 对无关角色炸掉。
-- NOTE: apply with ./db/apply_migration.sh
BEGIN;

CREATE OR REPLACE FUNCTION public.customer_ar_exposure_visible(p_customer_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN has_permission('module.customers.view')
                THEN customer_ar_exposure_base(p_customer_id) END;
$function$;

COMMENT ON FUNCTION public.customer_ar_exposure_visible(uuid) IS
    '客户应收敞口的【有检查外壳】(SAL-B4):无 module.customers.view 返回 NULL(不 RAISE —— 视图体里 RAISE 会把整张 operations_now 炸掉),有权限则委托内层 customer_ar_exposure_base。看板臂用它;销售拦截用内层(拦截不依赖卖货人自己的权限)。';

COMMIT;

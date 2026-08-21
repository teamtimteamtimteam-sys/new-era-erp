CREATE OR REPLACE FUNCTION public.arm_permission_widen(p_item_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 【放宽】:持有其中任一码的读者,即便没有那一支声明的 permission,也看得见它。
    -- 与 arm_permission_any() 【方向相反】—— 那一个是【收窄】(与 permission 相与)。
    -- 两个名字很像而语义相反,所以两处注释互相点名。
    -- 免柜期是【钱】的事(滞港费),而录里程碑的人在操作侧:两边都要看得见,
    -- 而它们之间没有共同的权限码,所以只能放宽。
    -- EQP-2c:保养那两支同理 —— 机器卡在财务、干活的人在加工,而它们底下每一张
    -- 表/视图的读者都是这两个码的 OR。不放宽,财务会在首页读到「受限」,
    -- 而他明明读得到那张状态视图。
    SELECT CASE WHEN p_item_type = 'free_time_expiring'
                THEN ARRAY['module.purchasing.view', 'module.finance.view']
                WHEN p_item_type IN ('equipment_service_due', 'equipment_service_approaching')
                THEN ARRAY['module.processing.view', 'module.finance.view']
           END;
$function$


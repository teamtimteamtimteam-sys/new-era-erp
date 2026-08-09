CREATE OR REPLACE FUNCTION public.void_approval_on_amount_increase()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old_level smallint;
    v_new_level smallint;
BEGIN
    IF NEW.approval_status <> 'approved' THEN
        RETURN NEW;
    END IF;
    -- 用【单据自己的汇率】折本位币,两侧同口径
    v_old_level := approval_level_for(round(OLD.estimated_total_ccy * OLD.fx_rate, 2));
    v_new_level := approval_level_for(round(NEW.estimated_total_ccy * NEW.fx_rate, 2));

    -- 【只在需要更高一级时作废】金额下降、或仍在同一级内变动,原审批依然成立 ——
    -- 已经批过 2 级的单子降到 1 级,再要一次批准是空转。
    IF v_new_level > v_old_level THEN
        NEW.approval_status := 'pending';
        NEW.approved_at := NULL;
        NEW.approved_by := NULL;
        -- 留痕:这不是谁做的决定,是一个系统事件,但必须看得见
        PERFORM record_approval_decision(
            'purchase_order', NEW.id, 'approval_voided', v_new_level,
            format('金额由 %s 改为 %s(本位币),所需审批级别由 %s 升到 %s —— 原审批作废,重新路由',
                   round(OLD.estimated_total_ccy * OLD.fx_rate, 2),
                   round(NEW.estimated_total_ccy * NEW.fx_rate, 2),
                   v_old_level, v_new_level));
    END IF;
    RETURN NEW;
END;
$function$;
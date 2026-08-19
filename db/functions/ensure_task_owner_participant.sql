CREATE OR REPLACE FUNCTION public.ensure_task_owner_participant(p_task_id uuid, p_owner_emp uuid, p_actor uuid DEFAULT NULL::uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id      uuid;
    v_removed timestamptz;
BEGIN
    SELECT id, removed_at INTO v_id, v_removed
      FROM public.task_participants
     WHERE task_id = p_task_id AND employee_id = p_owner_emp
     ORDER BY removed_at NULLS FIRST
     LIMIT 1;

    -- ① 已经在场 → 什么都不做。**这一支是升级可重入的全部要点**:
    --    降级不动参与者行,所以再升级时它仍然活跃;当年那条无条件 INSERT
    --    会在这里撞上 uq_task_participants_active,把一串重复键印到屏幕上。
    IF v_id IS NOT NULL AND v_removed IS NULL THEN
        RETURN 'already_active';
    END IF;

    -- ② 曾经在、已退出 → 复活成一次【重新加入】,并且【自己写那一行历史】:
    --    trg_task_participants_history 只认"在场→离场"那一次,复活它看不见。
    --    【不能只用 ON CONFLICT DO NOTHING】:那会让一行 removed_at 非空的
    --    归属人行原样留着,而 can_edit_task 的团队分支要求【活跃】行 ——
    --    归属人于是改不动自己的团队任务,并且没有任何错误说明为什么。
    IF v_id IS NOT NULL THEN
        UPDATE public.task_participants
           SET removed_at = NULL, removed_by = NULL
         WHERE id = v_id;
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (p_task_id, 'participant_added', p_owner_emp, COALESCE(p_actor, p_owner_emp));
        RETURN 'rejoined';
    END IF;

    -- ③ 从来没有过 → 照旧插入。
    --    历史【故意不写】:trg_task_participants_history 的规矩是
    --    "变更记录记的是改动,不是初始状态",而归属人的头一行正是初始状态。
    INSERT INTO public.task_participants (task_id, employee_id, added_by)
    VALUES (p_task_id, p_owner_emp, COALESCE(p_actor, p_owner_emp));
    RETURN 'inserted';
END;
$function$


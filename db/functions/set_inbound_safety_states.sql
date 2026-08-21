CREATE OR REPLACE FUNCTION public.set_inbound_safety_states(
    p_inbound_batch_id uuid,
    p_codes            text[]
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n int;
BEGIN
    PERFORM require_permission('module.inbound.edit');

    IF p_inbound_batch_id IS NULL THEN
        RAISE EXCEPTION 'SAFETY_STATES_BATCH_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;

    -- 【整组替换,而且【在一笔事务里】—— 这是本函数存在的全部理由】
    -- PROC-2b 的写法是 app 侧"先删后插",而 PostgREST 一次一条语句 ——
    -- 两步之间失败会留下一个【空集】,而空集的意思是"没有人记过"。
    -- 也就是说一次失败的保存会把"有人记过"改写成"没有人记过",
    -- 而那两件事在这套系统里差得很远。函数体是一笔事务,失败即整体回滚。
    DELETE FROM inbound_batch_safety_states WHERE inbound_batch_id = p_inbound_batch_id;

    IF p_codes IS NOT NULL AND array_length(p_codes, 1) > 0 THEN
        -- 重复不去重 —— 让主键去拒(它自己有一句人话)。
        -- 【去重会让"记了两次"静悄悄地变成"记了一次"】,而那是把一个输入错误
        -- 藏起来,不是把它处理掉。
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        SELECT p_inbound_batch_id, c FROM unnest(p_codes) c;
    END IF;

    SELECT count(*) INTO v_n FROM inbound_batch_safety_states WHERE inbound_batch_id = p_inbound_batch_id;
    RETURN jsonb_build_object('inbound_batch_id', p_inbound_batch_id, 'count', v_n);
END;
$function$

;

COMMENT ON FUNCTION public.set_inbound_safety_states(uuid, text[]) IS
'PROC-2c:一批货的安全状态【整组替换】,一笔事务。批次页面与两条建批次的路【共用它】。

【它为什么存在】PROC-2b 在 app 侧"先删后插",而 PostgREST 一次一条语句 ——
两步之间失败会留下一个空集。**而空集在这套系统里是一句有含义的话:"没有人记过"。**
于是一次失败的保存会把"有人记过"改写成"没有人记过" —— 一个静默的、方向明确的谎。
放进函数体,失败即整体回滚,前一组原样还在。

════════════════════════════════════════════════════════════════════════════
【D3 的判决:【不】加一个 not_checked 取值 —— 而 grill 找到了它的镜像,一并写下】

**不加的理由:** 这张字典回答的是【这批货处在什么状态】,而"没有人看过"
不是货的属性,是我们知道多少的属性。把它放进字典还会让它可以与真状态【并列勾选】
(「进过水」+「没人看过」),而那是一句读不通的话。
**所以缺席就是缺席,而且它是一个有名字的状态**:屏幕上写着
「没有记过任何安全状态。那的意思是没有人记过,不是这批货是安全的」。

**而 grill 找到了 brief 没有点名的那一半 —— 它对 PROC-3 要紧:**

> **「看过了,五种都不适用」今天与「没有人看过」长得一模一样。**

一批【厂内边角料】:从来没充过电、没破损、没进水、没鼓包 —— 五个取值一个都不适用,
于是零行。而零行读作"没有人记过"。**这与 measured-zero 对 never-measured 是同一族。**

**它不在本刀里补,理由有两条:**
1. **消费者是 PROC-3,而这个区别的代价只有它算得出来** —— 一道拒绝"没有安全状态"
   的闸会不会冤枉一批完全合格的厂内边角料,是那一刀要回答的;
2. **PROC-2 已经把工具建好了一半**:`material_sources.implies_never_charged`。
   PROC-3 读得到它 —— 一批来源为厂内边角料的货,零行【不是】一个缺口。
   剩下的那部分(退役料、看过了确实没问题)才需要一个新的表达方式,
   而那多半是一个"检查过了"的时刻戳(是【检查】的属性),不是字典里的一个值。
**返回条件:PROC-3 决定"零行"对投料意味着什么的那一刻。**
════════════════════════════════════════════════════════════════════════════';

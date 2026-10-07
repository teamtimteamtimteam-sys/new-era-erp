-- db/functions/set_inbound_safety_states.sql
-- PROC-2c:一批货的安全状态,一笔事务。批次页面与两条建批次的路共用它。
-- ★ MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q15 · Q22 · Q23,Tim):【只加新勾上的、只结束拿掉的】。
--   p_codes = 这一批此刻该有的全部状态(与从前一样)。与【开着的】那几条比:
--     · 新出现的 → 插一条(记录时刻 = 现在,记录人 = 本人);
--     · 不再出现的 → 结束那一条:ended_at = 现在、ended_by = 本人、end_reason = p_end_reason(必填,空 →
--       SAFETY_STATE_END_REASON_REQUIRED|<状态,逗号分隔>,一条都不写);
--     · 两边都有的 → 一个字节都不动(滞留时钟从它被记下的那一刻起算,不因保存重来 —— 此前每一次保存都删掉重插)。
--   签名多了 p_end_reason(末尾、带默认值):迁移是 DROP + CREATE;已部署的旧页面不传它,勾上照样能存,拿掉会被要理由拒。
--   重复的代码不去重 —— 让"开着的只有一条"那个唯一索引去拒(PROC-2c 的原理由:去重会把一个输入错误藏起来)。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc2-intake-condition-axes.sql; rewritten by 2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.set_inbound_safety_states(p_inbound_batch_id uuid, p_codes text[], p_end_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n      int;
    v_codes  text[] := COALESCE(p_codes, ARRAY[]::text[]);
    v_ending text;
BEGIN
    PERFORM require_permission('module.inbound.edit');

    IF p_inbound_batch_id IS NULL THEN
        RAISE EXCEPTION 'SAFETY_STATES_BATCH_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;

    -- 要结束的那几条:开着、而这一次没再勾上。结束要理由 —— 在写任何东西之前问。
    SELECT string_agg(s.safety_state_code, ',' ORDER BY s.safety_state_code) INTO v_ending
      FROM inbound_batch_safety_states s
     WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));
    IF v_ending IS NOT NULL AND btrim(COALESCE(p_end_reason, '')) = '' THEN
        RAISE EXCEPTION 'SAFETY_STATE_END_REASON_REQUIRED|%', v_ending;
    END IF;

    UPDATE inbound_batch_safety_states s
       SET ended_at = now(), ended_by = auth.uid(), end_reason = btrim(p_end_reason)
     WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));

    -- 新勾上的:只插开着的里面还没有的。同一次请求里写了两遍的代码不去重,让唯一索引去拒。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT p_inbound_batch_id, c FROM unnest(v_codes) c
     WHERE NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
                          AND s.safety_state_code = c);

    SELECT count(*) INTO v_n FROM inbound_batch_safety_states
     WHERE inbound_batch_id = p_inbound_batch_id AND ended_at IS NULL;
    RETURN jsonb_build_object('inbound_batch_id', p_inbound_batch_id, 'count', v_n);
END;
$function$;

COMMENT ON FUNCTION public.set_inbound_safety_states(uuid, text[], text) IS
'★ MES-3a(2026-10-06,MES-3a Step 0 Q22 · Q23,Tim):从【整组替换】改成【只加新勾上的、只结束拿掉的】—— 没变的那几条一个字节都不动,
于是它们的记录时刻(滞留时钟,Q15)不因每一次保存重来;拿掉的那几条被【结束】(ended_at · ended_by · end_reason),不被删掉,
而结束要一个理由(p_end_reason,空 → SAFETY_STATE_END_REASON_REQUIRED|<状态>)。下面是 PROC-2c 的原注释,【整组替换】那一句从此按这一句读。

PROC-2c:一批货的安全状态【整组替换】,一笔事务。批次页面与两条建批次的路【共用它】。

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

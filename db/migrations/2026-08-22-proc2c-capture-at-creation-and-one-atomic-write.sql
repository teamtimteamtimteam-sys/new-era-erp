-- PROC-2c(2026-08-22):到货状态在【门口】就记得下来,以及那一组多值的【一次原子写】。
--
-- 【本刀没有加任何列】—— 所以 inbound_batches 虽然是遮蔽表,
-- 那条"列 + 列级授权 + _masked 视图三件一起"的规矩这一刀【用不上】。
-- chemistry_certainty_code 是 PROC-2 加的,已经在遮蔽视图里(实测 25 列)。
-- 写在这里,是因为"不适用"与"忘了做"在报告里长得一样。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【grill 改了三处】
--
-- ① **D4 说"就像批次页面那样按名拒" —— 而批次页面【今天根本不拒】。**
--    实测:PROC-2b 的 IntakeConditionPanel 与 intakeConditionActions 里
--    has_condition_axes 零命中。也就是说这条适用性规矩【哪里都还不存在】。
--    **只把它加进两条建批次的路,批次页面就成了一条绕过它的现成通道** ——
--    而一条有洞的规矩比没有规矩更坏,因为人会信它。
--    **处置:规矩放进【数据库】**(两个守卫触发器),于是两条建批次的路、
--    批次页面、以及直连 SQL 全都被同一条判据盖住。这也是 PROC-1/PROC-2 的做法。
--
-- ② **D4 的"required where applicable"与 D3 的"absence 是合法状态"字面冲突。**
--    F4 把话说死了:**"一个吃得下状态轴的种类,什么都没记,仍然合法"**。
--    所以这两个守卫【只拦一个方向】:不适用却填了要拒;适用而空着是合法的。
--    D4 那半句说的是 PROC-2 已经建好的【物料那三条轴】,不是这两条批次轴。
--
-- ③ **D3 的判决:brief 是对的,不加 not_checked —— 但 grill 找到了它的镜像。**
--    整段写在 set_inbound_safety_states 的函数注释里。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 那一组多值,由【一个函数】拥有(D1)═══════════════════════════════
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
$function$;

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

REVOKE EXECUTE ON FUNCTION public.set_inbound_safety_states(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_inbound_safety_states(uuid, text[]) TO authenticated;

-- ═══ 2 · 适用性:两个守卫,放在【库】里(见抬头 ①)═══════════════════════════
CREATE OR REPLACE FUNCTION public.guard_inbound_condition_applicable()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_material uuid;
    v_kind  text;
    v_axes  boolean;
    v_zh    text;
BEGIN
    -- 【本守卫挂在两张表上,所以先认清自己在替谁把关】
    IF TG_TABLE_NAME = 'inbound_batch_safety_states' THEN
        -- 这一张是子表:批次【已经在】了,所以经批次查物料。
        SELECT m.id INTO v_material
          FROM inbound_batches ib JOIN materials m ON m.id = ib.material_id
         WHERE ib.id = NEW.inbound_batch_id;
    ELSE
        -- inbound_batches:只在【真的填了】确定度时才管。空着永远合法(D3)。
        IF NEW.chemistry_certainty_code IS NULL THEN
            RETURN NEW;
        END IF;
        -- 【直接用 NEW.material_id,【不要】回头去查 inbound_batches】
        -- 这是 BEFORE INSERT:那一行还【不在表里】,按 NEW.id 查是查不到的,
        -- 于是守卫会走进"查不到就放行"那一支 —— **它会在 INSERT 这条路上
        -- 一声不吭地失效,只在 UPDATE 上有效**。
        -- 这个洞是故障注入矩阵抓出来的,不是想出来的:那一格本该红在 F4,
        -- 结果整块中止,追下去才发现守卫在建批次那条路上从来没生效过。
        v_material := NEW.material_id;
    END IF;

    SELECT mk.code, mk.has_condition_axes, mk.name_zh INTO v_kind, v_axes, v_zh
      FROM materials m JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE m.id = v_material;

    -- 【查不到就放行,而这【不是】偷懒】物料的 kind_code 可空(八行历史物料就是空的,
    -- PROC-1 明确不回填)。种类不知道 → 适不适用也不知道 →
    -- **而"不知道"绝不能被当成"不适用"来拒人**。这与"空的两种意思"是同一条:
    -- 拒绝要有依据,而这里没有依据。
    IF NOT FOUND OR v_axes IS NULL THEN
        RETURN NEW;
    END IF;

    IF NOT v_axes THEN
        RAISE EXCEPTION 'INBOUND_CONDITION_NOT_APPLICABLE|%|%', v_kind, v_zh
          USING HINT = '这一类物料没有到货状态可言(安全状态与化学体系确定度只对电池料成立)。';
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_inbound_condition_applicable() FROM PUBLIC, anon;

COMMENT ON FUNCTION public.guard_inbound_condition_applicable() IS
'PROC-2c:到货状态那两条轴【只对吃得下状态轴的种类成立】(material_kinds.has_condition_axes)。

【为什么在库里,而不是在那两条建批次的路上】PROC-2c 的 brief 说"就像批次页面那样拒"——
**而批次页面今天根本不拒**(实测:PROC-2b 那两支文件里 has_condition_axes 零命中)。
只把规矩加进建批次的路,批次页面就成了一条现成的绕行通道,
而**一条有洞的规矩比没有规矩更坏,因为人会信它**。放进库里,三条路一起盖住。

【只拦一个方向,这是刻意的】不适用却填了 → 拒;适用而空着 → **合法**。
后者是 D3 的裁决:缺席是一个有名字的状态,不是一个待填的空。
(而"必填"那一半说的是 PROC-2 已经建好的【物料】那三条轴,不是这两条。)

【种类不知道时放行】物料的 kind_code 可空,而"不知道适不适用"绝不能被当成
"不适用"去拒人 —— 拒绝要有依据。';

CREATE TRIGGER trg_inbound_safety_states_applicable
    BEFORE INSERT ON public.inbound_batch_safety_states
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_condition_applicable();

CREATE TRIGGER trg_inbound_batches_condition_applicable
    BEFORE INSERT OR UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_condition_applicable();

-- ═══ 3 · 两条建批次的路各接两个【尾部带默认值】的参数(D2)══════════════════
-- 【DROP + CREATE,不是 CREATE OR REPLACE】签名变了。
-- preflight_migration.py 会拒绝一次签名不同的替换(那是重载,旧签名会作为
-- 镜像看不见的漂移活下来 —— FIN-21)。WO-1b 给 commit_processing_run 加
-- p_work_order_id 时逐字是这个做法,本刀照抄,不发明第二种。
-- 【尾部 + 默认值 = 既有调用点一个字都不用改】—— F1 正面钉住这一条。

DROP FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric);

CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- GRN-1a:p_declared_qty 原样落库,【不拒绝任何差异】,也【绝不从采购行推断】。
    -- PROC-2c:确定度随表头一起落 —— 适用性由 trg_inbound_batches_condition_applicable
    -- 判(它在库里,所以这条路、批次页面、直连 SQL 三条一起盖住)。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, unit_price, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_unit_price, p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, p_chemistry_certainty, v_user, v_user)
    RETURNING id INTO v_id;

    -- PROC-2c:安全状态【只在给了参数时才碰】。
    -- 【NULL 与 '{}' 在这里是两件事】NULL = "这条路没提这件事"(既有调用点),
    -- '{}' = "明说了:一个状态都没有"。两者结果相同(零行),但只有前者
    -- 保证【一个字节都不动】—— F1 钉的正是这个。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);
    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

DROP FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric);

CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:同上 —— 现场收货这条路一样进得到 FIN-32 的约束。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- 单位固定 kg、stage 用默认值 —— 与收货表单今天的行为逐字一致。
    -- 【采购单侧的那一串拒绝(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
    --  PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED)仍由表上的触发器抛出】,
    -- 这个函数一个字都不重复它们 —— 重复一遍就是第二份会漂开的判断。
    -- 【GRN-1a:收错料【不拒绝】】—— 换料是一个正当的、可以谈成的场景,
    -- 而拒绝会把它变成一次不可能完成的收货。它由 grn_discrepancies 点名
    -- (material_mismatch),由人去判断。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, declared_qty,
        chemistry_certainty_code, created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, p_declared_qty,
        p_chemistry_certainty, v_user, v_user)
    RETURNING id INTO v_id;

    -- PROC-2c:见 create_inbound_batch 里同一段注释 —— NULL 与 '{}' 是两件事。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

COMMIT;

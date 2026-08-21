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
$fn$

;

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

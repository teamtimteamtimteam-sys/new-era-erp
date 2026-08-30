-- PROC-BUILD-1-fu1(2026-08-30):【不适用】不是【没设】—— 一条实测撞出来的缺陷。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【怎么发现的】按"定义之达成"的要求,把三条拒绝逐条【真的触发一遍】。
-- 造第二种场景(加工产出而形态没设)时,插不进那一行物料:
--
--     ERROR: MATERIAL_CONDITION_AXES_REQUIRED|battery_material
--
-- 【码】`guard_material_condition_axes`(PROC-2)对形态这一列有【两条相反】的规矩:
--   * 种类【有】状态轴(battery_material)→ 形态**必填**;
--   * 种类【没有】状态轴(ewaste / packaging / consumable / spare_part)
--     → 形态**必须留空**,`MATERIAL_KIND_HAS_NO_CONDITION_AXES` 拦着不许填。
--
-- 于是本刀那条"形态为空就拒"的判据,对第二类物料【说了一句假话并且锁死了它】:
--   * 假话:拒绝说"到物料页把形态设上",而那个种类**根本不许设**;
--   * 锁死:操作员照着做会撞上另一条拒绝,两条互相指着对方。
--
-- **而它不是一个假想分支** —— 【码】线上 `ewaste` 就是
-- `may_ever_be_processed = true` 且 `has_condition_axes = false`:
-- 一种**可以加工**、而形态**必须为空**的料。它的产出批一旦要卖,就撞这一条。
-- (fixture 115 的 F5 为同一个种类、同一个理由留过一臂 —— 那一臂当时挡的是
--  安全状态把"不适用"写成"缺席";这里是同一个错误换了一条轴。)
--
-- 【判据因此改成:空的【意思】是什么,由种类回答,不由人猜】
--   * 种类没有状态轴        → 形态为空 = **不适用** → **放行**;
--   * 种类有状态轴而形态为空 → **没设** → 拒(守卫使它对新行不可达,
--     但那条 CHECK 是 NOT VALID,历史行可以违反,所以这一支留着);
--   * **查不到种类**(kind_code 为空,线上八行历史物料正是如此)
--     → **没有人记过** → 拒。**Tim 已裁定线上那 11 批的拦是被接受的后果。**
--
-- 本刀只改一个函数体,不动表、不动数据、不动那四个触发器。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.assert_output_batch_saleable(p_output_batch_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
    v_material uuid;
    v_code     text;
    v_form     text;
    v_from_run boolean;
    v_axes     boolean;
BEGIN
    SELECT ob.material_id, ob.code, m.form_code
      INTO v_material, v_code, v_form
      FROM public.output_batches ob
      JOIN public.materials m ON m.id = ob.material_id
     WHERE ob.id = p_output_batch_id;

    IF NOT FOUND THEN
        RETURN;   -- 批次不存在不是本函数的题;既有的 OUTPUT_NOT_FOUND 管它。
    END IF;

    -- ① 形态已知且不可售 —— 与物料级同一条判据,同一个错误码。
    PERFORM public.assert_material_form_saleable(v_material);

    IF v_form IS NULL THEN
        -- ════════════════════════════════════════════════════════════════════
        -- 【空的意思由【种类】回答,不由人猜】—— 见文件头。
        -- 【JOIN 查不到 = 没有人记过种类,那【不是】"不适用"】—— 与 PROC-3 的
        -- guard_processing_input 立的那条同源:两边都让数据回答,而这一边的
        -- 默认方向相反(那边放行,这边拒),因为后果不同:那边防的是【停线】,
        -- 这边防的是【卖掉一件不许卖的东西】。
        -- ════════════════════════════════════════════════════════════════════
        SELECT mk.has_condition_axes INTO v_axes
          FROM public.materials m
          JOIN public.material_kinds mk ON mk.code = m.kind_code
         WHERE m.id = v_material;

        IF NOT FOUND OR v_axes IS TRUE THEN
            SELECT EXISTS (SELECT 1 FROM public.processing_outputs po
                            WHERE po.output_batch_id = p_output_batch_id)
              INTO v_from_run;

            -- 【这条不对称是刻意的,不要"修"平它】
            --   * 买进来的、以及这条轴之前就存在的料:照旧可售。空的意思是
            --     "这条轴比这行料还年轻"。拦掉它等于停掉线上每一笔销售,
            --     并且会教操作员随便填一个值去解锁 —— 那会毁掉这条轴本身。
            --   * 加工产出的料:拦。产线跑起来那天,一个从来没有人设过形态的
            --     产出批会悄悄变成可售,而且没有任何信号,**后果是法律上的**。
            --
            -- 【这条拒绝【不】说"这个东西不许卖"】—— 那是另一句话,而且会是假的。
            IF v_from_run THEN
                RAISE EXCEPTION 'SALE_FORM_NOT_SET|%', v_code
                  USING HINT = '这一批是加工产出的,而它的物料没有设形态,所以【判断不了】它可不可售。这【不是】说它不许卖。到【物料 → 打开这一种物料】把形态设上。';
            END IF;
        END IF;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.assert_output_batch_saleable(uuid) IS
'PROC-BUILD-1:批次级的可售性断言 —— 占用与出货/直销用它。

**它会抛两条【不同】的拒绝,而它们永远不许合并成一条:**
  * `SALE_FORM_NOT_SALEABLE` —— 这个形态法律上不许卖(R5);
  * `SALE_FORM_NOT_SET`      —— 这一批是加工出来的而形态没设,所以判断不了。
    **它【不是】说这个东西不许卖。**
再加上既有的库存类拒绝(`IOD_SALE_EXCEEDS_AVAILABLE` /
`SO_RESERVE_EXCEEDS_AVAILABLE` / `OUTPUT_NOT_FOUND` / `OUTPUT_DELETED`)——
**三种句子,三种下一步动作,一条都不许长得像另一条。**

【fu1:【不适用】不是【没设】】一个种类如果没有状态轴(线上 ewaste 就是,
而且它 may_ever_be_processed = true),它的形态**必须为空** ——
`guard_material_condition_axes` 拦着不许填。对这种料喊"去把形态设上"
既是假话又是死锁。所以空的意思由 `material_kinds.has_condition_axes` 回答:
没有状态轴 → 不适用 → 放行;有状态轴、或【查不到种类】→ 没人决定过 → 拒。';

COMMIT;

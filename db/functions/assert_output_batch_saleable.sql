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
    v_purpose  text;
    v_p_zh     text;
    v_p_en     text;
BEGIN
    SELECT ob.material_id, ob.code, m.form_code, ob.purpose_code
      INTO v_material, v_code, v_form, v_purpose
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

    -- ② PROC-WIRE-1A:这一批已被指定为下游工序的投料 —— 于是它不是可售库存。
    --
    -- 【它必须是【第四句】,而不是前三句里任何一句的变体】
    --   SALE_FORM_NOT_SALEABLE = 这个东西法律上不许卖(没有旁路);
    --   SALE_FORM_NOT_SET      = 形态没设,所以【判断不了】(去把形态设上);
    --   库存类               = 数量不够(少卖点或换一批);
    --   本条                 = 这一批【许给了下游工序】(释放指定,或换一批)。
    -- 四句话四种下一步动作。**并成一句,操作员就不知道该做什么。**
    --
    -- 【措辞的红线】它【不许】说"这个东西不许卖" —— 对正极片那是假话
    -- (may_be_sold = true),而说假话的拒绝会教人去改一个根本没错的地方。
    SELECT p.name_zh, p.name_en INTO v_p_zh, v_p_en
      FROM public.output_batch_purposes p
     WHERE p.code = v_purpose
       AND p.is_saleable_stock IS FALSE;

    IF FOUND THEN
        RAISE EXCEPTION 'SALE_BATCH_EARMARKED|%|%|%', v_code, v_p_zh, v_p_en
          USING HINT = '这一批已被指定为下游工序的投料,所以它不算可售库存。这【不是】说这个东西不许卖 —— 要卖它,先到产出批次页把这个指定释放掉,或者改用另一批。';
    END IF;
END;
$function$

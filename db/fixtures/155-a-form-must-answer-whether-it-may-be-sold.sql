-- 155 每加一个形态,必须当场回答"能不能卖" —— PROC-BUILD-1 的形态取值
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【每一臂钉什么】
-- F1 R2/R4 点名的七个形态【都在】。少一个,Tim 的工艺路线就有一段说不出口。
-- F2 **新形态与既有形态【不是同一行】**:
--    de_cased_cell ≠ loose_cells(后者的表注写着"仍需要开壳");
--    cathode_sheet ≠ electrode_scrap(后者是边角料与废片,前者是产品)。
--    这一臂挡的是"顺手把新形态并进一个看起来像的旧形态"。
-- F3 **may_be_sold 没有默认值** —— 加一个形态而不回答能不能卖,【插不进去】。
--    这一臂是整件事的铰链:一个默认放行的取值会让"没有人想过"悄悄变成"可以卖"。
-- F4 电解液【同时】是一个形态与一个损耗类别 —— 那是本刀把三件事放进同一支
--    迁移的那条连接。它断的话,两边就各自漂移了。
-- F5 implies_dismantling:de_cased_cell 【还要再拆】(壳开了,极片还没分),
--    其余六个不用。这一臂钉的是那条规则列没有被一律填成同一个值。
--
-- 日期:自带(本 fixture 不碰业务单据)。
BEGIN;
DO $$
DECLARE
    v_forms text[] := ARRAY['de_cased_cell','cathode_sheet','anode_sheet',
                            'separator','casing','structural_parts','electrolyte'];
    v_code text; v_n int; v_denied boolean; v_msg text; v_dis boolean;
BEGIN
    -- ══════════ F1 · 七个形态都在 ══════════
    RAISE NOTICE 'fixture 155 · 进入 F1';
    FOREACH v_code IN ARRAY v_forms LOOP
        IF NOT EXISTS (SELECT 1 FROM material_forms WHERE code = v_code) THEN
            RAISE EXCEPTION 'FIXTURE 155F1 失败:R2/R4 点名的形态【%】不在字典里 —— 少一个,Tim 那条工艺路线就有一段说不出口', v_code;
        END IF;
    END LOOP;

    -- ══════════ F2 · 新形态不是旧形态的别名 ══════════
    RAISE NOTICE 'fixture 155 · 进入 F2';
    IF NOT EXISTS (SELECT 1 FROM material_forms WHERE code = 'loose_cells')
       OR NOT EXISTS (SELECT 1 FROM material_forms WHERE code = 'electrode_scrap') THEN
        RAISE EXCEPTION 'FIXTURE 155F2 前置失败:这一臂比的是【新旧两行同时存在】—— 旧的那两行不在,就没有东西可比';
    END IF;
    -- 已开壳电芯 与 散电芯:两行,不是一行。
    SELECT count(*) INTO v_n FROM material_forms WHERE code IN ('loose_cells','de_cased_cell');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 155F2 失败:散电芯与已开壳电芯必须是【两行】。loose_cells 的表注写着"仍需要开壳",de_cased_cell 是它之后的一格';
    END IF;
    -- 正极片 与 极片废料:两行,而且【可售性可以各自回答】。
    SELECT count(*) INTO v_n FROM material_forms WHERE code IN ('electrode_scrap','cathode_sheet');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 155F2 失败:极片废料(边角料与废片)与正极片(产品)必须是【两行】—— 合并它们会让一个可售判断落在错的东西上';
    END IF;

    -- ══════════ F3 · may_be_sold 没有默认值 ══════════
    RAISE NOTICE 'fixture 155 · 进入 F3';
    IF (SELECT column_default FROM information_schema.columns
         WHERE table_schema='public' AND table_name='material_forms' AND column_name='may_be_sold') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 155F3 失败:may_be_sold 【不许有默认值】。一个默认放行的取值会让"没有人想过"悄悄变成"可以卖"';
    END IF;
    -- 不回答就插不进去 —— 这一臂是整件事的铰链。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO material_forms (code, name_en, name_zh, implies_dismantling, sort_order)
        VALUES ('zz155_form', 'f155', 'f155', false, 999);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 155F3 失败:加一个形态而【不回答能不能卖】,必须插不进去';
    END IF;
    -- 对照:回答了就插得进去 —— 少了这一半,一个"什么都拦"的实现照样绿。
    INSERT INTO material_forms (code, name_en, name_zh, implies_dismantling, may_be_sold, sort_order)
    VALUES ('zz155_form', 'f155', 'f155', false, true, 999);
    IF NOT EXISTS (SELECT 1 FROM material_forms WHERE code = 'zz155_form') THEN
        RAISE EXCEPTION 'FIXTURE 155F3 失败:回答了能不能卖之后,加一个形态必须是【加一行】的代价';
    END IF;

    -- ══════════ F4 · 电解液两边都在 ══════════
    RAISE NOTICE 'fixture 155 · 进入 F4';
    IF NOT EXISTS (SELECT 1 FROM material_forms WHERE code = 'electrolyte')
       OR NOT EXISTS (SELECT 1 FROM loss_categories WHERE code = 'electrolyte_evaporation') THEN
        RAISE EXCEPTION 'FIXTURE 155F4 失败:电解液【同时】是一个形态(R4:它离开这条线)与一个损耗类别(W2-i:质量走了)。**那条连接正是本刀把三件事放进同一支迁移的理由** —— 断了它,两边就各自漂移';
    END IF;

    -- ══════════ F5 · implies_dismantling 不是一律填同一个值 ══════════
    RAISE NOTICE 'fixture 155 · 进入 F5';
    SELECT implies_dismantling INTO v_dis FROM material_forms WHERE code = 'de_cased_cell';
    IF v_dis IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 155F5 失败:已开壳电芯【还要再拆】—— 壳开了,极片还没分。实得「%」', COALESCE(v_dis::text,'NULL');
    END IF;
    SELECT count(*) INTO v_n FROM material_forms
     WHERE code IN ('cathode_sheet','anode_sheet','separator','casing','structural_parts','electrolyte')
       AND implies_dismantling IS TRUE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 155F5 失败:极片/隔膜/壳体/结构件/电解液都已经是散的了,不该再标成"要拆"。实得 % 行标着要拆', v_n;
    END IF;
END $$;
ROLLBACK;

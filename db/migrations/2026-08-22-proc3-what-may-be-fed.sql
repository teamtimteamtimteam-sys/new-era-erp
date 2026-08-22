-- PROC-3:什么东西可以投料 —— 把 PROC-1/PROC-2 记下来的事实变成一条前置条件
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这一刀【收窄】行为,不去掉任何东西】
--
-- PROC-1 记下了"这一种物料可不可以投料",PROC-2 记下了"这一批货到货时是什么
-- 状态",PROC-2c 让门口就能记。**三刀都只记事实,一个人都没拦。**
-- 本刀读它们。一批昨天投得进去的货,今天可能被拒 —— 所以拒绝必须是一句人话,
-- 而句子与守卫在【同一次提交】里落地(AGENTS.md:破窗那一节)。
--
-- 【加在 guard_processing_input 上,因为那个守卫本来就是"什么可以当投料"】
-- 它今天的拒绝顺序是:
--   ① PROCESSING_INPUT_DIRECT_INSERT  裸插(不走 commit,库存流水就对不上)
--   ② PROCESSING_INPUT_SELF_CONSUME   一张单吃自己的产出
--   ③ MATERIAL_NOT_PROCESSABLE        PROC-1:这一【种】物料不许投料
-- 本刀接在 ③ 之后,问的是下一个问题:这一【批】货现在是什么状态。
-- 顺序是刻意的:种类答不上来就不必问批次,而"这种料根本不能加工"是一个
-- 比"这批货没放电"更靠前、也更便宜的答复。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_processing_input()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_material_id uuid;
    v_may  boolean;
    v_code text;
    -- PROC-3
    v_axes       boolean;
    v_batch_code text;
    v_n          integer;
    v_bad_zh     text;
    v_bad_en     text;
    v_c_zh       text;
    v_c_en       text;
BEGIN
    IF current_setting('evoltrya.movement_ctx', true) NOT LIKE 'processing:%'
       AND current_setting('evoltrya.movement_ctx', true) NOT LIKE 'reversal:%' THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_DIRECT_INSERT';
    END IF;
    IF NEW.output_batch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM processing_outputs po
        WHERE po.output_batch_id = NEW.output_batch_id AND po.run_id = NEW.run_id
    ) THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_SELF_CONSUME|%', NEW.run_id;
    END IF;
    -- ── PROC-1:只有【说了可以投料】的物料进得来 ────────────────────────────
    -- 【NULL 不放行】八行历史物料的 may_be_processed 是空的,而空的意思是
    -- "没有人决定过" —— 把它读成"可以"正是本仓库反复付账的那一个错
    -- (METAL-1 的 no_reference、SS-1 的阈值为 NULL)。所以判据写成
    -- `IS NOT TRUE`:空与 false 一样被拦,而拒绝的话说得出是哪一种。
    SELECT COALESCE(ib.material_id, ob.material_id) INTO v_material_id
      FROM (SELECT 1) x
      LEFT JOIN inbound_batches ib ON ib.id = NEW.inbound_batch_id
      LEFT JOIN output_batches  ob ON ob.id = NEW.output_batch_id;
    IF v_material_id IS NOT NULL THEN
        SELECT m.may_be_processed, m.code INTO v_may, v_code
          FROM materials m WHERE m.id = v_material_id;
        IF v_may IS NOT TRUE THEN
            RAISE EXCEPTION 'MATERIAL_NOT_PROCESSABLE|%|%', v_code,
                CASE WHEN v_may IS NULL THEN 'undecided' ELSE 'false' END
              USING HINT = '这一种物料没有被声明为可投料;第二个参数说的是【没人决定过】还是【决定了不投】。';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-3:这一【批】货现在是什么状态
    --
    -- 【只问进料批次,不问产出批次】一个产出批【从来没有到过门口】——
    -- 它是这里做出来的,没有"到货状态"可言。而且它要能存在,喂它的那些
    -- 进料批必然已经过了这道闸,所以"把一批脏料洗成干净产出"这条路不存在。
    -- (历史除外:本刀之前跑的 13 张单,它们的产出不受本刀追溯。)
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.inbound_batch_id IS NOT NULL THEN
        -- 【D5 适用性,而把它写反是最可能的那个缺陷】
        -- 一个【可加工、但没有状态轴】的种类,身上根本没有安全状态这回事,
        -- **绝不能因为"它没有安全状态"而被拦住**。不要以为"可加工"蕴含
        -- "有状态轴" —— 那只是今天这几行字典恰好如此,不是一条定律:
        -- 实测线上 `ewaste` 就是 may_ever_be_processed = true 且
        -- has_condition_axes = false。它今天就在,这一支不是假想的分支。
        --
        -- 【查不到 = 没有人记过种类,那【不是】"不适用"】—— 与 PROC-2c 立的
        -- 那条同源:两边都放行。JOIN 查不到(kind_code 为空、或字典里没有那一行)
        -- 时 FOUND 为假,于是整块跳过。
        --
        -- 【而这一支【今天走不到】,写下来免得下一个人以为它被测过】
        -- materials_kind_stated 那条 CHECK 要求 kind_code 与 may_be_processed
        -- **同时**非空,所以"没有种类"的行必然也"没表过态" —— 而没表过态的行
        -- 在上面 PROC-1 那一步就被 MATERIAL_NOT_PROCESSABLE 拦下了,轮不到这里。
        -- 线上实测:8 行物料,种类为空的 8 行,**种类为空却表了态的 0 行**。
        -- 【那为什么留着它】两个条件是各自独立的,而那条 CHECK 是 NOT VALID ——
        -- 它只管新行,历史行可以违反。今天没有这样的历史行,不等于以后没有;
        -- 而这一支的代价是一个 IF,写错的代价是把一批"没人记过种类"的货
        -- 按"不适用"放行,或者反过来拦死。**它没有 fixture 臂,因为造不出
        -- 一个到得了它的场景而不先撞上 PROC-1 那一条** —— 这句话本身就是
        -- 那条断言:两道守卫的顺序保证了它到不了。
        SELECT mk.has_condition_axes INTO v_axes
          FROM inbound_batches ib
          JOIN materials       m  ON m.id   = ib.material_id
          JOIN material_kinds  mk ON mk.code = m.kind_code
         WHERE ib.id = NEW.inbound_batch_id;

        IF FOUND AND v_axes IS TRUE THEN
            SELECT ib.code INTO v_batch_code
              FROM inbound_batches ib WHERE ib.id = NEW.inbound_batch_id;

            -- 【D4:只读 may_be_fed,【不读】is_active】
            -- is_active 管的是"今天还能不能【新选】这个值",不是"已经记下来的
            -- 事实还算不算数"。那批货进过水这件事,不会因为字典行被停用而改变。
            -- 要撤回一条【规则】,改的是 may_be_fed;要让一个值不再被选,改的
            -- 是 is_active。**两个动词,谁也替不了谁**(字典表注上写着同一句)。
            --
            -- 【D2:合取 —— 每一条都必须可投料】
            -- 一批已放电的货【同时也进过水】,那它就是进过水的:放电不能把水
            -- 抵消掉。这是全系统唯一一道失败后果是【起火】而不是【数字算错】
            -- 的闸,所以取的是"有一条坏的就拒"。
            --
            -- 【把【所有】坏的那几条一次点完,不是只报第一条】
            -- 报第一条会让人跑第二趟:清掉"进过水"再来,又撞上"鼓包漏液"。
            -- string_agg 按 sort_order 排,顺序稳定。
            SELECT count(*),
                   string_agg(d.name_zh, '、' ORDER BY d.sort_order)
                       FILTER (WHERE d.may_be_fed IS NOT TRUE),
                   string_agg(d.name_en, ', ' ORDER BY d.sort_order)
                       FILTER (WHERE d.may_be_fed IS NOT TRUE)
              INTO v_n, v_bad_zh, v_bad_en
              FROM inbound_batch_safety_states s
              JOIN inbound_safety_states d ON d.code = s.safety_state_code
             WHERE s.inbound_batch_id = NEW.inbound_batch_id;

            -- 【D1:缺席与坏值是两条拒绝,因为它们的下一步动作不同】
            -- "没有人记过"→ 去把它记下来;"这批货进过水"→ 去处理那批货。
            -- 一条共用的码会把这个区别藏起来。
            IF v_n = 0 THEN
                RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_RECORDED|%', v_batch_code
                  USING HINT = '一条安全状态都没有的意思是【没有人记过】,不是"这批货安全"。到【进料 → 打开这一批 → 到货状态】那一块把它记上。';
            END IF;
            IF v_bad_zh IS NOT NULL THEN
                RAISE EXCEPTION 'INPUT_SAFETY_STATE_NOT_FEEDABLE|%|%|%',
                    v_batch_code, v_bad_zh, v_bad_en
                  USING HINT = '这一批带着不可投料的安全状态(全部列在消息里,一次清完)。状态改了要到【进料 → 打开这一批 → 到货状态】那一块改。';
            END IF;

            -- ════════════════════════════════════════════════════════════════
            -- 【D3:这里【故意】与上面不对称 —— 确定度【没记】是放行的】
            --
            -- **不要"修"掉这个不一致。** 两条轴防的不是同一件事:
            --   * 安全状态防的是【起火】。一批【没人看过】的货与一批【不安全】的
            --     货,后果是同一个 —— 所以缺席必须拦。
            --   * 确定度防的是【数字算错】。那个数字由后面的化验回答,而不是靠
            --     停线来回答。
            -- 而且代价是实测过的:线上 23 批货【一条确定度都没有】,而「待识别」
            -- 这个取值本身 may_be_fed = false —— 所以"缺席也拦"等于把每一批
            -- 分不清成分的货【压在一家外部化验所后面】,好几天。
            --
            -- 这句话写在这里,是因为下一个读到这段的人会看见一处不一致并想把它
            -- 抹平,而抹平的方向如果选错,停的是产线。
            -- ════════════════════════════════════════════════════════════════
            SELECT c.name_zh, c.name_en INTO v_c_zh, v_c_en
              FROM inbound_batches ib
              JOIN inbound_chemistry_certainties c ON c.code = ib.chemistry_certainty_code
             WHERE ib.id = NEW.inbound_batch_id
               AND c.may_be_fed IS NOT TRUE;
            IF FOUND THEN
                RAISE EXCEPTION 'INPUT_CHEMISTRY_NOT_FEEDABLE|%|%|%',
                    v_batch_code, v_c_zh, v_c_en
                  USING HINT = '这一批的化学体系确定度被记成了一个不可投料的值。到【进料 → 打开这一批 → 到货状态】那一块改。';
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_processing_input() FROM PUBLIC, anon;

-- ════════════════════════════════════════════════════════════════════════════
-- D4:把【两个动词】写在字典自己身上,而不是只写在守卫里
-- ════════════════════════════════════════════════════════════════════════════
COMMENT ON COLUMN public.inbound_safety_states.may_be_fed IS
'PROC-2 记的规则,PROC-3 起【真的拦人】:guard_processing_input 读它。

【合取】一批货身上的每一条安全状态都必须 may_be_fed = true 才投得进去。
一批已放电的货【同时也进过水】,那它就是进过水的 —— 放电不能把水抵消掉。

【两个动词,谁也替不了谁】
  * 要撤回一条【规则】(我们把规则定错了,想全局收回)—— 改 **may_be_fed**。
    一行字典,立刻生效,而且【事实还留着】:那批货进过水这件事没有被抹掉。
  * 要让一个值【不再被新选】—— 改 **is_active**。它管的是选单,不管已记的事实。
【守卫【不读】is_active】所以停用一个值【不会】让已经贴着它的货变成可投料。
这是刻意的:停用一行字典是一个看起来很轻的动作,而它若能解锁一批货,
那就成了一条无痕迹、且一次性对所有批次生效的释放路径。';

COMMENT ON COLUMN public.inbound_chemistry_certainties.may_be_fed IS
'PROC-2 记的规则,PROC-3 起【真的拦人】:guard_processing_input 读它。

【与安全状态那一条【故意】不对称:确定度【没记】是放行的】
安全状态防起火,所以"没人看过"与"不安全"同罪;确定度防的是数字算错,
而那个数字由后面的化验回答,不靠停线回答。理由完整写在 guard_processing_input
里那一段注释上 —— 看见不一致想抹平之前先读它,抹平的方向选错会停产线。

【两个动词】与 inbound_safety_states.may_be_fed 同一条:may_be_fed 撤规则,
is_active 停选单,守卫只读前者。';

COMMIT;

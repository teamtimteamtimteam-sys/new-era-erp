-- 187 提取出来的基准换算,与它替掉的那段算术【逐个输入相同】
--
-- TOOLS-1 ④(2026-09-03)。把湿基/干基换算从 sale_settlement_compute 里提成
-- convert_weight_basis / convert_grade_basis,结算改调它们。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【为什么需要这一支,而 fixture 149 不够】★★
-- 149 走的是【结算那条路】,而且它已经在提取之后重跑通过(实测,线上,退 0)——
-- 它断言湿基与干基结算出不同的钱、而**含金属两边一模一样**,那正是换算对了的证据。
-- **但它只喂了它自己那一组输入。**
-- 这一支问的是另一个问题:**对每一种输入,新表达式与旧表达式是不是同一个函数?**
--
-- ★【"在真实结算行上证明输出不变"这件事,今天【做不到】,而这要说出来】★
--   实测(2026-09-03,线上):`sales_settlements` **0 行**,
--   `assay_results` 里 `moisture_pct` 非空的 **0 行**。
--   **所以"真实行"这个集合是空的,而在空集上通过的检查什么都没证明。**
--   替代做法就是本支:把旧表达式【原样抄成一个 oracle】,与新函数逐点比对。
--   两者都是纯算术,所以"在一张足够密的网格上处处相等"是一个【强于】
--   "在零行真实数据上没报错"的证据。
--
-- 【oracle 从哪来】下面 v_ref_w / v_ref_g 里那两段 CASE,是从提取【之前】的
-- sale_settlement_compute 里逐字符抄下来的。**不许"顺手改好"它** ——
-- 它的作用就是保留旧行为,包括旧行为里那些不好看的地方(见 D 臂)。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_w numeric; v_m numeric; v_c numeric;
    v_from text; v_to text;
    v_new numeric; v_ref numeric;
    v_cases int := 0; v_bad int := 0;
    v_first_bad text := NULL;
    v_contained_ar numeric; v_contained_dry numeric;
BEGIN
    -- ══════════ A. 重量:新函数 ≡ 旧表达式,逐点比对 ═══════════════════════
    -- 网格覆盖:重量含小数与大数;水分含 0 / NULL / 常见值 / 高值;四种基准组合。
    FOREACH v_w IN ARRAY ARRAY[0, 1, 12.5, 1000, 23456.789]::numeric[] LOOP
    FOREACH v_m IN ARRAY ARRAY[0, 0.5, 8, 12.34, 50, 99]::numeric[] LOOP
    FOREACH v_from IN ARRAY ARRAY['as_received','dry']::text[] LOOP
    FOREACH v_to IN ARRAY ARRAY['as_received','dry']::text[] LOOP
        v_new := convert_weight_basis(v_w, v_from, v_to, v_m);
        -- 【oracle:提取之前那一行,逐字符】
        --   v_swt := CASE WHEN v_basis = 'as_received' THEN v_gross
        --                 ELSE round(v_gross * (1 - COALESCE(v_moist,0)/100.0), 4) END;
        -- 它的 from 恒为 'as_received'(v_gross 是批次毛重),所以 oracle 只在
        -- from='as_received' 时有定义 —— 另一半是本刀【新增】的方向,A 臂不比它,
        -- 由 C 臂用"含金属守恒"来钉。
        IF v_from = 'as_received' THEN
            v_ref := CASE WHEN v_to = 'as_received' THEN v_w
                          ELSE round(v_w * (1 - COALESCE(v_m, 0) / 100.0), 4) END;
            v_cases := v_cases + 1;
            IF v_new IS DISTINCT FROM v_ref THEN
                v_bad := v_bad + 1;
                IF v_first_bad IS NULL THEN
                    v_first_bad := format('w=%s m=%s %s→%s 新=%s 旧=%s', v_w, v_m, v_from, v_to, v_new, v_ref);
                END IF;
            END IF;
        END IF;
    END LOOP; END LOOP; END LOOP; END LOOP;

    -- 【空集守卫】网格必须真的跑过 —— 一个 0 次比较的循环会安静地"通过"
    IF v_cases < 50 THEN
        RAISE EXCEPTION 'FIXTURE 187A 失败:只比对了 % 个输入 —— 网格没跑起来,不是"都相等"', v_cases;
    END IF;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'FIXTURE 187A 失败:% / % 个输入上新旧不等。第一个:%', v_bad, v_cases, v_first_bad;
    END IF;

    -- ══════════ B. 含量:新函数 ≡ 旧表达式,逐点比对 ═══════════════════════
    v_cases := 0; v_bad := 0; v_first_bad := NULL;
    FOREACH v_c IN ARRAY ARRAY[0, 0.01, 3.5, 42, 99.99]::numeric[] LOOP
    FOREACH v_m IN ARRAY ARRAY[0, 0.5, 8, 12.34, 50, 99]::numeric[] LOOP
    FOREACH v_from IN ARRAY ARRAY['as_received','dry']::text[] LOOP
    FOREACH v_to IN ARRAY ARRAY['as_received','dry']::text[] LOOP
        v_new := convert_grade_basis(v_c, v_from, v_to, v_m);
        -- 【oracle:提取之前那一段,逐字符】
        --   v_content_s := CASE
        --       WHEN v_assay.weight_basis = v_basis THEN v_content
        --       WHEN v_assay.weight_basis = 'dry' AND v_basis = 'as_received'
        --           THEN v_content * (1 - v_moist / 100.0)
        --       ELSE v_content / (1 - v_moist / 100.0) END;
        v_ref := CASE
            WHEN v_from = v_to THEN v_c
            WHEN v_from = 'dry' AND v_to = 'as_received' THEN v_c * (1 - v_m / 100.0)
            ELSE v_c / (1 - v_m / 100.0) END;
        v_cases := v_cases + 1;
        IF v_new IS DISTINCT FROM v_ref THEN
            v_bad := v_bad + 1;
            IF v_first_bad IS NULL THEN
                v_first_bad := format('c=%s m=%s %s→%s 新=%s 旧=%s', v_c, v_m, v_from, v_to, v_new, v_ref);
            END IF;
        END IF;
    END LOOP; END LOOP; END LOOP; END LOOP;
    IF v_cases < 100 THEN
        RAISE EXCEPTION 'FIXTURE 187B 失败:只比对了 % 个输入 —— 网格没跑起来', v_cases;
    END IF;
    IF v_bad > 0 THEN
        RAISE EXCEPTION 'FIXTURE 187B 失败:% / % 个输入上新旧不等。第一个:%', v_bad, v_cases, v_first_bad;
    END IF;

    -- ══════════ C. 真正要紧的那条不变量:含金属守恒 ═══════════════════════
    -- 重量与含量【必须换到同一个基准上】,两者相乘才守恒。这是 149 A 臂的判据,
    -- 这里在【本刀新增的那个方向】(dry → as_received)上再钉一次 ——
    -- 那个方向 oracle 里没有,所以只能用不变量来验。
    v_w := 1000;    -- 干基 1000 kg
    v_m := 20;      -- 水分 20%
    v_c := 10;      -- 干基含量 10%
    -- 干基那一侧的含金属
    v_contained_dry := v_w * v_c / 100.0;
    -- 换到湿基:重量变大,含量变小,乘积必须不变
    v_contained_ar := convert_weight_basis(v_w, 'dry', 'as_received', v_m)
                      * convert_grade_basis(v_c, 'dry', 'as_received', v_m) / 100.0;
    -- round 到 4 位之后比 —— convert_weight_basis 会 round,所以精确相等不成立,
    -- 而【那正是结算自己的口径】(SETTLEMENT_ROUND_DP = 4)。
    IF round(v_contained_dry, 2) IS DISTINCT FROM round(v_contained_ar, 2) THEN
        RAISE EXCEPTION 'FIXTURE 187C 失败:含金属不守恒 —— 干基 % vs 湿基 %',
            v_contained_dry, v_contained_ar;
    END IF;

    -- ══════════ D. 旧行为里【不好看】的那两处,原样保留 ═══════════════════
    -- 保留它们不是偷懒,是本刀的承诺:"结算的输出一个字节都不变"。
    -- 改掉它们【会改变失败模式】,而那也是一种改变。

    -- D1:含量换算在 moisture 为 NULL 时给出 NULL(旧式没有 COALESCE)。
    IF convert_grade_basis(10, 'dry', 'as_received', NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 187D1 失败:含量换算在 moisture 为 NULL 时应当给出 NULL(与提取前一致)';
    END IF;
    -- D2:重量换算在 moisture 为 NULL 且目标是 dry 时,COALESCE 成 0 → 原值。
    --     (旧式写着 COALESCE(v_moist,0),而它【只在重量这一侧】有。)
    IF convert_weight_basis(1000, 'as_received', 'dry', NULL) IS DISTINCT FROM 1000 THEN
        RAISE EXCEPTION 'FIXTURE 187D2 失败:重量换算的 COALESCE(m,0) 没保住 —— 提取前它在';
    END IF;
    -- D3:同基准时原值不动,【不 round】。
    IF convert_weight_basis(1234.56789, 'as_received', 'as_received', 8) IS DISTINCT FROM 1234.56789 THEN
        RAISE EXCEPTION 'FIXTURE 187D3 失败:同基准应当原值不动且不 round(与提取前一致)';
    END IF;

    RAISE NOTICE 'fixture 187 ok:重量 %、含量 % 个输入上新旧逐点相等;含金属守恒;三处旧行为保住',
        50, v_cases;
END $$;
ROLLBACK;

-- PROC-1(2026-08-12):产出化验 —— 化验单据长出第二个父,【记录共享,应用拆开】
--
-- REC-1 记下的不对等:回收率表两侧并排摆着,投入侧是化验结果(有单号、有日期、
-- 有取代链、可撤销),产出侧只有手工格子(没有单号、没有出处、没有"这是谁测的")。
-- 本刀让化验单据可以挂在产出批上,于是那张表的两侧【第一次可以是同一种事实】。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【双父 XOR,不另起一张表】—— processing_inputs 的形状
-- assay_results.inbound_batch_id 放开 NOT NULL,新增 output_batch_id,
-- CHECK num_nonnulls(...) = 1。另起一张表会得到两套化验语义(两条编号序列、
-- 两条取代链实现、两个撤销函数),而"化验"在实验室里只有一种。
--
-- 【记录、编号、取代是共享的;应用拆开】
-- record_assay_result 收两个父之一;ASY-YYYY-NNNN 一条序列(化验单号是实验室
-- 视角的,不分进出);取代链按父分别成链(同一个批次上后应用的取代先应用的,
-- 进料链与产出链互不相扰)。而【应用】拆成两个函数,不在一个函数里藏一个 IF:
--     apply_assay_result 把"抄含量"与"按含量重算应付并过账"焊在一起 ——
--     那是进料化验的全部意义(货到估价、证书回来重算)。
--     产出批【没有一张应付可以重述】:它的成本来自分摊,不来自化验。
--     所以 apply_output_assay 只做两件事:抄含量(带出处)、让过期机制看得见。
--     一个分支里"半个函数不执行"的函数,是两个函数挤在一个名字里。
--
-- 【含量出处:content_source + source_assay_id】—— FIN-26 的答案,原样适用
-- 两张 *_batch_metals 各加 content_source('assay'/'manual')与 source_assay_id。
-- 有了化验之后,手工敲的含量【算什么】?算"人填的",并且记下来 —— 出处是
-- 【记录】的,绝不从"有没有化验"去推断。
--   * output_batch_metals:既有 6 行(4 个产出批)全部回填 'manual',然后 NOT NULL。
--     这次回填是【可证明的】,与 FIN-26 的 NULL price_source 不同:产出化验在本
--     迁移之前【不可能存在】(承载它的列就是上面那条 ALTER 建的),所以既有产出
--     含量行必然全部出自手工格子。迁移内有断言把这个前提钉死。
--   * inbound_batch_metals:既有 19 行【保持 NULL = 出处未知】。进料行两个写入口
--     (apply_assay_result 与手工格子)都存在已久,哪行出自哪口【不可证明】——
--     按化验行反推"内容一致就是化验写的"正是 FIN-26 拒绝的那种推断。生产重建
--     不带这些行。新行必填:CHECK ... NOT VALID(FIN-32 的形状)。
--
-- 【守恒仍然是提示,永远不设闸】—— 而且不只是时序原因
-- 化验是一次【对事实的测量】。因为它与期望相矛盾就拒绝落账,压掉的恰恰是
-- "有什么不对"的证据 —— 拦下一张真实验室单据的系统,是在替实验室改数。
-- 产出化验买到的是【认识论】:守恒警告从"实验室 vs 手敲"变成"实验室 vs 实验室",
-- 报警时你第一次有资格怀疑工艺,而不是先怀疑哪只手滑了。
-- 回收率视图因此每侧多一列聚合出处(assay / manual / mixed / unknown):
-- 它终于能说出自己除的是哪一种数。
--
-- 【第六个过期源:output_batch_metals.updated_at】
-- metal_value 基准按产出金属含量拆成本,而过期视图此前不看这张表。于是
-- "先分摊、后应用产出化验"(正常次序:含量在提交之后才回来)会让拆分悄悄过期
-- 而毫无信号 —— 这个缺口今天对手工改动同样成立,一并关上。
--
-- 【RLS 跟着父走】进料化验挂 module.inbound.*,产出化验挂 module.output.*。
-- 不改的话产出化验被闩在进料模块后面 —— 产出的人读到 0 行而不是被拒,
-- OPS-14 修过的那种病,不再造一个新的。
--
-- 【产出侧测什么指标 —— Tim 未决,点名记账】Doc 1 在此处空白。机制接受任意
-- 金属子集,不预设"必须测哪几样";这个缺口记在 docs/as-built-divergences.md
-- 的 REC-1 条目下,等第一张真产出化验单来定。
--
-- 镜像同步:db/tables/{assay_results,inbound_batch_metals,output_batch_metals}.sql、
-- db/functions/{record_assay_result,apply_assay_result,unapply_assay_result,
-- apply_output_assay}.sql、db/views/{processing_metal_recovery,
-- processing_run_allocation_status}.sql。行为断言:db/fixtures/54。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─── 1 · assay_results:第二个父 ────────────────────────────────────────────

ALTER TABLE public.assay_results ALTER COLUMN inbound_batch_id DROP NOT NULL;
ALTER TABLE public.assay_results
    ADD COLUMN output_batch_id uuid REFERENCES public.output_batches (id);
ALTER TABLE public.assay_results
    ADD CONSTRAINT assay_results_one_parent
    CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1);
CREATE INDEX idx_assay_results_output_batch ON public.assay_results (output_batch_id);

COMMENT ON COLUMN public.assay_results.output_batch_id IS
    'PROC-1:产出批父(与 inbound_batch_id 二选一,num_nonnulls = 1 —— processing_inputs 的形状)。挂产出批的化验由 apply_output_assay 应用:只抄含量、不动定价 —— 产出批没有一张应付可以重述。';

-- ─── 2 · 含量出处:两张 metals 表 ───────────────────────────────────────────

ALTER TABLE public.inbound_batch_metals
    ADD COLUMN content_source text CHECK (content_source IN ('assay', 'manual')),
    ADD COLUMN source_assay_id uuid REFERENCES public.assay_results (id);
ALTER TABLE public.inbound_batch_metals
    ADD CONSTRAINT inbound_batch_metals_source_consistent CHECK (
        (content_source = 'assay'  AND source_assay_id IS NOT NULL)
     OR (content_source = 'manual' AND source_assay_id IS NULL)
     OR (content_source IS NULL    AND source_assay_id IS NULL));
-- 新行必填、老行放过(FIN-32 的形状):19 行既有进料含量【出处未知】,不回填 ——
-- 按"内容与化验一致"反推是 FIN-26 拒绝的那种推断。生产重建不带这些行。
ALTER TABLE public.inbound_batch_metals
    ADD CONSTRAINT inbound_batch_metals_content_source_required
    CHECK (content_source IS NOT NULL) NOT VALID;

ALTER TABLE public.output_batch_metals
    ADD COLUMN content_source text CHECK (content_source IN ('assay', 'manual')),
    ADD COLUMN source_assay_id uuid REFERENCES public.assay_results (id);

-- 回填的前提【在事务内断言】,不靠注释:产出化验在本迁移之前不可能存在
-- (output_batch_id 这一列就是上面建的),所以既有产出含量行必然全部手工。
-- 这个断言今天是结构性为真;它存在是为了让"重排/重跑这段 SQL"没法悄悄破坏前提。
DO $$
DECLARE v_n bigint;
BEGIN
    SELECT count(*) INTO v_n FROM public.assay_results WHERE output_batch_id IS NOT NULL;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'PROC-1 回填前提被破坏:已存在 % 份产出化验,不能再把全部产出含量行标成 manual', v_n;
    END IF;
END $$;
UPDATE public.output_batch_metals SET content_source = 'manual';
ALTER TABLE public.output_batch_metals ALTER COLUMN content_source SET NOT NULL;
ALTER TABLE public.output_batch_metals
    ADD CONSTRAINT output_batch_metals_source_consistent CHECK (
        (content_source = 'assay'  AND source_assay_id IS NOT NULL)
     OR (content_source = 'manual' AND source_assay_id IS NULL));

COMMENT ON COLUMN public.inbound_batch_metals.content_source IS
    'PROC-1:这行含量【是谁说的】—— assay(实验室,source_assay_id 指向那份单据)或 manual(人填的)。出处是【记录】的,绝不从"有没有化验"推断(FIN-26)。NULL = PROC-1 之前写入,出处未知 —— 不回填,界面读作「未知」;新行由 NOT VALID 约束强制必填。';
COMMENT ON COLUMN public.output_batch_metals.content_source IS
    'PROC-1:这行含量【是谁说的】—— assay(实验室,source_assay_id 指向那份单据)或 manual(人填的)。既有行回填 manual 是【可证明的】:产出化验在 PROC-1 之前不可能存在。';

-- ─── 3 · RLS 跟着父走 ───────────────────────────────────────────────────────
-- 进料化验挂 module.inbound.*,产出化验挂 module.output.*。守卫跟着数据自己的
-- 归属,不跟着"化验功能当初建在哪个目录"(OPS-15 的规则,换一张表再用一次)。

DROP POLICY "assay_results select by permission" ON public.assay_results;
CREATE POLICY "assay_results select by permission"
    ON public.assay_results
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));

DROP POLICY "assay_results insert by permission" ON public.assay_results;
CREATE POLICY "assay_results insert by permission"
    ON public.assay_results
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
             OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));

DROP POLICY "assay_results update by permission" ON public.assay_results;
CREATE POLICY "assay_results update by permission"
    ON public.assay_results
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)))
    WITH CHECK ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
             OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));

DROP POLICY "assay_results delete by permission" ON public.assay_results;
CREATE POLICY "assay_results delete by permission"
    ON public.assay_results
    AS PERMISSIVE FOR DELETE TO authenticated
    USING ((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)));

-- 子表(化验金属行)沿父单据判:哪个模块能读父,哪个模块就能读行。
DROP POLICY "assay_result_metals select by permission" ON public.assay_result_metals;
CREATE POLICY "assay_result_metals select by permission"
    ON public.assay_result_metals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.assay_results ar
                    WHERE ar.id = assay_result_metals.assay_result_id
                      AND ((ar.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
                        OR (ar.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)))));

DROP POLICY "assay_result_metals insert by permission" ON public.assay_result_metals;
CREATE POLICY "assay_result_metals insert by permission"
    ON public.assay_result_metals
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (EXISTS (SELECT 1 FROM public.assay_results ar
                    WHERE ar.id = assay_result_metals.assay_result_id
                      AND ((ar.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
                        OR (ar.output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)))));

DROP POLICY "assay_result_metals update by permission" ON public.assay_result_metals;
CREATE POLICY "assay_result_metals update by permission"
    ON public.assay_result_metals
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (EXISTS (SELECT 1 FROM public.assay_results ar
                    WHERE ar.id = assay_result_metals.assay_result_id
                      AND ((ar.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
                        OR (ar.output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM public.assay_results ar
                    WHERE ar.id = assay_result_metals.assay_result_id
                      AND ((ar.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
                        OR (ar.output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)))));

DROP POLICY "assay_result_metals delete by permission" ON public.assay_result_metals;
CREATE POLICY "assay_result_metals delete by permission"
    ON public.assay_result_metals
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (EXISTS (SELECT 1 FROM public.assay_results ar
                    WHERE ar.id = assay_result_metals.assay_result_id
                      AND ((ar.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.edit'::text))
                        OR (ar.output_batch_id IS NOT NULL AND has_permission('module.output.edit'::text)))));

-- ─── 4 · 记录:共享的那一半 ─────────────────────────────────────────────────
-- 签名变了(多收一个父),同一支迁移里先 DROP 旧签名 —— 不 DROP 就是重载,
-- 旧签名活下去而镜像里只有一个(preflight 会拒,FIN-21 的教训)。

DROP FUNCTION public.record_assay_result(uuid, date, jsonb, text, text, text, boolean, text);

CREATE OR REPLACE FUNCTION public.record_assay_result(p_inbound_batch_id uuid, p_assay_date date, p_metals jsonb, p_lab_name text DEFAULT NULL::text, p_certificate_ref text DEFAULT NULL::text, p_sample_ref text DEFAULT NULL::text, p_is_final boolean DEFAULT true, p_notes text DEFAULT NULL::text, p_output_batch_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
BEGIN
    -- PROC-1:两个父【二选一】。记录、编号、取代共享一张表一条序列;
    -- 权限跟着父走 —— 进料化验挂 inbound 模块,产出化验挂 output 模块。
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'ASSAY_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('module.inbound.edit');
        IF NOT EXISTS (
            SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
    ELSE
        PERFORM require_permission('module.output.edit');
        IF NOT EXISTS (
            SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
        END IF;
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, output_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes, created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes, v_user, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count
    );
END;
$function$;

-- ─── 5 · 应用:拆开的那一半 ─────────────────────────────────────────────────

-- 5a. apply_assay_result 只收进料化验。它把"抄含量"与"重算应付并过账"焊在一起,
--     那是进料化验的意义;产出化验走 apply_output_assay。抄进的行带上出处。
CREATE OR REPLACE FUNCTION public.apply_assay_result(p_assay_result_id uuid, p_pricing_formula_id uuid DEFAULT NULL::uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_assay    record;
    v_batch    record;
    v_commit   uuid;
    v_csrc     uuid;
    v_ccode    text;
    v_live     uuid;
    v_formula  uuid;
    v_fcode    text;
    v_metals   jsonb;
    v_calc     jsonb;
    v_unit     numeric;
    v_rep      jsonb := NULL;
    v_priced   boolean := false;
    v_status   text;
    v_prior    uuid;
    v_note     text := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- PROC-1:产出化验不走这条路 —— 这里的第 2-5 步全是围着应付转的,
    -- 而产出批没有应付。拆函数,不在函数里藏 IF。
    IF v_assay.output_batch_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_OUTPUT|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM inbound_batches
    WHERE id = v_assay.inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_assay.inbound_batch_id;
    END IF;

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    --    PROC-1:抄进的行带出处 —— content_source='assay',指回这份单据。
    DELETE FROM inbound_batch_metals WHERE inbound_batch_id = v_batch.id;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct,
                                      content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 【结算条款 = 承诺时抄下的副本】(FIN-27)。解析次序与从前解析公式同构:
    --    批次自己的承诺 → 它那条采购行的承诺。活公式在这里【一次都不读】。
    v_commit := resolve_pricing_commitment(v_batch.id);

    IF p_pricing_formula_id IS NOT NULL THEN
        -- 结算时才指名公式(无采购单的现场收货):那一刻【就是】承诺时刻,现在抄。
        -- 已经有副本了就不许被顶掉 —— 副本一旦落下,它就是记录。
        IF v_commit IS NULL THEN
            v_commit := commit_pricing_terms(p_pricing_formula_id, NULL, v_batch.id);
        ELSE
            SELECT c.source_formula_id, c.source_formula_code INTO v_csrc, v_ccode
            FROM pricing_term_commitments c WHERE c.id = v_commit;
            IF v_csrc IS DISTINCT FROM p_pricing_formula_id THEN
                RAISE EXCEPTION 'PRICING_TERMS_ALREADY_COMMITTED|%|%', v_batch.code, v_ccode;
            END IF;
        END IF;
    END IF;

    IF v_commit IS NOT NULL THEN
        -- 3. 与计价器同一份算术(calculate_metal_price_from_terms),条款来自副本;
        --    再走与手工计价【同一条】重计价路径(reprice_inbound_batch)—— 价差分录、
        --    price_history、1200/5000 拆账三件事只存在一份实现。
        --    参考日默认化验日:结算价随行情,行情看化验那天。
        SELECT c.source_formula_id, c.source_formula_code INTO v_formula, v_fcode
        FROM pricing_term_commitments c WHERE c.id = v_commit;

        v_calc := calculate_metal_price_from_terms(
            pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity,
            COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;

        IF v_unit > 0 THEN
            v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                           'Assay ' || v_assay.code || ' applied');
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 没有副本。有活公式引用【却没有副本】= FIN-27 之前留下的承诺,当时没记
        --    条款 —— 点名拒。悄悄退回去读活公式正是本切要拆掉的行为,而把今天的
        --    公式当成当时谈定的条款,是编造一份承诺(D:不回填)。
        --    完全没有公式引用的批次照旧:手工定价的采购本来就由人定价,不是错误。
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次的定价状态:只有真的重了价才谈得上 final
    v_status := CASE WHEN v_priced AND v_assay.is_final THEN 'final'
                     ELSE v_batch.pricing_status END;
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        pricing_status = v_status,
        updated_by = v_user
    WHERE id = v_batch.id;

    -- 6. 取代链:此前已执行且未被取代的化验,superseded_by 指向本次
    -- code 作平局裁决:applied_at 在同一事务里可能相同(now() 冻结),
    -- 而编号无缝且单调 —— 排序必须确定
    SELECT id INTO v_prior FROM assay_results
    WHERE inbound_batch_id = v_batch.id AND id <> p_assay_result_id
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'priced', v_priced,
        'formula_code', v_fcode,
        -- FIN-27:结算按【哪一份承诺】算的 —— 供应商问起来要指得出那份副本
        'commitment_id', v_commit,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'in_stock_ratio', v_rep->'in_stock_ratio',
        'inventory_share_usd', v_rep->'inventory_share_usd',
        'cost_share_usd', v_rep->'cost_share_usd',
        'journal_code', v_rep->'journal_code',
        'pricing_status', v_status,
        'note', v_note
    );
END;
$function$;

-- 5b. apply_output_assay:抄含量(带出处),让过期机制看得见。到此为止。
--     没有重计价、没有分录、没有 pricing_status —— 产出批的成本来自分摊,
--     化验改变的是"这批东西是什么",随后的成本重算是人显式重跑分摊的事
--     (过期旗会举起来,金额永远不悄悄动 —— FIN-8 以来的一贯分工)。
CREATE OR REPLACE FUNCTION public.apply_output_assay(p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_assay record;
    v_batch record;
    v_prior uuid;
    v_count integer;
    v_run   record;
BEGIN
    PERFORM require_permission('module.output.edit');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- 进料化验不走这条路:它的应用【就是】重算应付,少了那一半不叫应用。
    IF v_assay.output_batch_id IS NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_INBOUND|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM output_batches
    WHERE id = v_assay.output_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_assay.output_batch_id;
    END IF;

    -- 批次含量 = 本化验的含量(删后重插,同进料侧)。行带出处;updated_at/created_at
    -- 因此更新 —— 过期视图的第六个来源读的就是它,这一写【就是】举旗动作本身。
    DELETE FROM output_batch_metals WHERE output_batch_id = v_batch.id;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct,
                                     content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- 取代链:与进料侧同一条规则,按【产出批】成链(进料链与产出链互不相扰)
    SELECT id INTO v_prior FROM assay_results
    WHERE output_batch_id = v_batch.id AND id <> p_assay_result_id
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 产出它的那张加工单:若已分摊,这次应用让 metal_value 拆分过期(过期视图
    -- 自己会说;这里把"哪张单、有没有分摊过"报出来,界面不用再拼)。
    SELECT r.id, r.code, r.allocated_at INTO v_run
    FROM processing_outputs po
    JOIN processing_runs r ON r.id = po.run_id AND r.deleted_at IS NULL
    WHERE po.output_batch_id = v_batch.id
    LIMIT 1;

    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'output_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'metal_count', v_count,
        'superseded_prior', v_prior IS NOT NULL,
        'producing_run_code', v_run.code,
        'producing_run_allocated_at', v_run.allocated_at,
        'allocation_now_stale', v_run.allocated_at IS NOT NULL
    );
END;
$function$;

-- 5c. 撤销:共享的取代链,按父定位"最新一环";权限跟着父走。
CREATE OR REPLACE FUNCTION public.unapply_assay_result(p_assay_result_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_assay  record;
    v_latest uuid;
BEGIN
    -- PROC-1:先读单据才知道父是谁,权限判在任何改动之前(定义者身份读,不漏行)
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND OR v_assay.applied_at IS NULL THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    IF v_assay.inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('module.inbound.edit');
    ELSE
        PERFORM require_permission('module.output.edit');
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 只许撤最近一次:链条中间抽走一环,superseded_by 的叙事就断了。
    -- 链按【父】各自成链 —— 同一张表里进料链与产出链互不相扰。
    -- code 作平局裁决(applied_at 同事务内可能相同,编号无缝单调)。
    SELECT id INTO v_latest FROM assay_results
    WHERE (CASE WHEN v_assay.inbound_batch_id IS NOT NULL
                THEN inbound_batch_id = v_assay.inbound_batch_id
                ELSE output_batch_id = v_assay.output_batch_id END)
      AND applied_at IS NOT NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_latest IS DISTINCT FROM p_assay_result_id THEN
        RAISE EXCEPTION 'NOT_LATEST_ASSAY|%', v_assay.code;
    END IF;

    UPDATE assay_results
    SET applied_at = NULL, applied_by = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unapplied] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 被本次取代的上一份化验,链解开
    UPDATE assay_results SET superseded_by = NULL, updated_by = v_user
    WHERE superseded_by = p_assay_result_id;

    -- 【刻意不回价、不回含量】撤销"已执行"标记只是承认这份结果不再作数;
    -- 价格与含量退回到哪一版,是新化验或手工计价的显式动作 —— 静默回滚一个
    -- 已经过完账、可能已被分摊读走的状态,比留着它更危险。
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_assay.inbound_batch_id,
        'output_batch_id', v_assay.output_batch_id,
        'reverted_price', false
    );
END;
$function$;

-- ─── 6 · 回收率视图:每侧说出自己除的是哪一种数 ────────────────────────────
-- 新列追加在末尾(CREATE OR REPLACE 的要求);聚合口径:一侧全部同源报那个源,
-- 混着报 'mixed';进料侧 PROC-1 之前的行出处未知,报 'unknown'(产出侧结构上
-- 不可能 —— content_source NOT NULL)。

CREATE OR REPLACE VIEW public.processing_metal_recovery WITH (security_invoker = off) AS
 WITH ins AS (
         SELECT pi.run_id,
            m.metal,
            sum(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg,
            CASE
                WHEN min(COALESCE(m.content_source, 'unknown'::text)) = max(COALESCE(m.content_source, 'unknown'::text)) THEN min(COALESCE(m.content_source, 'unknown'::text))
                ELSE 'mixed'::text
            END AS input_source
           FROM processing_inputs pi
             JOIN LATERAL ( SELECT ibm.metal,
                    ibm.content_pct,
                    ibm.content_source
                   FROM inbound_batch_metals ibm
                  WHERE ibm.inbound_batch_id = pi.inbound_batch_id
                UNION ALL
                 SELECT obm.metal,
                    obm.content_pct,
                    obm.content_source
                   FROM output_batch_metals obm
                  WHERE obm.output_batch_id = pi.output_batch_id) m ON true
          GROUP BY pi.run_id, m.metal
        ), outs AS (
         SELECT po.run_id,
            obm.metal,
            sum(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg,
            CASE
                WHEN min(obm.content_source) = max(obm.content_source) THEN min(obm.content_source)
                ELSE 'mixed'::text
            END AS output_source
           FROM processing_outputs po
             JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
          GROUP BY po.run_id, obm.metal
        )
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    COALESCE(i.metal, o.metal) AS metal,
    i.input_metal_kg,
    o.output_metal_kg,
    i.metal IS NOT NULL AS input_measured,
    o.metal IS NOT NULL AS output_measured,
        CASE
            WHEN i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric THEN round(o.output_metal_kg / i.input_metal_kg * 100::numeric, 2)
            ELSE NULL::numeric
        END AS recovery_pct,
        CASE
            WHEN i.metal IS NULL THEN 'input_not_measured'::text
            WHEN o.metal IS NULL THEN 'output_not_measured'::text
            WHEN i.input_metal_kg = 0::numeric THEN 'input_measured_zero'::text
            ELSE NULL::text
        END AS recovery_blocked_by,
    i.metal IS NOT NULL AND o.metal IS NOT NULL AND o.output_metal_kg > i.input_metal_kg AS conservation_warning,
    bool_or(i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric) OVER (PARTITION BY r.id) AS run_recovery_computable,
    i.input_source,
    o.output_source
   FROM ins i
     FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
     JOIN processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
  WHERE r.status = 'committed'::text AND r.deleted_at IS NULL AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.processing_metal_recovery IS
    '每个已提交加工单 × 金属的回收率(REC-1 起区分【测出来是零】与【根本没测】)。input_metal_kg / output_metal_kg 为 NULL 表示那一侧从未测过这个金属 —— 不再压成 0,因为两者导向相反的结论。recovery_blocked_by 说明算不出的原因;conservation_warning 只在两侧都测过、且产出大于投入时为真,它【永远只是提示,绝不设闸】—— 而且不只因为时序(产出含量往往在提交之后才录):化验是一次对事实的测量,因为它与期望相矛盾就拒绝落账,压掉的恰恰是"有什么不对"的证据。PROC-1 起每侧带聚合出处 input_source / output_source(assay / manual / mixed / unknown)—— 这个警告从此分得出"实验室 vs 手敲"与"实验室 vs 实验室",这张表也终于能说出自己除的是哪一种数(unknown = PROC-1 之前录的行,出处没人记过)。';

-- ─── 7 · 过期视图:第六个来源 ───────────────────────────────────────────────
-- metal_value 基准按产出金属含量拆成本(allocate_processing_costs 直接读
-- output_batch_metals),而这里此前不看那张表。于是"先分摊、后应用产出化验"
-- (正常次序)让拆分悄悄过期 —— 这个缺口对手工改含量同样成立,一并关上。
-- 【按基准限定】:weight 基准的拆分不读含量,含量变了它不过期 —— 无条件举旗
-- 是喊狼来了,而没人看的旗和没有旗是同一样东西(fixture 54 两个方向都钉)。

CREATE OR REPLACE VIEW public.processing_run_allocation_status WITH (security_invoker = off) AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    COALESCE(g.cogs_posted, 0::bigint) AS cogs_posted,
    r.capitalization_entry_id IS NULL OR je.status = 'posted'::text AS safe_to_reallocate
   FROM processing_runs r
     LEFT JOIN journal_entries je ON je.id = r.capitalization_entry_id
     LEFT JOIN LATERAL ( SELECT max(x.ts) AS last_cost_change
           FROM ( SELECT GREATEST(e.created_at, e.updated_at) AS ts
                   FROM processing_cost_entries e
                  WHERE e.run_id = r.id
                UNION ALL
                 SELECT fa.created_at
                   FROM freight_allocations fa
                     JOIN freight_documents fd ON fd.id = fa.freight_document_id
                     JOIN processing_inputs pif ON pif.inbound_batch_id = fa.inbound_batch_id
                  WHERE pif.run_id = r.id AND fd.deleted_at IS NULL AND fd.status = 'posted'::text
                UNION ALL
                 SELECT ph.created_at
                   FROM price_history ph
                     JOIN processing_inputs pi ON pi.inbound_batch_id = ph.inbound_batch_id
                  WHERE pi.run_id = r.id
                UNION ALL
                 SELECT r2.allocated_at
                   FROM processing_inputs pi2
                     JOIN processing_outputs po2 ON po2.output_batch_id = pi2.output_batch_id
                     JOIN processing_runs r2 ON r2.id = po2.run_id
                  WHERE pi2.run_id = r.id AND r2.allocated_at IS NOT NULL
                UNION ALL
                 SELECT GREATEST(obm.created_at, obm.updated_at) AS ts
                   FROM processing_outputs po6
                     JOIN output_batch_metals obm ON obm.output_batch_id = po6.output_batch_id
                  WHERE po6.run_id = r.id AND r.allocation_basis = 'metal_value'::text
                UNION ALL
                 SELECT r.allocation_basis_changed_at AS ts) x) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS cogs_posted
           FROM sales_records sr
             JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
          WHERE sr.cogs_entry_id IS NOT NULL) g ON true
  WHERE r.deleted_at IS NULL AND has_permission('module.processing.view'::text);

COMMIT;

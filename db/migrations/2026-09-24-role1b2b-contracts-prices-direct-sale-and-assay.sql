-- db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql
-- ROLE-1 · Batch 2b —— Tim 的角色与审批矩阵(docs/role-matrix.md)第 2 批的后一半。
-- 由 db/scripts/build_role1b2b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本批做什么】(Batch 2 grilling Q12–Q15 + Batch 2b grilling Q1–Q6,Tim 全部接受)
--   ① 四个新动作码:action.contract_terms(cco)· action.metal_prices(finance)·
--      action.direct_sale(cco)· action.apply_assay(cto)。
--   ② ★ Tim 的常设裁定(2026-09-24):admin 角色持【每一个】码 —— 本刀的四个,加 Batch 2a 的三个
--      (action.finance_settings · action.customer_credit · action.supplier_approve)。幂等:
--      ON CONFLICT DO NOTHING(Tim 可能已经手工加过;Step 0 以 postgres 读基表:一个都没有)。
--      admin@ 不持 cfo 角色(那一行 revoked_at = 2026-09-23 15:00:48),本刀不碰 user_roles。
--   ③ 合同(Q12 · Q1):contracts 与七张条款表的写策略和 enforce_write_permission 从
--      module.customers.edit / module.suppliers.edit 换成 action.contract_terms。
--      link_document_to_contract 的门不变(挂单据仍归开单据的码)。
--   ④ 金属行情(Q13):metal_prices · metal_price_indices · index_market_calendar · pricing_settings
--      的写策略与触发器、upsert_metal_prices 的门,换成 action.metal_prices。定价公式仍在
--      module.pricing.edit —— 从 cto 与 finance 拿掉,只剩 cco(和 admin)。procurement / sales
--      两个无人持有的角色保留它(Q2,ROLE1B2B-UNHELD-PRICING-EDIT)。
--   ⑤ 直接销售(Q14 · Q3):record_output_sale 换成 action.direct_sale;sales_records 的
--      INSERT 与 UPDATE 两条写策略拿掉(四个写入方全是 SECURITY DEFINER);原来那支
--      enforce_write_permission('module.finance.edit') 换成 guard_sales_record_direct_write
--      (语句级,按名拒 SALE_THROUGH_FUNCTION_ONLY)。
--   ⑥ 化验(Q15 · Q4):apply_assay_result · apply_output_assay · unapply_assay_result ·
--      preview_assay_price · preview_apply_output_assay 换成 action.apply_assay;记录结果仍归
--      inbound.edit / output.edit。两扇侧门按名关:guard_assay_applied_columns
--      (ASSAY_APPLY_THROUGH_FUNCTION_ONLY)· guard_batch_metals_assay_source
--      (ASSAY_CONTENT_THROUGH_FUNCTION_ONLY)。reprice_inbound_batch 里那道嵌套的
--      inbound.edit 检查不拆(cto 持有它;登记在 Batch 4)。reprice_from_committed_terms
--      与它的预览不动(Q6,Batch 4)。
--
-- 【不做什么】审批开关与策略一个字都不碰。不动任何决定函数的门。不写任何业务行。
--
-- 【RUNTIME CONFIG 的引导默认值,照 AGENTS.md 那条规矩说清楚】
--   · role_permissions 的引导【改了】:finance 的 module.pricing.edit 换成 action.metal_prices ——
--     仍是它原来的意思(全新安装的起点)。cco / cto / cfo 仍不在引导里
--     (ROLE1-BOOTSTRAP-MISSING-ROLES),所以 contract_terms / direct_sale / apply_assay 在全新
--     安装里只有 admin 之外无人持有 —— 与 Batch 1、2a 的新码同一个处境。引导里的 admin 仍是
--     "只做系统管理";线上 admin 持全部码是 Tim 为测试做的裁定,不是全新安装的起点。
--   · permissions 是逐行比对的种子:新增四行;module.pricing.edit 与 module.output.edit 两行的
--     描述改写(不再含金属行情 / 销售),镜像同步。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少;
-- approval_log 与 journal_entries 一行没多;合同、行情、销售、化验的行数一行没变;每一个角色的码 =
-- 之前 + 本刀的授权 − 本刀的两条收回,不多不少;admin 持有每一个新码、一个旧码也没丢;每一张在途单据都还有
-- 一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B2B_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.contract_terms', 'action.metal_prices',
                                                        'action.direct_sale', 'action.apply_assay')) THEN
        RAISE EXCEPTION 'ROLE1B2B_PRE|new codes already exist';
    END IF;
    IF (SELECT count(*) FROM permissions WHERE code IN ('action.finance_settings', 'action.customer_credit',
                                                         'action.supplier_approve')) <> 3 THEN
        RAISE EXCEPTION 'ROLE1B2B_PRE|Batch 2a codes are not all present';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('trg_assay_results_applied_columns',
               'trg_inbound_batch_metals_assay_source', 'trg_output_batch_metals_assay_source',
               'trg_sales_records_direct_write')) THEN
        RAISE EXCEPTION 'ROLE1B2B_PRE|a Batch 2b trigger already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b2b_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');
CREATE TEMP TABLE b2b_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log, (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM contracts) AS contracts, (SELECT count(*) FROM metal_prices) AS metal_prices,
       (SELECT count(*) FROM metal_price_indices) AS indices, (SELECT count(*) FROM sales_records) AS sales_records,
       (SELECT count(*) FROM assay_results) AS assays,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied;
CREATE TEMP TABLE b2b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:四个新码;两个码的描述改写 ─────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.contract_terms', 'action', 'Contracts and their terms', '合同与合同条款', 'Create contracts and write their terms: grade specifications, pricing, refining charges, penalties, settlement, volume commitments and insurance. Linking a purchase or sales document to a contract stays with the code that raises the document.', '新建合同并写它的条款:品位规格、计价、精炼费、罚则、结算、数量承诺与保险。把一张采购或销售单据挂到合同上,仍归开那张单据的码。', 1010),
    ('action.metal_prices', 'action', 'Metal prices, indices and the quote threshold', '金属行情、指数与报价阈值', 'Enter and correct daily metal prices, maintain price indices and the index market calendar, and set the stale-quote threshold. Pricing formulas stay with Pricing (edit).', '录入与更正每日金属行情,维护价格指数与指数交易日历,设定报价过期阈值。定价公式仍归「定价(编辑)」。', 1020),
    ('action.direct_sale', 'action', 'Sell directly from an output batch', '从产出批次直接销售', 'Record a sale straight from an output batch, outside a sales order. It posts revenue and cost of goods. Sales orders and shipping stay with Sales (edit).', '不经销售订单,直接从一个产出批次记一笔销售;它过收入与销货成本。销售订单与发货仍归「销售(编辑)」。', 1030),
    ('action.apply_assay', 'action', 'Apply and unapply assay results', '应用与撤销应用化验结果', 'Apply a recorded lab result to an inbound or output batch, undo that application, and see what applying would do. Applying an inbound assay reprices the batch and posts to the supplier payable. Recording a lab result stays with Inbound (edit) and Output (edit).', '把一份已记录的化验结果应用到进料或产出批次上、撤销这次应用,并预览应用会带来什么。应用进料化验会给批次重新定价,并过到供应商应付。记录化验结果仍归「进料(编辑)」与「产出(编辑)」。', 1040);
UPDATE public.permissions SET description_en = 'Pricing formulas — create, change, remove. Metal prices moved to their own action code.', description_zh = '定价公式 —— 新建、修改、删除。金属行情已移到它自己的动作码。'
 WHERE code = 'module.pricing.edit';
UPDATE public.permissions SET description_en = 'Output batches and their lab results — create, change, remove. Direct sale and assay application moved to their own action codes.', description_zh = '产出批次与它的化验结果 —— 新建、修改、删除。直接销售与化验应用已移到各自的动作码。'
 WHERE code = 'module.output.edit';

-- ── 2 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/guard_assay_applied_columns.sql
-- ROLE-1 · Batch 2b(Batch 2 grilling Q15 · Batch 2b grilling Q4):**应用化验结果只归 cto**
-- (action.apply_assay),记录化验结果仍归 module.inbound.edit / module.output.edit。
--
-- 【为什么需要一支守卫】assay_results 的写策略仍开在 inbound.edit / output.edit 上(记录结果
-- 的人要写它),于是一个持这两个码的人可以不经 apply_assay_result / apply_output_assay /
-- unapply_assay_result,直接把 applied_at / applied_by / superseded_by 写成"已应用"或"已撤销"——
-- 批次不重算价、含量不抄,但屏幕与提醒会把它当成应用过。本守卫把这三列收成只走函数:
--   · 直连 INSERT 带着其中任何一列(非 NULL)→ ASSAY_APPLY_THROUGH_FUNCTION_ONLY;
--   · 直连 UPDATE 改动其中任何一列(IS DISTINCT FROM)→ 同上;
--   · 别的列(备注、实验室、证书号……)照旧归记录的人。
-- 三支函数都是 SECURITY DEFINER,row_security_active = false,本守卫看不见它们。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql.

CREATE OR REPLACE FUNCTION public.guard_assay_applied_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.applied_at IS NOT NULL OR NEW.applied_by IS NOT NULL OR NEW.superseded_by IS NOT NULL THEN
            RAISE EXCEPTION 'ASSAY_APPLY_THROUGH_FUNCTION_ONLY';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.applied_at IS DISTINCT FROM OLD.applied_at
       OR NEW.applied_by IS DISTINCT FROM OLD.applied_by
       OR NEW.superseded_by IS DISTINCT FROM OLD.superseded_by THEN
        RAISE EXCEPTION 'ASSAY_APPLY_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_assay_applied_columns() IS
'ROLE-1 Batch 2b:直连写(row_security_active)改动 assay_results.applied_at / applied_by / superseded_by,或直连 INSERT 带着其中任何一列,按名拒 ASSAY_APPLY_THROUGH_FUNCTION_ONLY —— 应用与撤销应用只走 apply_assay_result / apply_output_assay / unapply_assay_result(action.apply_assay,cto)。记录结果的其余列照旧。INVOKER,以分出直连写与属主路径。';

-- db/functions/guard_batch_metals_assay_source.sql
-- ROLE-1 · Batch 2b(Batch 2b grilling Q4):**一行"出自化验"的含量只由应用化验写出来**。
--
-- 【洞】inbound_batch_metals / output_batch_metals 的写策略开在 inbound.edit / output.edit 上 ——
-- 手工录含量本来归它们(PROC-1:手工那条路把出处写成 manual、source_assay_id 清空)。
-- 可是同一条策略也放行一次直连 INSERT / UPDATE 把 content_source 写成 'assay'、
-- source_assay_id 指向任何一份化验单:不经 action.apply_assay,却让一份化验单替一个
-- 手填的数字背书。本守卫(两张表同一支):
--   · 直连写(row_security_active)的 NEW 行出处是 'assay',或带着 source_assay_id
--     → ASSAY_CONTENT_THROUGH_FUNCTION_ONLY;
--   · 手工路径(manual、source_assay_id 为空)与删除照旧。
-- 应用化验的两支函数都是 SECURITY DEFINER,本守卫看不见它们。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql.

CREATE OR REPLACE FUNCTION public.guard_batch_metals_assay_source()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF NEW.content_source = 'assay' OR NEW.source_assay_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_CONTENT_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_batch_metals_assay_source() IS
'ROLE-1 Batch 2b:直连写(row_security_active)一行 inbound_batch_metals / output_batch_metals,若 content_source = assay 或带着 source_assay_id,按名拒 ASSAY_CONTENT_THROUGH_FUNCTION_ONLY —— 出自化验的含量只由应用化验(action.apply_assay)写出。手工录入与删除照旧。INVOKER,以分出直连写与属主路径。';

-- db/functions/guard_sales_record_direct_write.sql
-- ROLE-1 · Batch 2b(Batch 2 grilling Q14 · Batch 2b grilling Q3):**sales_records 没有直连写**。
--
-- 【量过的】写 sales_records 的四支函数 —— record_output_sale · ship_order ·
-- attribute_sale_customer · allocate_processing_costs —— 全是 SECURITY DEFINER(线上
-- pg_proc.prosecdef = t,2026-09-24 以 postgres 读);没有一个屏幕直连写它。于是 INSERT 与
-- UPDATE 两条写策略(都开在 module.finance.edit 上)一并拿掉。
--   · INSERT 那一条让财务不经 record_output_sale(现归 action.direct_sale)就能记一笔销售;
--   · UPDATE 那一条过得了 reject_sales_record_mutation 的只剩一件事:把 cogs_entry_id 从空
--     填成任何一张分录 —— 伪造一条销货成本的链。
--
-- 【为什么还要一支语句级守卫】没有写策略时,直连 UPDATE / DELETE 是【零行、不报错】
-- (SILENT-1 那一族);本守卫零行也照样触发,按名拒 SALE_THROUGH_FUNCTION_ONLY。
-- 它取代原来那支 enforce_write_permission('module.finance.edit') —— 那支会让财务过关,
-- 再被 RLS 静默吞掉。属主路径(row_security_active = false)一律放行。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql.

CREATE OR REPLACE FUNCTION public.guard_sales_record_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'SALE_THROUGH_FUNCTION_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_sales_record_direct_write() IS
'ROLE-1 Batch 2b:sales_records 的任何直连写(row_security_active,语句级,零行也触发)按名拒 SALE_THROUGH_FUNCTION_ONLY。写它的四支函数都是 SECURITY DEFINER;直接销售走 record_output_sale(action.direct_sale,cco)。';

-- ─── apply_assay_result
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
    PERFORM require_permission('action.apply_assay');
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
$function$
;

-- ─── apply_output_assay
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
    PERFORM require_permission('action.apply_assay');
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
$function$
;

-- ─── unapply_assay_result
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
    PERFORM require_permission('action.apply_assay');
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
$function$
;

-- ─── preview_assay_price
CREATE OR REPLACE FUNCTION public.preview_assay_price(p_inbound_batch_id uuid, p_metals jsonb, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
BEGIN
    PERFORM require_permission('action.apply_assay');
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        RETURN jsonb_build_object('calc', NULL, 'impact', NULL);
    END IF;

    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), p_metals, v_batch.quantity, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 净值 ≤ 0 时不试算:apply_assay_result 那时也不定价(落含量、记 note),
    -- 【这是警告不是拒绝】—— 页面的琥珀提示照旧,按钮保持可用。
    IF v_unit > 0 THEN
        -- 计价口径是 USD/kg(行情与处理费都按 USD/吨),提交也是按 USD 递给
        -- reprice_inbound_batch 的 —— 币种在这里说出来,两边才对得上。
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit, 'USD');
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;

-- ─── preview_apply_output_assay
CREATE OR REPLACE FUNCTION public.preview_apply_output_assay(p_output_batch_id uuid, p_assay_result_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_assay   record;
    v_batch   record;
    v_run     record;
    v_current jsonb;
    v_next    jsonb := NULL;
BEGIN
    -- 试算给要按"应用"的人看 —— 权限同 apply_output_assay
    PERFORM require_permission('action.apply_assay');

    SELECT * INTO v_batch FROM output_batches
    WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF p_assay_result_id IS NOT NULL THEN
        SELECT * INTO v_assay FROM assay_results
        WHERE id = p_assay_result_id AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
        END IF;
        -- 与 apply_output_assay 同一串拒绝,同一串码(试算在应用会拒的地方同样拒)
        IF v_assay.output_batch_id IS NULL THEN
            RAISE EXCEPTION 'ASSAY_IS_INBOUND|%', v_assay.code;
        END IF;
        IF v_assay.output_batch_id <> p_output_batch_id THEN
            -- 挂在别的产出批上:对这个批次而言它不存在
            RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', v_assay.code;
        END IF;
        IF v_assay.applied_at IS NOT NULL THEN
            RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
        END IF;

        SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct)
                         ORDER BY arm.metal)
        INTO v_next
        FROM assay_result_metals arm
        WHERE arm.assay_result_id = p_assay_result_id;
    END IF;

    -- 当前含量,带出处 —— "被顶掉的是谁说的数"是这个预览存在的一半理由
    SELECT jsonb_agg(jsonb_build_object(
               'metal', obm.metal,
               'content_pct', obm.content_pct,
               'content_source', obm.content_source,
               'source_assay_code', src.code)
           ORDER BY obm.metal)
    INTO v_current
    FROM output_batch_metals obm
    LEFT JOIN assay_results src ON src.id = obm.source_assay_id
    WHERE obm.output_batch_id = p_output_batch_id;

    -- 产出它的加工单与过期后果。谓词与过期视图第六源同一条判断
    -- (metal_value 限定);fixture 54 的 I/D 臂把两者钉在一起。
    SELECT r.id, r.code, r.allocated_at, r.allocation_basis INTO v_run
    FROM processing_outputs po
    JOIN processing_runs r ON r.id = po.run_id AND r.deleted_at IS NULL
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'batch_code', v_batch.code,
        'current_metals', COALESCE(v_current, '[]'::jsonb),
        'assay_metals', v_next,
        'producing_run_id', v_run.id,
        'producing_run_code', v_run.code,
        'producing_run_allocated_at', v_run.allocated_at,
        'producing_run_basis', v_run.allocation_basis,
        'will_flag_stale', v_run.allocated_at IS NOT NULL
                           AND v_run.allocation_basis = 'metal_value'
    );
END;
$function$
;

-- ─── record_output_sale
CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_price_source text DEFAULT NULL::text, p_price_provenance jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_base    numeric;
    v_movement_ids  uuid[];
    v_available     numeric;
    v_held          numeric;
    v_committed     numeric;
    v_sale_id       uuid;
    v_sale_date     date;
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
    PERFORM require_permission('action.direct_sale');
    IF p_sale_date IS NULL THEN
        RAISE EXCEPTION 'SALE_DATE_REQUIRED';
    END IF;
    v_sale_date := p_sale_date;
    SELECT deleted_at, remaining_qty, code INTO v_deleted, v_remaining, v_code
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    -- IOD-1:【可卖的是"可用",不是"物理剩余"】。被扣住的货仍在这批里,
    -- 但它不可动用 —— 所以拒绝必须同时说出两个数,否则人看着 remaining 够
    -- 却卖不掉,屏幕上没有任何东西解释为什么。
    -- SO-2:第三个桶,同一条理由 —— 【一个说不出 committed 的拒绝,会让人
    -- 看着"可用 0、暂扣 0"却卖不掉】,而真正的答案是"它许给了某张订单"。
    -- 消息里因此有三个数;哪一张订单由订单页与批次面板的预留清单回答。
    -- 【这一刀不从 committed 里卖】:发货消耗归 cut 4,它会带着订单行一起来。
    v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'available'), 0);
    v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                        WHERE output_batch_id = p_output_batch_id
                          AND stock_status = 'on_hold'), 0);
    v_committed := COALESCE((SELECT sum(qty_delta) FROM inventory_movements
                             WHERE output_batch_id = p_output_batch_id
                               AND stock_status = 'committed'), 0);
    IF p_quantity > v_available THEN
        RAISE EXCEPTION 'IOD_SALE_EXCEEDS_AVAILABLE|%|%|%|%',
            p_quantity, v_available, v_held, v_committed;
    END IF;

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【交易日】的行方买入价(tt_buy)估值 ——
    -- 收入与应收是我们将来要【卖给银行】的外币。当日无牌价即拒(FX_RATE_MISSING),
    -- 不许悄悄用最近一天的。汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, v_sale_date, 'tt_buy');
    v_amount_base := round(p_quantity * p_unit_price * v_fx, 2);

    -- ── SAL-B:信用管控 —— 拦截【暂放在这里】,等销售订单存在就搬到下单处 ──────
    -- (docs/sales-scoping.md §6/§8:quote 无处挂、order 未建、发货是今天唯一的
    -- 咽喉。搬,不要在订单上再加第二道检查 —— 两道检查就是两份会漂的实现。)
    IF p_customer_id IS NOT NULL THEN
        DECLARE
            v_hold  boolean;
            v_limit numeric;
            v_cust_code text;
            v_exposure numeric;
        BEGIN
            SELECT credit_hold, credit_limit_base, code
            INTO v_hold, v_limit, v_cust_code
            FROM customers WHERE id = p_customer_id;
            -- 人工冻结:无论敞口多少都停发(争议发票时停货不是算术条件)
            IF v_hold THEN
                RAISE EXCEPTION 'CREDIT_HOLD|%', v_cust_code;
            END IF;
            -- 【NULL = 没设限额(放行);0 = 现款现货(任何赊销都拒)—— 相反,不是相近】
            -- 把 NULL 当 0 用会拒掉全部既有客户的销售;fixture 39A 两头钉死。
            IF v_limit IS NOT NULL THEN
                v_exposure := customer_ar_exposure_base(p_customer_id);
                -- 【本位币比较】,与审批阈值同理:单据币种比较会让 USD 客户越过
                -- SGD 客户越不过的限额(fixture 39B 用同一个判别形状钉住)
                IF v_exposure + v_amount_base > v_limit THEN
                    -- 【把数字说全】:限额、当前敞口、这一单 —— 只说"超限"等于
                    -- 让人去手算系统已经知道的三个数
                    RAISE EXCEPTION 'CREDIT_LIMIT_EXCEEDED|%|%|%|%',
                        v_cust_code, v_limit, v_exposure, v_amount_base;
                END IF;
            END IF;
        END;
    END IF;

    -- IOD-1:出货走 drain_stock —— 一次销售可能跨几个库位桶,于是写出【多行】流水。
    -- 顺序与规则收在 drain_stock 一处(见其函数头),销售这一层只说"拿这么多出来"。
    -- 【SO-2b:腿在 sales_record_movements 里,一条一行】此前这里把 v_movement_ids[1]
    -- 记进单值外键 sales_records.movement_id —— 一个列装不下多条腿,于是那一列一直
    -- 在说半句真话(而且"第一条"只是排空顺序上碰巧排在前面的那条,没有任何业务
    -- 含义)。那一列已经 DROP;下面按 drain_stock 返回的每一个 uuid 写一行腿。
    v_movement_ids := drain_stock(
        p_qty => p_quantity, p_movement_type => 'sale', p_business_date => v_sale_date,
        p_output_batch_id => p_output_batch_id, p_statuses => ARRAY['available'],
        p_notes => p_notes, p_created_by => v_user);

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    -- SAL-A(FIN-26 的卖方半边):出处是【记录】,不是从公式在不在推断。
    -- computed 必带依据;manual/NULL 不留依据 —— 空白好过编造。
    IF p_price_source IS NOT NULL AND p_price_source NOT IN ('computed', 'manual') THEN
        RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%', p_price_source;
    END IF;
    IF p_price_source = 'computed' AND (p_price_provenance IS NULL OR jsonb_typeof(p_price_provenance) <> 'object') THEN
        RAISE EXCEPTION 'PROVENANCE_REQUIRED';
    END IF;

    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, created_by, price_source, price_provenance)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_base, v_sale_date, p_notes, v_user,
            p_price_source,
            CASE WHEN p_price_source = 'computed' THEN p_price_provenance END)
    RETURNING id INTO v_sale_id;

    -- SO-2b:【一条腿一行】—— drain_stock 返回几个 uuid 就写几行。
    INSERT INTO sales_record_movements (sales_record_id, movement_id)
    SELECT v_sale_id, x FROM unnest(v_movement_ids) x;
    -- 【断言,不是假设】腿的条数必须等于 drain 返回的条数。一条都不能少:
    -- 少一条,这笔销售在台账上就有一段出库没有主人,而屏幕上什么都不会变
    -- (那正是被 DROP 掉的那一列十几周里一直在做的事)。
    IF (SELECT count(*) FROM sales_record_movements WHERE sales_record_id = v_sale_id)
       <> array_length(v_movement_ids, 1) THEN
        RAISE EXCEPTION 'SALE_LEGS_LOST|%|%', array_length(v_movement_ids, 1),
            (SELECT count(*) FROM sales_record_movements WHERE sales_record_id = v_sale_id);
    END IF;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_base 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_base INTO v_unit_cost
    FROM processing_outputs po
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    IF v_unit_cost IS NOT NULL THEN
        v_cogs := round(p_quantity * v_unit_cost, 2);
        IF v_cogs <> 0 THEN
            v_je2 := post_journal_entry(
                v_sale_date,
                'COGS ' || v_code,
                'sale', v_sale_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
        END IF;
    END IF;

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_base', v_amount_base,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$

;

-- ─── upsert_metal_prices
CREATE OR REPLACE FUNCTION public.upsert_metal_prices(p_price_date date, p_prices jsonb, p_price_index text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_source_reference text DEFAULT NULL::text, p_quote_delayed boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_el       jsonb;
    v_metal    text;
    v_raw      text;
    v_price    numeric;
    v_inserted integer := 0;
    v_updated  integer := 0;
    v_skipped  integer := 0;
    v_was_ins  boolean;
BEGIN
    PERFORM require_permission('action.metal_prices');
    -- METAL-2:录入的是【哪个指数】的行情。NULL = 未声明(老序列),它是一个
    -- 可表示的状态而不是默认值 —— 界面上是一个必须选的下拉,而不是留空就当某个值。
    IF p_price_index IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM metal_price_indices WHERE code = p_price_index AND is_active) THEN
        RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', p_price_index;
    END IF;
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;

    -- LME-1a:【出处必填,而且按名拒】p_source 有 DEFAULT NULL 只是为了不打断
    -- 既有调用方的参数写法 —— 它【不是】一个可以省略的参数,漏了就在这里停下。
    -- 表上那条 NOT NULL(已拿掉 DEFAULT)是兜底:它挡得住绕过本函数的直插,
    -- 但抛出来的是约束原文;这一句是给人看的那一版。
    IF p_source IS NULL OR btrim(p_source) = '' THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_REQUIRED';
    END IF;
    IF p_source NOT IN ('published_index','broker_quote','internal_estimate','unknown') THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_INVALID|%', p_source;
    END IF;
    -- 【unknown 不许用在新录入上】它是给 LME-1a 之前那些无从考证的历史行的。
    -- 允许新录入选 unknown,等于把这一列变回一句空话 —— 只是换了个词。
    IF p_source = 'unknown' THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW';
    END IF;
    -- 【published_index 必须说得出是哪一个】表上有同样的 CHECK;这一句先说人话。
    IF p_source = 'published_index' AND p_price_index IS NULL THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_INDEX_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        -- PROC-CLEANUP:【现读字典】。这里原本写死七个码 —— 那是 PROC-4 漏掉的三份之一。
        -- PROC-4 报的"残留 0"只对【约束】成立,它的 S1 没有查函数体。
        -- 后果是具体的:往 substances 加一行之后,外键放行,而这里按 METAL_INVALID 拒 ——
        -- 于是"加一种物质 = 加一行"这句承诺,在这条路上不成立。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;

        -- 空值跳过而不是报错:UI 的每日录入表单常常只填了其中几个金属。
        v_raw := v_el->>'price_usd_per_tonne';
        IF v_raw IS NULL OR btrim(v_raw) = '' THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        v_price := v_raw::numeric;
        IF v_price IS NULL OR v_price <= 0 THEN
            RAISE EXCEPTION 'PRICE_INVALID|%|%', v_metal, v_raw;
        END IF;

        -- (metal, price_date) 唯一。软删的行也占着这个位置 —— 撞上就顺手复活它
        -- (deleted_at = NULL)并写入新价,这两种情形都算 updated。
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source,
                                  source_reference, quote_delayed, created_by, updated_by)
        VALUES (v_metal, v_price, p_price_date, p_price_index, p_source,
                nullif(btrim(coalesce(p_source_reference,'')), ''), p_quote_delayed, v_user, v_user)
        ON CONFLICT (metal, price_date, price_index) DO UPDATE
        SET price_usd_per_tonne = EXCLUDED.price_usd_per_tonne,
            source              = EXCLUDED.source,
            source_reference    = EXCLUDED.source_reference,
            quote_delayed       = EXCLUDED.quote_delayed,
            deleted_at          = NULL,
            updated_by          = v_user
        RETURNING (xmax = 0) INTO v_was_ins;

        IF v_was_ins THEN
            v_inserted := v_inserted + 1;
        ELSE
            v_updated := v_updated + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'price_date', p_price_date,
        'price_index', p_price_index,
        'source', p_source,
        'inserted', v_inserted,
        'updated', v_updated,
        'skipped', v_skipped
    );
END;
$function$;

-- ── 3 · 合同与七张条款表:写权换到 action.contract_terms(Q12 · Q1)───────────
DROP POLICY "contracts insert by owner permission" ON public.contracts;
CREATE POLICY "contracts insert by owner permission"
    ON public.contracts AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP POLICY "contracts update by owner permission" ON public.contracts;
CREATE POLICY "contracts update by owner permission"
    ON public.contracts AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP TRIGGER enforce_write_permission ON public.contracts;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contracts
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');
DROP POLICY "contract grade specs write by owner permission" ON public.contract_grade_specs;
CREATE POLICY "contract grade specs write by owner permission"
    ON public.contract_grade_specs AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP TRIGGER enforce_write_permission ON public.contract_grade_specs;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_grade_specs
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');
DROP POLICY "contract insurance write by owner permission" ON public.contract_insurance_obligations;
CREATE POLICY "contract insurance write by owner permission"
    ON public.contract_insurance_obligations AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP TRIGGER enforce_write_permission ON public.contract_insurance_obligations;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_insurance_obligations
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');
DROP POLICY "contract penalty elements write by owner permission" ON public.contract_penalty_elements;
CREATE POLICY "contract penalty elements write by owner permission"
    ON public.contract_penalty_elements AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP TRIGGER enforce_write_permission ON public.contract_penalty_elements;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_penalty_elements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');
DROP POLICY "contract pricing terms write by owner permission" ON public.contract_pricing_terms;
CREATE POLICY "contract pricing terms write by owner permission"
    ON public.contract_pricing_terms AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP TRIGGER enforce_write_permission ON public.contract_pricing_terms;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_pricing_terms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');
DROP POLICY "contract refining charges write by owner permission" ON public.contract_refining_charges;
CREATE POLICY "contract refining charges write by owner permission"
    ON public.contract_refining_charges AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP TRIGGER enforce_write_permission ON public.contract_refining_charges;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_refining_charges
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');
DROP POLICY "contract settlement terms write by owner permission" ON public.contract_settlement_terms;
CREATE POLICY "contract settlement terms write by owner permission"
    ON public.contract_settlement_terms AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP TRIGGER enforce_write_permission ON public.contract_settlement_terms;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_settlement_terms
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');
DROP POLICY "contract volume write by owner permission" ON public.contract_volume_commitments;
CREATE POLICY "contract volume write by owner permission"
    ON public.contract_volume_commitments AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.contract_terms'::text))
    WITH CHECK (has_permission('action.contract_terms'::text));
DROP TRIGGER enforce_write_permission ON public.contract_volume_commitments;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_volume_commitments
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');

-- ── 4 · 金属行情、指数、指数交易日历、报价阈值:写权换到 action.metal_prices(Q13)──
DROP POLICY "metal_prices insert by permission" ON public.metal_prices;
CREATE POLICY "metal_prices insert by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.metal_prices'::text));
DROP POLICY "metal_prices update by permission" ON public.metal_prices;
CREATE POLICY "metal_prices update by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.metal_prices'::text)) WITH CHECK (has_permission('action.metal_prices'::text));
DROP POLICY "metal_prices delete by permission" ON public.metal_prices;
CREATE POLICY "metal_prices delete by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.metal_prices'::text));
DROP TRIGGER enforce_write_permission ON public.metal_prices;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.metal_prices
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.metal_prices');
DROP POLICY "metal_price_indices write by permission" ON public.metal_price_indices;
CREATE POLICY "metal_price_indices write by permission"
    ON public.metal_price_indices AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.metal_prices'))
    WITH CHECK (has_permission('action.metal_prices'));
DROP TRIGGER enforce_write_permission ON public.metal_price_indices;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.metal_price_indices
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.metal_prices');
DROP POLICY "index market calendar write by pricing permission" ON public.index_market_calendar;
CREATE POLICY "index market calendar write by pricing permission"
    ON public.index_market_calendar AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('action.metal_prices'::text))
    WITH CHECK (has_permission('action.metal_prices'::text));
DROP TRIGGER enforce_write_permission ON public.index_market_calendar;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.index_market_calendar
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.metal_prices');
DROP POLICY "pricing_settings update by permission" ON public.pricing_settings;
CREATE POLICY "pricing_settings update by permission"
    ON public.pricing_settings AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.metal_prices'))
    WITH CHECK (has_permission('action.metal_prices'));
DROP TRIGGER enforce_write_permission ON public.pricing_settings;
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.pricing_settings
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.metal_prices');

-- ── 5 · sales_records:没有直连写(Q14 · Q3)────────────────────────────────────
DROP POLICY "sales_records insert by permission" ON public.sales_records;
DROP POLICY "sales_records update by permission" ON public.sales_records;
DROP TRIGGER enforce_write_permission ON public.sales_records;
CREATE TRIGGER trg_sales_records_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.sales_records
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_sales_record_direct_write();

-- ── 6 · 化验的两扇侧门(Q4)────────────────────────────────────────────────
CREATE TRIGGER trg_assay_results_applied_columns
    BEFORE INSERT OR UPDATE ON public.assay_results
    FOR EACH ROW EXECUTE FUNCTION public.guard_assay_applied_columns();
CREATE TRIGGER trg_inbound_batch_metals_assay_source
    BEFORE INSERT OR UPDATE ON public.inbound_batch_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_metals_assay_source();
CREATE TRIGGER trg_output_batch_metals_assay_source
    BEFORE INSERT OR UPDATE ON public.output_batch_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_metals_assay_source();

-- ── 7 · 授权 ─────────────────────────────────────────────────────────────────
-- cco:合同条款与直接销售;finance:金属行情(交出 pricing.edit);cto:应用化验(交出 pricing.edit)。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('cco', 'action.contract_terms'), ('cco', 'action.direct_sale'),
               ('finance', 'action.metal_prices'), ('cto', 'action.apply_assay')) g(role_code, c)
    ON g.role_code = r.code;
DELETE FROM role_permissions rp USING roles r
 WHERE r.id = rp.role_id AND r.code IN ('finance', 'cto') AND rp.permission_code = 'module.pricing.edit';
-- admin:Tim 的常设裁定 —— 持每一个码,含本刀四个与 Batch 2a 三个。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, c FROM roles r
 CROSS JOIN unnest(ARRAY['action.contract_terms', 'action.metal_prices', 'action.direct_sale', 'action.apply_assay',
                         'action.finance_settings', 'action.customer_credit', 'action.supplier_approve']) c
 WHERE r.code = 'admin'
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 8 · 每一张在途单据,有几个【不是它自己当事人】的人决定得了它 ──────────────
-- 零件与 ROLE-1 Batch 1 / 2a 的自证逐字相同(按【人】数,Tim 的两个账号只算一个);本刀没有改动
-- 任何一支决定函数的门,所以用"之后"那一组门问。
CREATE FUNCTION pg_temp.b2b_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      LEFT JOIN holds h ON 'module.processing.edit' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      LEFT JOIN holds h ON 'module.stocktakes.edit' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
     WHERE s.status = 'open' AND s.deleted_at IS NULL
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE b2b_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');

-- ── 9 · 自证:同一笔事务里,失败即整笔回滚 ────────────────────────────────────
DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
    v_admin_2a int;
BEGIN
    -- ① 授权 = 之前 + 本刀的授权 − 两条收回,不多不少
    --    (admin 的 Batch 2a 三码是否新加,取决于 Tim 有没有手工加过:两种都接受)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT
         SELECT role_code || ':' || permission_code FROM b2b_grants_before)
        EXCEPT
        SELECT unnest(ARRAY['cco:action.contract_terms', 'cco:action.direct_sale', 'finance:action.metal_prices',
                            'cto:action.apply_assay',
                            'admin:action.contract_terms', 'admin:action.metal_prices', 'admin:action.direct_sale',
                            'admin:action.apply_assay', 'admin:action.finance_settings', 'admin:action.customer_credit',
                            'admin:action.supplier_approve'])
    ) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2B_PROOF|unexpected grant: %', v_bad; END IF;
    SELECT count(*) INTO v_admin_2a FROM b2b_grants_before
     WHERE role_code = 'admin' AND permission_code IN ('action.finance_settings', 'action.customer_credit',
                                                       'action.supplier_approve');
    SELECT count(*) INTO v_n FROM (
        SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
        EXCEPT SELECT role_code || ':' || permission_code FROM b2b_grants_before) d;
    IF v_n <> 8 + (3 - v_admin_2a) THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|expected % new grants, got %', 8 + (3 - v_admin_2a), v_n;
    END IF;
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        SELECT role_code || ':' || permission_code AS x FROM b2b_grants_before
        EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id) d;
    IF v_bad IS DISTINCT FROM 'cto:module.pricing.edit, finance:module.pricing.edit' THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|removed grants are not exactly the two pricing.edit: %', v_bad;
    END IF;

    -- ② admin 缺的码只可能是它本来就缺的(Tim 的常设裁定:admin【保留】它的全部码,并拿到每一个
    --    新码)。试跑量到:admin 从来没有 module.tasks.view_all(读别人的个人任务;Tim 2026-09-23
    --    23:33 还回去的 45 个码里就没有它)—— 本刀不替 Tim 加它,只断言它没有再多缺一个。
    SELECT string_agg(p.code, ', ' ORDER BY p.code) INTO v_bad FROM permissions p
     WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                        WHERE r.code = 'admin' AND rp.permission_code = p.code)
       AND (p.code IN ('action.contract_terms', 'action.metal_prices', 'action.direct_sale', 'action.apply_assay',
                       'action.finance_settings', 'action.customer_credit', 'action.supplier_approve')
            OR EXISTS (SELECT 1 FROM b2b_grants_before b WHERE b.role_code = 'admin' AND b.permission_code = p.code));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2B_PROOF|admin lacks: %', v_bad; END IF;

    -- ③ 定价公式只剩 cco 与 admin(加两个无人持有的角色,Q2)
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'module.pricing.edit';
    IF v_bad IS DISTINCT FROM 'admin cco procurement sales' THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|pricing.edit holders are %', v_bad;
    END IF;

    -- ④ edit 蕴含 view
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE 'module.%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id
                        AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B2B_PROOF|edit without view: %', v_bad; END IF;

    -- ⑤ 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|approvals switched off';
    END IF;

    -- ⑥ 在途单据一张不少、一张不多;留痕与分录一行没多;业务行一行没变
    IF EXISTS ((SELECT b.k, b.id FROM b2b_pending_before b EXCEPT SELECT a.k, a.id FROM b2b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b2b_pending_after a EXCEPT SELECT b.k, b.id FROM b2b_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT (approval_log, journal_entries, contracts, metal_prices, indices, sales_records, assays, assays_applied)
          FROM b2b_counts_before)
       IS DISTINCT FROM
       (SELECT ((SELECT count(*) FROM approval_log), (SELECT count(*) FROM journal_entries),
                (SELECT count(*) FROM contracts), (SELECT count(*) FROM metal_prices),
                (SELECT count(*) FROM metal_price_indices), (SELECT count(*) FROM sales_records),
                (SELECT count(*) FROM assay_results),
                (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL))) THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|a business row count changed';
    END IF;

    -- ⑦ sales_records 不再有任何写策略
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'sales_records'
                AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|sales_records still has a write policy';
    END IF;

    -- ⑧ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b2b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B2B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b2b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B2B_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b2b_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b2b_pending_decider_check(boolean);

COMMIT;

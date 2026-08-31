-- db/migrations/2026-09-01-eqppay1-b-fu3-a-machine-can-be-ordered-with-or-without-retention.sql
-- EQP-PAY-1 fu3:质保金随【下单】一起落地,而"没有质保金"仍然是【没有那一行】。
--
-- 【为什么不做成建完单之后再补一刀】质保金是付款条款的一部分。分成两次调用,
-- 第二次失败就会留下一张【条款不全】的采购单 —— 而它在屏幕上看起来完全正常。
-- 放进同一支函数,它与单据同生共死。
--
-- ★【可选性是结构性的,这一支没有把它变软】★ 负载里没有 retention 这一键就不建行;
-- 而表上那条 CHECK 是 percentage > 0,所以一行 0% 【存不进去】。
-- "没有质保金"与"0% 质保金"连长得一样的机会都没有(db/fixtures/175 的 A 臂断言这一条)。

BEGIN;

CREATE OR REPLACE FUNCTION public.create_purchase_order(p_supplier_id uuid, p_order_date date, p_expected_delivery date, p_currency text, p_fx_rate numeric, p_incoterm text, p_terms_text text, p_notes text, p_lines jsonb, p_payment_terms jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- APR-2c:审批生效与否决定这张单生为什么状态。三态见迁移文件头。
    v_appr_on    boolean := approvals_enabled();
    v_user       uuid := auth.uid();
    v_date       date;
    v_fx         numeric;
    v_po_id      uuid := gen_random_uuid();
    v_code       text;
    v_line       jsonb;
    v_line_no    integer;
    v_line_id    uuid;      -- FIN-27:承诺挂在行上,需要它的 id
    v_qty        numeric;
    v_price      numeric;
    v_src          text;      -- FIN-26:computed / manual / NULL(旧调用方)
    v_prov         jsonb;     -- FIN-26:computed 行的重导出依据
    v_amount     numeric;
    v_material   uuid;
    v_asset       uuid;
    v_formula    uuid;
    v_f          record;
    v_total      numeric := 0;
    v_count      integer := 0;
    v_committed  integer := 0;  -- FIN-27:抄下条款的行数
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer := 0;
    v_pct_total  numeric := 0;
    v_term_count integer := 0;
    v_retentions integer := 0;
    -- ── EQP-PAY-1 ──────────────────────────────────────────────────────────
    -- A2:混装单在门上【先】拒一次。计数而不是布尔,好让参数形状与既有那道
    -- guard_po_lines_single_kind 逐字相同(|单号|材料行数|设备行数)。
    v_n_material integer := 0;
    v_n_asset    integer := 0;
    v_kind       text;              -- 'equipment' / 'material'
    v_applicable boolean;           -- R5:这一期的里程碑用不用得上
    v_ret        jsonb;              -- R6:这条设备行的质保金(可选 —— 没有就【没有这一行】)
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    IF p_order_date IS NULL THEN
        RAISE EXCEPTION 'ORDER_DATE_REQUIRED';
    END IF;
    v_date := p_order_date;
    IF p_supplier_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;

    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【下单日】的行方卖出价(tt_sell)估值。
    -- 当日无牌价即拒 —— 这也逼着牌价当天录入(隔天可能就查不到了)。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_order_date, 'tt_sell');

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_code := next_purchase_order_code(v_date);

    INSERT INTO purchase_orders (id, code, supplier_id, order_date, expected_delivery_date,
                                 currency, fx_rate, estimated_total_ccy, status,
                                 approval_status, approved_at, approved_by,
                                 incoterm, terms_text, notes, created_by, updated_by)
    VALUES (v_po_id, v_code, p_supplier_id, v_date, p_expected_delivery,
            -- APR-2:新单【生为 draft/pending】—— 此前是 confirmed/approved,
            -- 于是"提单人发起"根本无处可放。批准把它推到 confirmed。
            p_currency, v_fx, 0,
            -- APR-2c:审批生效 → draft/pending,等人批;审批未生效 → 直接 confirmed/approved,
            -- 而【界面会明说审批未生效】,不是悄悄放行。两者都不是默认值,是一个被声明的状态。
            CASE WHEN v_appr_on THEN 'draft'   ELSE 'confirmed' END,
            CASE WHEN v_appr_on THEN 'pending' ELSE 'approved'  END,
            CASE WHEN v_appr_on THEN NULL ELSE now() END,
            CASE WHEN v_appr_on THEN NULL ELSE v_user END,
            p_incoterm, p_terms_text, p_notes, v_user, v_user);

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;
        v_line_no := COALESCE((v_line->>'line_no')::integer, v_count);
        v_material := (v_line->>'material_id')::uuid;
        -- EQP-1a:设备行 —— 引用一张【已经存在】的资产卡,行不创建资产
        v_asset := (v_line->>'asset_id')::uuid;
        v_qty := (v_line->>'quantity')::numeric;
        v_price := (v_line->>'estimated_unit_price')::numeric;
        v_formula := (v_line->>'pricing_formula_id')::uuid;

        -- EQP-1a:恰一非空 —— 与表上那条 CHECK 同一句话,在这里【先】说一遍,
        -- 好让走门的人拿到一个具名拒绝而不是一条约束原文。
        IF num_nonnulls(v_material, v_asset) <> 1 THEN
            RAISE EXCEPTION 'PO_LINE_KIND_INVALID|%', v_line_no
              USING HINT = '一行要么订材料、要么订一台已建卡的设备,不能都给、也不能都不给';
        END IF;

        -- ── EQP-PAY-1(A2):混装单,在门上先拒一次 ────────────────────────
        -- 【这不是第二份实现】表上那道 trg_po_lines_single_kind(EQP-1a)是
        -- DEFERRABLE INITIALLY DEFERRED —— 它在 COMMIT 那一刻才炸,那时整张单
        -- 已经建完了。这里在插入第二种行的【那一刻】就拒,并且说得出该怎么办。
        -- 错误码与参数形状与那一道【逐字相同】:一条规矩只能有一个码,
        -- 否则屏幕上会有一半的拒绝印出裸码。
        IF v_material IS NOT NULL THEN v_n_material := v_n_material + 1; END IF;
        IF v_asset    IS NOT NULL THEN v_n_asset    := v_n_asset    + 1; END IF;
        IF v_n_material > 0 AND v_n_asset > 0 THEN
            RAISE EXCEPTION 'PO_LINES_MIXED_KINDS|%|%|%', v_code, v_n_material, v_n_asset
              USING HINT = '一张采购单要么全是材料行、要么全是设备行 —— 请开两张单:一张订料,一张订机器。两者的收货路径、成本处理与付款里程碑都不同';
        END IF;

        IF v_material IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_material AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(v_material::text, '?');
        END IF;
        IF v_asset IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM fixed_assets WHERE id = v_asset
        ) THEN
            RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(v_asset::text, '?');
        END IF;
        -- EQP-1a-TAIL:设备行的 quantity 与 unit 【省略即给默认,给错则按名拒】。
        -- 只给默认不够 —— 一个明确传了 quantity = 5 的调用方会通过下面那条
        -- "> 0" 的校验,然后撞上一条【裸的约束违例】,而屏幕上永不出现裸码。
        IF v_asset IS NOT NULL THEN
            IF v_qty IS NULL THEN v_qty := 1; END IF;
            IF v_qty <> 1 THEN
                RAISE EXCEPTION 'PO_LINE_EQUIPMENT_QTY|%|%', v_line_no, v_qty
                  USING HINT = '一条设备行订的是【一台】机器 —— 四台是四条行,它们各有各的资产卡与投用日';
            END IF;
            IF COALESCE(v_line->>'unit', 'unit') <> 'unit' THEN
                RAISE EXCEPTION 'PO_LINE_EQUIPMENT_UNIT|%|%', v_line_no, v_line->>'unit'
                  USING HINT = '设备行的计量单位恒为 unit —— 留空即取它;填 kg 会让这台机器被加进公斤里';
            END IF;
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_INVALID|%', v_line_no;
        END IF;
        IF v_formula IS NOT NULL THEN
            SELECT id, code, is_active, deleted_at INTO v_f
            FROM pricing_formulas WHERE id = v_formula;
            IF NOT FOUND OR v_f.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_formula;
            END IF;
            IF NOT v_f.is_active THEN
                RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
            END IF;
        END IF;

        -- 没给估价就是 0:PO 是承诺,估算金额可以留白(公式定价的料常常如此)
        v_amount := CASE WHEN v_price IS NULL THEN 0 ELSE round(v_qty * v_price, 2) END;
        v_total := v_total + v_amount;

        -- ── FIN-26:价格出处 ─────────────────────────────────────────────────
        -- computed / manual 是【记录】,不是从 expected_assay 是否为空【推断】——
        -- 推断在谁改了一个字段没改另一个的那一刻就失真。computed 必带 provenance
        -- (够重新导出这个数:化验、逐金属行情与日期、汇率与取自哪天、公式当时的
        -- 参数快照 —— 公式是可编辑的,行上引用的 id 指不住当时的样子)。
        v_src  := v_line->>'price_source';
        v_prov := v_line->'price_provenance';
        IF v_src IS NOT NULL AND v_src NOT IN ('computed', 'manual') THEN
            RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%|%', v_line_no, v_src;
        END IF;
        IF v_src = 'computed' AND (v_prov IS NULL OR jsonb_typeof(v_prov) <> 'object') THEN
            RAISE EXCEPTION 'PROVENANCE_REQUIRED|%', v_line_no;
        END IF;
        IF v_src IS DISTINCT FROM 'computed' THEN
            v_prov := NULL;   -- 手填/未声明的行不留出处 —— 空白好过编造(B3)
        END IF;
        IF v_price IS NULL THEN
            v_src := NULL; v_prov := NULL;   -- 没有价就没有出处
        END IF;

        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id, quantity,
                                          unit, pricing_formula_id, estimated_unit_price,
                                          estimated_amount_ccy, expected_assay, notes, created_by,
                                          price_source, price_provenance)
        VALUES (v_po_id, v_line_no, v_material, v_asset, v_qty,
                COALESCE(v_line->>'unit', CASE WHEN v_asset IS NOT NULL THEN 'unit' ELSE 'kg' END), v_formula, v_price,
                v_amount, v_line->'expected_assay', v_line->>'notes', v_user,
                v_src, v_prov)
        RETURNING id INTO v_line_id;

        -- ── FIN-27:承诺时抄下结算条款 ───────────────────────────────────────
        -- 【与估价无关】公式定价的行下单时常常没有单价,而条款照样是谈定的 ——
        -- 有公式就抄,不看 estimated_unit_price。抄下之后,公式此后怎么改、
        -- 被停用还是被软删,都碰不到这一行的结算。
        IF v_formula IS NOT NULL THEN
            PERFORM commit_pricing_terms(v_formula, v_line_id, NULL);
            v_committed := v_committed + 1;
        END IF;

        -- ── EQP-PAY-1(R6):这条设备行的质保金 ────────────────────────────────
        -- ★【可选,而"没有"是【结构性】的】★ 负载里没有 retention 这一键,就【不建行】。
        -- 系统里因此不存在"0% 的质保金"这种东西 —— 表上那条 CHECK 是 percentage > 0,
        -- 一行 0% 存不进去。"没有质保金"与"0% 质保金"是两个不同的事实,
        -- 而这里保证它们连长得一样的机会都没有。
        --
        -- 【为什么在这支函数里,而不是建完单之后再补一刀】质保金是条款的一部分。
        -- 分成两次调用,第二次失败就会留下一张【条款不全】的单,而它看起来完全正常。
        v_ret := v_line->'retention';
        IF v_ret IS NOT NULL AND jsonb_typeof(v_ret) = 'object' THEN
            IF v_asset IS NULL THEN
                RAISE EXCEPTION 'RETENTION_NOT_AN_EQUIPMENT_LINE|%', v_line_no
                  USING HINT = '质保金是设备的事 —— 一条材料行没有验收,也就没有可以起算的锚';
            END IF;
            INSERT INTO purchase_order_line_retentions
                (purchase_order_line_id, percentage, fixed_amount_ccy, retention_months,
                 anchor_event, notes)
            VALUES (v_line_id,
                    (v_ret->>'percentage')::numeric,
                    (v_ret->>'fixed_amount_ccy')::numeric,
                    COALESCE((v_ret->>'retention_months')::integer, 12),
                    COALESCE(v_ret->>'anchor_event', 'acceptance_complete'),
                    v_ret->>'notes');
            v_retentions := v_retentions + 1;
        END IF;
    END LOOP;

    UPDATE purchase_orders SET estimated_total_ccy = v_total, updated_by = v_user
    WHERE id = v_po_id;

    -- EQP-PAY-1:行落完了,所以这张单的种类【现在】问得出来。混装已在上面拒掉,
    -- 所以这两种情形互斥。
    v_kind := CASE WHEN v_n_asset > 0 THEN 'equipment' ELSE 'material' END;

    -- 付款计划是【可选的】:有些采购就是到货即付,没有分期可言。
    IF p_payment_terms IS NOT NULL AND jsonb_typeof(p_payment_terms) = 'array'
       AND jsonb_array_length(p_payment_terms) > 0 THEN
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);

            -- ── EQP-PAY-1(R5):这一期的里程碑,在这一类单上用得上吗 ────────
            -- 【此前这里一个字都不校验】—— 直接 INSERT,让表上的 CHECK 去炸,
            -- 于是屏幕上拿到的是一条裸约束原文。现在先按名拒。
            SELECT CASE WHEN v_kind = 'equipment' THEN applies_to_equipment
                        ELSE applies_to_material END
            INTO v_applicable
            FROM payment_trigger_events WHERE code = v_term->>'trigger_event';

            IF v_applicable IS NULL THEN
                RAISE EXCEPTION 'TERMS_EVENT_UNKNOWN|%|%', v_seq, COALESCE(v_term->>'trigger_event', '?')
                  USING HINT = '不认识这一种付款里程碑 —— 可选的种类是 payment_trigger_events 里的行';
            END IF;
            IF NOT v_applicable THEN
                RAISE EXCEPTION 'PO_TERM_EVENT_NOT_APPLICABLE|%|%|%|%',
                    v_code, v_seq, v_term->>'trigger_event', v_kind
                  USING HINT = '这一种里程碑在这一类采购单上用不上 —— 一台机器永远不会被化验(post_assay)。可选的种类见 payment_trigger_events 的适用性两列';
            END IF;

            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                                      fixed_amount_ccy, trigger_event, due_date, notes)
            VALUES (v_po_id, v_seq, v_term->>'label',
                    (v_term->>'percentage')::numeric,
                    (v_term->>'fixed_amount_ccy')::numeric,
                    v_term->>'trigger_event',
                    (v_term->>'due_date')::date,
                    v_term->>'notes');
            v_term_count := v_term_count + 1;
        END LOOP;

        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;
    END IF;

    -- APR-2:提单即留痕。级别留空 —— 级别是【审批当时】按金额算出来的,
    -- 提单时算出来存下就是一个会过期的副本。
    -- 审批生效时这是一次【提交】;未生效时没有人做过决定,记 auto_approved ——
    -- 与 APR-1 回填那三张旧单同一个词,理由也同一个:记录真实发生的事,不要把
    -- "系统直接盖章"伪装成一次人的决定。
    IF v_appr_on THEN
        PERFORM record_approval_decision('purchase_order', v_po_id, 'submitted', NULL, NULL);
    ELSE
        PERFORM record_approval_decision('purchase_order', v_po_id, 'auto_approved', NULL,
            '审批流未启用(finance_settings.approvals_enabled = false)—— 系统直接盖章,没有人做过这个决定');
    END IF;

    RETURN jsonb_build_object(
        'purchase_order_id', v_po_id,
        'code', v_code,
        'estimated_total_ccy', v_total,
        'line_count', v_count,
        'committed_line_count', v_committed,
        'term_count', v_term_count,
        'retention_count', v_retentions,
        'order_kind', v_kind
    );
END;
$function$;

COMMIT;

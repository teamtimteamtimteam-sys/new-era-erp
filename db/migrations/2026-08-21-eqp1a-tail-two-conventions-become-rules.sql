-- EQP-1a-TAIL(2026-08-21):把两条【约定】变成【规则】。
--
-- 【问题】N2 的两个值(quantity = 1、unit = 'unit')此前只活在 fixture 103 里。
-- 而库里 unit 的默认值是 'kg' —— 一条省略了 unit 的设备行会【无声地变成公斤】,
-- 没有任何拒绝。**一条表单那一刀可以忘掉的约定,不是规则。**
-- N1 当初的理由正是 ordered_qty 那个不看单位的 sum(quantity);
-- 把单位留在约定层,等于把同一类缺陷留在下一层。
--
-- 【grill 对 T3 的修正 —— 报告里会说】brief 建议"省略时给默认值"。
-- 只做默认【不够】:一个【明确传了】quantity = 5 或 unit = 'kg' 的调用方,
-- 会通过 RPC 既有的校验(quantity > 0),然后撞上一条【裸的约束违例】——
-- 而本仓库的规矩是"拒绝要具名,屏幕上永不出现裸码"。
-- 所以 T3 做成两件事:【省略即给默认】+【明确给错则按名拒】。

BEGIN;

-- ── T1 / T2:两条 CHECK,分开两个名字 ────────────────────────────────────────
-- 【分开写,不合并】fixture 要按【约束名】断言两条不同的规则;
-- 合并成一条"设备行形状不对"会让两个断言指向同一个名字,分不出是哪一条坏了。
-- 【材料行逐字节不受影响】asset_id IS NULL → 恒真,那一支根本不判。
-- 线上 6 条行全是材料行、0 条设备行(实测),所以两条都可以直接 VALID 加。
ALTER TABLE public.purchase_order_lines
    ADD CONSTRAINT purchase_order_lines_equipment_qty_one
    CHECK (asset_id IS NULL OR quantity = 1);

ALTER TABLE public.purchase_order_lines
    ADD CONSTRAINT purchase_order_lines_equipment_unit
    CHECK (asset_id IS NULL OR unit = 'unit');

COMMENT ON CONSTRAINT purchase_order_lines_equipment_qty_one ON public.purchase_order_lines IS
'EQP-1a-TAIL:一条设备行订的是【一台】机器 —— quantity 恒为 1。
四台机器是四条行(或四张单),不是一条 quantity = 4 的行:它们各有各的资产卡、
各自的投用日与折旧。材料行(asset_id IS NULL)不受这条约束。';

COMMENT ON CONSTRAINT purchase_order_lines_equipment_unit ON public.purchase_order_lines IS
'EQP-1a-TAIL:设备行的计量单位恒为 ''unit''。
【这条 CHECK 存在的全部理由】unit 的列默认值是 ''kg'' —— 省略它的设备行会
无声地变成公斤,而 purchase_order_status.ordered_qty 是一个【不看单位】的
sum(quantity),于是那台机器会被加进公斤里。约定挡不住"忘了填",CHECK 挡得住。';

-- ── T3 · 两扇门:省略即给默认,给错则按名拒 ────────────────────────────────
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
    END LOOP;

    UPDATE purchase_orders SET estimated_total_ccy = v_total, updated_by = v_user
    WHERE id = v_po_id;

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
        'term_count', v_term_count
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.amend_purchase_order(p_purchase_order_id uuid, p_reason text, p_header jsonb DEFAULT NULL::jsonb, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_po       record;
    v_el       jsonb;
    v_line_id  uuid;
    v_qty      numeric;
    v_price    numeric;
    v_new_date date;
    v_fx       numeric;
    v_total    numeric;
    v_plan_fixed numeric;
    v_plan_pct   numeric;
    v_changed  integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填】一次改动没有理由,历史上就是一行"数字变了"而没有"为什么"。
        RAISE EXCEPTION 'PO_AMEND_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_po FROM purchase_orders
     WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;

    -- 【已结束 / 已作废的单不能改】先 reopen,让状态变化成为一次有记录的动作,
    -- 而不是修改的副作用。
    IF v_po.status IN ('closed','cancelled') THEN
        RAISE EXCEPTION 'PO_NOT_AMENDABLE|%|%', v_po.code, v_po.status;
    END IF;

    -- 理由传给留痕触发器(触发器读不到函数参数)
    PERFORM set_config('evoltrya.amend_reason', btrim(p_reason), true);
    PERFORM set_config('evoltrya.po_amend_ctx', '1', true);

    -- ── 表头 ────────────────────────────────────────────────────────────────
    IF p_header IS NOT NULL AND jsonb_typeof(p_header) = 'object' THEN
        v_new_date := COALESCE((p_header->>'order_date')::date, v_po.order_date);
        -- 【汇率从不由调用方递入】改单据日就要重取牌价:缺牌价即拒绝、绝不编一个。
        -- 采购是我们买外币 → tt_sell。本位币恒 1(定义,不是兜底)。
        IF v_new_date IS DISTINCT FROM v_po.order_date THEN
            IF v_po.currency = base_currency_code() THEN
                v_fx := 1;
            ELSE
                v_fx := fx_rate_for(v_po.currency, v_new_date, 'tt_sell');
            END IF;
        ELSE
            v_fx := v_po.fx_rate;
        END IF;

        UPDATE purchase_orders SET
            order_date = v_new_date,
            expected_delivery_date = CASE WHEN p_header ? 'expected_delivery_date'
                THEN (p_header->>'expected_delivery_date')::date ELSE expected_delivery_date END,
            incoterm = CASE WHEN p_header ? 'incoterm' THEN p_header->>'incoterm' ELSE incoterm END,
            terms_text = CASE WHEN p_header ? 'terms_text' THEN p_header->>'terms_text' ELSE terms_text END,
            notes = CASE WHEN p_header ? 'notes' THEN p_header->>'notes' ELSE notes END,
            fx_rate = v_fx,
            updated_by = v_user
        WHERE id = p_purchase_order_id;
    END IF;

    -- ── 明细 ────────────────────────────────────────────────────────────────
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_line_id := NULLIF(v_el->>'id', '')::uuid;

            IF COALESCE((v_el->>'remove')::boolean, false) THEN
                IF v_line_id IS NULL THEN
                    RAISE EXCEPTION 'PO_LINE_REMOVE_NEEDS_ID';
                END IF;
                -- 收过货的行删不掉 —— 守卫触发器点名拒(货真的到了,单据上却没有出处)
                DELETE FROM purchase_order_lines
                 WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                v_changed := v_changed + 1;
                CONTINUE;
            END IF;

            v_qty := (v_el->>'quantity')::numeric;
            -- EQP-1a-TAIL:设备行同一条规矩 —— 省略即给默认,给错则按名拒。
            IF (v_el->>'asset_id') IS NOT NULL THEN
                IF v_qty IS NULL THEN v_qty := 1; END IF;
                IF v_qty <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_EQUIPMENT_QTY|%|%', COALESCE(v_el->>'line_no','?'), v_qty
                      USING HINT = '一条设备行订的是【一台】机器 —— 四台是四条行';
                END IF;
                IF COALESCE(v_el->>'unit', 'unit') <> 'unit' THEN
                    RAISE EXCEPTION 'PO_LINE_EQUIPMENT_UNIT|%|%', COALESCE(v_el->>'line_no','?'), v_el->>'unit'
                      USING HINT = '设备行的计量单位恒为 unit —— 留空即取它';
                END IF;
            END IF;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'PO_LINE_QUANTITY_INVALID|%', COALESCE(v_el->>'line_no', '?');
            END IF;
            v_price := NULLIF(v_el->>'estimated_unit_price', '')::numeric;

            IF v_line_id IS NULL THEN
                -- 新增行:与建单同口径(金额 = 数量 × 单价,无价则 0)
                -- EQP-1a:改单也能加设备行 —— 恰一非空,与建单同一句话
                IF num_nonnulls((v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid) <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_KIND_INVALID|%', COALESCE(v_el->>'line_no', '?')
                      USING HINT = '一行要么订材料、要么订一台已建卡的设备,不能都给、也不能都不给';
                END IF;
                IF (v_el->>'asset_id') IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM fixed_assets WHERE id = (v_el->>'asset_id')::uuid
                ) THEN
                    RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_el->>'asset_id';
                END IF;
                INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id,
                    quantity, unit, estimated_unit_price, estimated_amount_ccy, notes, created_by)
                VALUES (p_purchase_order_id,
                    COALESCE((v_el->>'line_no')::integer,
                        (SELECT COALESCE(MAX(line_no), 0) + 1 FROM purchase_order_lines
                          WHERE purchase_order_id = p_purchase_order_id)),
                    (v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid,
                    v_qty, COALESCE(v_el->>'unit', CASE WHEN (v_el->>'asset_id') IS NOT NULL THEN 'unit' ELSE 'kg' END),
                    v_price, round(v_qty * COALESCE(v_price, 0), 2), v_el->>'notes', v_user);
            ELSE
                -- 【已收下限由触发器把关】砍到已收之下 → PO_LINE_BELOW_RECEIVED
                UPDATE purchase_order_lines SET
                    quantity = v_qty,
                    unit = COALESCE(v_el->>'unit', unit),
                    estimated_unit_price = CASE WHEN v_el ? 'estimated_unit_price'
                        THEN v_price ELSE estimated_unit_price END,
                    estimated_amount_ccy = round(v_qty * COALESCE(
                        CASE WHEN v_el ? 'estimated_unit_price' THEN v_price
                             ELSE estimated_unit_price END, 0), 2)
                WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
            END IF;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 总额:与明细【同一条语句】算完 ───────────────────────────────────────
    -- 【顺序就是要点】这一列是 APR-2 作废触发器盯着的东西。若先改行、再另起一条
    -- 语句写总额,触发器判断时依据的总额与产生它的那批行已经不是一回事 ——
    -- 那会产生一个看起来完全正常、却基于陈旧数字的审批决定。
    UPDATE purchase_orders po SET
        estimated_total_ccy = COALESCE(s.total, 0),
        updated_by = v_user
    FROM (SELECT COALESCE(SUM(estimated_amount_ccy), 0) AS total
            FROM purchase_order_lines WHERE purchase_order_id = p_purchase_order_id) s
    WHERE po.id = p_purchase_order_id;

    SELECT estimated_total_ccy INTO v_total FROM purchase_orders WHERE id = p_purchase_order_id;

    -- ── 付款计划:定额腿必须仍然加得上 ───────────────────────────────────────
    SELECT COALESCE(SUM(fixed_amount_ccy), 0), COALESCE(SUM(percentage), 0)
      INTO v_plan_fixed, v_plan_pct
      FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    IF v_plan_fixed > 0 THEN
        -- 【定额腿在场:拒绝,不缩放】一条定额腿之所以是定额,正因为有人谈的是一个
        -- 数字而不是一个比例。替它按比例缩放,就是系统替操作员重新谈了一次条款,
        -- 而没有任何人被告知(与调高信用额度让告警安静同族)。
        -- 报出三个数:订单额、计划额、差额 —— 补救归操作员,而两条路都是有记录的动作。
        DECLARE
            v_plan_total numeric :=
                v_plan_fixed + round(v_total * v_plan_pct / 100.0, 2);
        BEGIN
            IF round(v_plan_total, 2) <> round(v_total, 2) THEN
                RAISE EXCEPTION 'PO_PLAN_FIXED_MISMATCH|%|%|%',
                    round(v_total, 2), round(v_plan_total, 2),
                    round(v_plan_total - v_total, 2);
            END IF;
        END;
    END IF;
    -- 【比例计划不在此列,而且这不是遗漏】百分比的意思就是"订单的这一份",
    -- 它按构造跟着总额走;定额的意思是"这么多钱",只有它需要被拦住。

    PERFORM set_config('evoltrya.po_amend_ctx', '', true);
    PERFORM set_config('evoltrya.amend_reason', '', true);

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'lines_changed', v_changed,
        'estimated_total_ccy', v_total,
        'approval_status', (SELECT approval_status FROM purchase_orders WHERE id = p_purchase_order_id));
END;
$function$;

COMMIT;

-- LOG-4a(2026-08-20):出口运费是【费用】,不是落地成本。
--
-- Tim 已定,本迁移不再论证,只把它做成机制:
--   * 出口运费借 6300(运输物流费,expense),【永不】进 1200/5000;
--   * 复用 freight_documents,加一列 direction;出境那一支【按名拒绝】进料侧机器;
--   * 单据是钱的对象,container_id 可空;
--   * 报价的分母是【每箱】—— 只落成 forwarder_rate_quotes.amount_ccy 的列注释,不动 schema;
--   * 本刀不碰任何税形的东西。
--
-- 【LOG-3-SURVEY §3 点名的三个资本化陷阱,就是本刀要证明关上的那三个】
--   A 借方写死 1200/5000 —— 出境臂根本不走那条路径,fixture 断言【那两行不存在】;
--   B batch_freight_base → allocate_processing_costs 的材料成本 —— 出境单不许有分摊行,
--     由表上的守卫拒(不是"RPC 没提供"),所以那个求和读不到它;
--   C batch_margin 按 account_type='cogs' 汇总 —— 6300 是 expense,不是 cogs。
--
-- 【为什么是新函数,不是给 record_freight_document 加一个参数】两条,都是硬的:
--   1. 加参数 = 改签名 = 【重载】。db/preflight_migration.py 会当场拒绝
--      (FIN-21 的原样重演:旧签名原样活下去,而镜像里只有一个)。
--   2. 判据是"进料臂逐字节不动"。新函数让 record_freight_document 只多一件事:
--      INSERT 的列清单里多一个 direction,值是字面量 'inbound'。
--      没有一个 IF p_direction、没有一条分支、每一条拒绝与每一行分录原样。
--
-- 零线上行(freight_documents count = 0),所以 direction NOT NULL 不需要回填,
-- 货代守卫也不需要给任何既有行开例外 —— 这两件事今天是免费的,明天不是。

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- (a) direction —— 无默认值。看得见的默认值才不是假设(FIN-36 的判别法)。
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.freight_documents
    ADD COLUMN direction text NOT NULL
        CHECK (direction IN ('inbound','outbound'));

COMMENT ON COLUMN public.freight_documents.direction IS
    'LOG-4a:这张运费单是【进货运费】还是【出口运费】。两者【不是同一种成本】:
inbound 资本化进批次成本(借 1200/5000,分摊到进料批);outbound 是期间费用(借 6300),
永不进存货、永不进 COGS、【永远没有分摊行】(freight_allocations 上的守卫按名拒)。
没有 schema 默认值 —— 一个默认成 inbound 的出口运费会安静地钻进存货,
而那正是 docs/landed-cost-scoping.md 说的"看不见的错误"。';

COMMENT ON COLUMN public.forwarder_rate_quotes.amount_ccy IS
    'LOG-4a:分母是【每一个集装箱】(Tim 定)。这一列不带单位列,是因为单位是一条
【决定】而不是一个字段:改成每票或每重量单位,要动的是这条决定与随之而来的比较口径,
不是给这张表加一列。实际运费与它的比较在 LOG-4b 之后才成立 —— 那时读的仍是这个分母。';

-- ════════════════════════════════════════════════════════════════════════════
-- (c) 货代守卫 —— 关掉 FRT-1 / LOG-1a 之间的时间差。
--     containers.forwarder_id 与 forwarder_rate_quotes.supplier_id 早就有这条守卫,
--     【唯独运费单没有】—— FRT-1 早于 counterparty_type,那是时间差,不是决定。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_freight_document_forwarder()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_type text; v_code text;
BEGIN
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.supplier_id;
    IF v_type IS DISTINCT FROM 'forwarder' THEN
        RAISE EXCEPTION 'FREIGHT_SUPPLIER_NOT_A_FORWARDER|%', COALESCE(v_code, NEW.supplier_id::text)
          USING HINT = '运费的对手方只能是货代 —— 记到材料供应商名下,分录照样是平的,而钱记在了错的人头上';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_freight_documents_forwarder
    BEFORE INSERT OR UPDATE OF supplier_id ON public.freight_documents
    FOR EACH ROW EXECUTE FUNCTION public.guard_freight_document_forwarder();

-- ════════════════════════════════════════════════════════════════════════════
-- (b·守卫) 出境单据【没有分摊行】—— 在【表】上拒,不是靠"RPC 没提供那条路"。
--     RPC 不提供只是没铺路;守卫才是墙。直插是这套系统里真实存在的一条路
--     (containers 那条 code 里装着错误负载的行就是直插留下的)。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_freight_allocation_direction()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_dir text; v_code text;
BEGIN
    SELECT direction, code INTO v_dir, v_code
      FROM public.freight_documents WHERE id = NEW.freight_document_id;
    IF v_dir IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DOCUMENT_NOT_FOUND|%', NEW.freight_document_id;
    END IF;
    IF v_dir <> 'inbound' THEN
        RAISE EXCEPTION 'EXPORT_FREIGHT_HAS_NO_ALLOCATIONS|%', v_code
          USING HINT = '出口运费是期间费用,不摊进任何批次 —— 给它一条分摊行就是把它塞进存货';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_freight_allocations_direction
    BEFORE INSERT OR UPDATE ON public.freight_allocations
    FOR EACH ROW EXECUTE FUNCTION public.guard_freight_allocation_direction();

-- ════════════════════════════════════════════════════════════════════════════
-- (d·守卫) status 不再是手改得到的。
--     此前 'reversed' 是一个【只能靠手工 UPDATE 写进去的值】,而那条 UPDATE
--     除了 updated_at 之外没有人看着 —— 冲销没有分录、没有理由、没有人。
--     同 guard_soft_delete_provenance 的形状:标记由库内函数设,PostgREST 够不着。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.guard_freight_status_transition()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;
    IF COALESCE(current_setting('evoltrya.freight_reverse_ctx', true), '') <> '1' THEN
        RAISE EXCEPTION 'FREIGHT_STATUS_NO_DIRECT_UPDATE|%|%->%',
            COALESCE(NEW.code, OLD.code, '?'), OLD.status, NEW.status
          USING HINT = '运费单的状态只能由 reverse_freight_document 改 —— 它会记下理由、经手人,并冲掉那张分录';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_freight_documents_status_guard
    BEFORE UPDATE ON public.freight_documents
    FOR EACH ROW EXECUTE FUNCTION public.guard_freight_status_transition();

-- ════════════════════════════════════════════════════════════════════════════
-- (d·列) 冲销的留痕 —— AUDEL 家族的形状:谁、为什么、哪一张冲销分录。
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.freight_documents
    ADD COLUMN container_id      uuid REFERENCES public.containers (id),
    ADD COLUMN reversed_at       timestamptz,
    ADD COLUMN reversed_by       uuid,
    ADD COLUMN reversal_reason   text,
    ADD COLUMN reversal_entry_id uuid REFERENCES public.journal_entries (id);

COMMENT ON COLUMN public.freight_documents.container_id IS
    'LOG-4a:出口运费【可以】指向一个箱子,但单据本身才是钱的对象(Tim 定)——
所以这一列可空:货代的一张账单可能同时覆盖几个箱子,也可能在箱子建档之前就到。
指了就必须指得中:箱子不存在或已软删【按名拒】(EXPORT_FREIGHT_CONTAINER_NOT_FOUND)。
进货运费不用这一列 —— 它的归属是分摊行指向的那些进料批。';
COMMENT ON COLUMN public.freight_documents.reversal_reason IS
    'LOG-4a:冲销的理由,必填(AUDEL 家族)。没有理由的冲销,事后没人答得出为什么。';

-- ════════════════════════════════════════════════════════════════════════════
-- (a·续) record_freight_document —— 进料臂【逐字节不动】,只多写一列 direction。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_freight_document(p_doc_date date, p_supplier_id uuid, p_amount numeric, p_currency text, p_allocation_basis text, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_allocations jsonb DEFAULT NULL::jsonb, p_notes text DEFAULT NULL::text, p_gst_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_doc_id    uuid := gen_random_uuid();
    v_code      text;
    v_year      integer;
    v_seq       integer;
    v_fx        numeric;
    v_base      numeric;
    v_bank      text;
    v_el        jsonb;
    v_batch     record;
    v_ids       uuid[] := ARRAY[]::uuid[];
    v_units     text[];
    v_basis_tot numeric := 0;
    v_stated    numeric := 0;
    v_share     numeric;
    v_basis_qty numeric;
    v_ratio     numeric;
    v_inv_tot   numeric := 0;
    v_cost_tot  numeric := 0;
    v_alloc_tot numeric := 0;
    v_lines     jsonb := '[]'::jsonb;
    v_je        jsonb;
    v_rows      jsonb := '[]'::jsonb;
    v_last      uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ── 必填项:日期决定期间与汇率,绝不默认(FIN-10)────────────────────────
    IF p_doc_date IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DATE_REQUIRED';
    END IF;
    IF p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_SUPPLIER_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_AMOUNT_INVALID';
    END IF;
    IF p_allocation_basis IS NULL OR p_allocation_basis NOT IN ('weight','value','stated') THEN
        RAISE EXCEPTION 'FREIGHT_BASIS_INVALID|%', COALESCE(p_allocation_basis, '?');
    END IF;
    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array'
       OR jsonb_array_length(p_allocations) = 0 THEN
        RAISE EXCEPTION 'FREIGHT_NO_BATCHES';
    END IF;

    -- ── GST 是一道闸门,不是一句备注 ─────────────────────────────────────────
    -- 进口 GST 是【可抵扣的进项税】(1400):资本化它会同时高估存货【并】毁掉抵扣。
    -- 今天 gst_registered = false、税率 0,所以这里直接点名拒收。
    -- 【登记之后该怎么走,写在这里而不是留给人猜】:GST 部分单独借 1400、
    -- 不参与任何分摊,只有净额进 1200/5000。
    IF p_gst_amount IS NOT NULL AND p_gst_amount <> 0 THEN
        RAISE EXCEPTION 'FREIGHT_GST_NOT_CAPITALISABLE|%', p_gst_amount;
    END IF;

    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'FREIGHT_PAYMENT_STATUS_INVALID|%', p_payment_status;
    END IF;
    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, bank_account_for_currency(p_currency));
        IF v_bank IS NULL THEN
            RAISE EXCEPTION 'BANK_ACCOUNT_REQUIRED';
        END IF;
    ELSE
        v_bank := NULL;
    END IF;

    -- ── 汇率:本位币免换算;外币按【单据日】的行方卖出价(我们付钱出去)──────
    IF p_currency = base_currency_code() THEN
        v_fx := 1;
    ELSE
        v_fx := fx_rate_for(p_currency, p_doc_date, 'tt_sell');
    END IF;
    v_base := round(p_amount * v_fx, 2);

    -- ── 批次集合:先取回来,顺便验单位与货值 ─────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_last := (v_el->>'inbound_batch_id')::uuid;
        IF v_last = ANY (v_ids) THEN
            RAISE EXCEPTION 'FREIGHT_DUPLICATE_BATCH|%', v_last;
        END IF;
        SELECT ib.id, ib.code, ib.quantity, ib.unit, ib.unit_price, ib.remaining_qty
        INTO v_batch
        FROM inbound_batches ib WHERE ib.id = v_last AND ib.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(v_last::text, '?');
        END IF;
        v_ids   := v_ids || v_batch.id;
        v_units := COALESCE(v_units, ARRAY[]::text[]) || v_batch.unit;

        IF p_allocation_basis = 'weight' THEN
            v_basis_tot := v_basis_tot + v_batch.quantity;
        ELSIF p_allocation_basis = 'value' THEN
            -- 【未计价批次:点名拒绝,不给零份额】零份额等于把它那部分运费悄悄
            -- 摊到别的批次头上,而那是一个没人看得见的错误 —— 正是资本化的代价所在。
            IF v_batch.unit_price IS NULL THEN
                RAISE EXCEPTION 'FREIGHT_BATCH_UNPRICED|%', v_batch.code;
            END IF;
            v_basis_tot := v_basis_tot + v_batch.quantity * v_batch.unit_price;
        ELSE
            IF (v_el->>'amount_base') IS NULL THEN
                RAISE EXCEPTION 'FREIGHT_STATED_AMOUNT_REQUIRED|%', v_batch.code;
            END IF;
            IF (v_el->>'amount_base')::numeric < 0 THEN
                RAISE EXCEPTION 'FREIGHT_STATED_AMOUNT_INVALID|%', v_batch.code;
            END IF;
            v_stated := v_stated + (v_el->>'amount_base')::numeric;
        END IF;
    END LOOP;

    -- weight:跨不同单位的"按重量分"没有意义 —— 拒绝,不是近似
    IF p_allocation_basis = 'weight'
       AND (SELECT count(DISTINCT u) FROM unnest(v_units) u) > 1 THEN
        RAISE EXCEPTION 'FREIGHT_MIXED_UNITS|%', array_to_string(
            ARRAY(SELECT DISTINCT u FROM unnest(v_units) u ORDER BY 1), ',');
    END IF;
    IF p_allocation_basis IN ('weight','value') AND COALESCE(v_basis_tot, 0) <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_BASIS_ZERO|%', p_allocation_basis;
    END IF;
    -- stated:必须【正好】加总到单据金额。差一分就拒 —— 单据自己列明了,
    -- 对不上就是抄错了,而"差一点"在存货里同样看不见。
    IF p_allocation_basis = 'stated' AND round(v_stated, 2) <> v_base THEN
        RAISE EXCEPTION 'FREIGHT_STATED_SUM_MISMATCH|%|%', round(v_stated, 2), v_base;
    END IF;

    -- ── 无缝编号(同 EXP/JE 手法)────────────────────────────────────────────
    v_year := EXTRACT(YEAR FROM p_doc_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('freight_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM freight_documents WHERE code LIKE 'FRT-' || v_year::text || '-%';
    v_code := 'FRT-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- ── 单据先落地,分录号后补 ───────────────────────────────────────────────
    -- 【顺序是被外键逼出来的,不是风格】freight_allocations 的外键指向本单,
    -- 所以分摊行不可能先于单据存在。record_expense 是"先过分录再插单据",
    -- 那条顺序在这里【不成立】—— 照抄它就是第一版那个外键错。
    -- LOG-4a:direction 是【字面量 'inbound'】。这个函数没有出境分支,
    -- 出境走 record_export_freight_document —— 进料臂因此逐字节不动。
    INSERT INTO freight_documents (id, code, doc_date, supplier_id, amount_ccy, currency,
        fx_rate, amount_base, allocation_basis, payment_status, bank_account_code,
        notes, created_by, updated_by, direction)
    VALUES (v_doc_id, v_code, p_doc_date, p_supplier_id, p_amount, p_currency,
        v_fx, v_base, p_allocation_basis, p_payment_status, v_bank,
        p_notes, v_user, v_user, 'inbound');

    -- ── 逐批分摊 + 拆账 ─────────────────────────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        SELECT ib.id, ib.code, ib.quantity, ib.unit_price, ib.remaining_qty
        INTO v_batch FROM inbound_batches ib WHERE ib.id = (v_el->>'inbound_batch_id')::uuid;

        IF p_allocation_basis = 'weight' THEN
            v_basis_qty := v_batch.quantity;
            v_share := round(v_base * v_batch.quantity / v_basis_tot, 2);
        ELSIF p_allocation_basis = 'value' THEN
            v_basis_qty := round(v_batch.quantity * v_batch.unit_price, 2);
            v_share := round(v_base * (v_batch.quantity * v_batch.unit_price) / v_basis_tot, 2);
        ELSE
            -- stated:金额是人直接列明的,没有可再导出的中间量 —— basis_qty 留空。
            v_basis_qty := NULL;
            v_share := round((v_el->>'amount_base')::numeric, 2);
        END IF;

        -- 【拆账比例取此刻】迟到的运费是主路径;收货即到就是 ratio = 1。
        v_ratio := CASE WHEN v_batch.quantity = 0 THEN 1
                        ELSE LEAST(1, GREATEST(0, v_batch.remaining_qty / v_batch.quantity)) END;

        INSERT INTO freight_allocations (freight_document_id, inbound_batch_id,
                                         amount_base, basis_qty, in_stock_ratio, created_by)
        VALUES (v_doc_id, v_batch.id, v_share, v_basis_qty, round(v_ratio, 6), v_user);

        v_inv_tot  := v_inv_tot + round(v_share * v_ratio, 2);
        v_cost_tot := v_cost_tot + (v_share - round(v_share * v_ratio, 2));
        v_alloc_tot := v_alloc_tot + v_share;
        v_rows := v_rows || jsonb_build_object(
            'inbound_batch_id', v_batch.id, 'batch_code', v_batch.code,
            'amount_base', v_share, 'basis_qty', v_basis_qty,
            'in_stock_ratio', round(v_ratio, 6));
    END LOOP;

    -- 取整误差归到最后一批 —— 分摊之和必须【等于】单据金额,不是约等于
    IF v_alloc_tot <> v_base THEN
        UPDATE freight_allocations
           SET amount_base = amount_base + (v_base - v_alloc_tot)
         WHERE freight_document_id = v_doc_id AND inbound_batch_id = v_last;
        SELECT in_stock_ratio INTO v_ratio FROM freight_allocations
         WHERE freight_document_id = v_doc_id AND inbound_batch_id = v_last;
        v_inv_tot  := v_inv_tot + round((v_base - v_alloc_tot) * v_ratio, 2);
        v_cost_tot := v_base - v_inv_tot;
    END IF;

    -- ── 过账。借:在库 1200 / 已耗 5000;贷:【货代】—— 已付走银行,未付走 2000 ──
    IF round(v_inv_tot, 2) <> 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '1200', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', round(v_inv_tot, 2),
            'line_memo', 'freight — in-stock share');
    END IF;
    IF round(v_cost_tot, 2) <> 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '5000', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', round(v_cost_tot, 2),
            'line_memo', 'freight — consumed share');
    END IF;
    v_lines := v_lines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
        'line_memo', 'freight payable — forwarder');

    v_je := post_journal_entry(p_doc_date,
        'Freight ' || v_code, 'freight', v_doc_id, v_lines);

    UPDATE freight_documents SET journal_entry_id = (v_je->>'entry_id')::uuid
     WHERE id = v_doc_id;

    RETURN jsonb_build_object(
        'freight_document_id', v_doc_id, 'code', v_code,
        'amount_base', v_base, 'allocation_basis', p_allocation_basis,
        'in_stock_base', round(v_inv_tot, 2), 'consumed_base', round(v_cost_tot, 2),
        'entry_id', v_je->>'entry_id', 'allocations', v_rows);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- (b) 出口运费的门。借 6300,贷 2000 / 银行。没有分摊、没有批次、没有 GST 参数。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_export_freight_document(
    p_doc_date date,
    p_supplier_id uuid,
    p_amount numeric,
    p_currency text,
    p_payment_status text DEFAULT 'unpaid'::text,
    p_bank_account text DEFAULT NULL::text,
    p_container_id uuid DEFAULT NULL::uuid,
    p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_doc_id uuid := gen_random_uuid();
    v_code   text;
    v_year   integer;
    v_seq    integer;
    v_fx     numeric;
    v_base   numeric;
    v_bank   text;
    v_ctr    text;
    v_lines  jsonb := '[]'::jsonb;
    v_je     jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ── 必填项,与进料侧同一条规矩(FIN-10):日期决定期间与汇率,绝不默认 ────
    IF p_doc_date IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DATE_REQUIRED';
    END IF;
    IF p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_SUPPLIER_REQUIRED';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'FREIGHT_AMOUNT_INVALID';
    END IF;
    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'FREIGHT_PAYMENT_STATUS_INVALID|%', p_payment_status;
    END IF;
    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, bank_account_for_currency(p_currency));
        IF v_bank IS NULL THEN
            RAISE EXCEPTION 'BANK_ACCOUNT_REQUIRED';
        END IF;
    ELSE
        v_bank := NULL;
    END IF;

    -- ── 箱子可空;【指了就必须指得中】────────────────────────────────────────
    -- 单据是钱的对象(Tim 定),所以不指也成立:货代一张账单可能覆盖几个箱子,
    -- 也可能在箱子建档之前就到。但指向一个不存在或已注销的箱子,是一条
    -- 【看起来有出处、其实没有】的记录 —— 那比不指更坏。
    IF p_container_id IS NOT NULL THEN
        SELECT code INTO v_ctr FROM containers
         WHERE id = p_container_id AND deleted_at IS NULL;
        IF v_ctr IS NULL THEN
            RAISE EXCEPTION 'EXPORT_FREIGHT_CONTAINER_NOT_FOUND|%', p_container_id
              USING HINT = '这个箱子不存在,或者已经注销了 —— 指向它的运费单会带着一个查不回去的出处';
        END IF;
    END IF;

    -- ── 汇率:与进料侧【同一条】—— 单据日的行方卖出价(我们付钱出去)─────────
    IF p_currency = base_currency_code() THEN
        v_fx := 1;
    ELSE
        v_fx := fx_rate_for(p_currency, p_doc_date, 'tt_sell');
    END IF;
    v_base := round(p_amount * v_fx, 2);

    -- ── 无缝编号:【与进料侧同一个 FRT- 号段】(Tim 定)。同一把 advisory 锁,
    --    所以两个方向并发取号也不会撞 —— 号段是一条,不是两条。
    v_year := EXTRACT(YEAR FROM p_doc_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('freight_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM freight_documents WHERE code LIKE 'FRT-' || v_year::text || '-%';
    v_code := 'FRT-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- allocation_basis 在本表是 NOT NULL,而出境单据【没有分摊】。
    -- 'stated' 是三个取值里唯一一个不意味着"由系统算一个分法"的:它的意思是
    -- "金额是人直接列明的,没有可再导出的中间量" —— 对一张不分摊的单据,
    -- 这恰好是真话。写 'weight' 或 'value' 才是编造一个从未发生的口径。
    INSERT INTO freight_documents (id, code, doc_date, supplier_id, amount_ccy, currency,
        fx_rate, amount_base, allocation_basis, payment_status, bank_account_code,
        notes, created_by, updated_by, direction, container_id)
    VALUES (v_doc_id, v_code, p_doc_date, p_supplier_id, p_amount, p_currency,
        v_fx, v_base, 'stated', p_payment_status, v_bank,
        p_notes, v_user, v_user, 'outbound', p_container_id);

    -- ── 过账:借 6300(运输物流费,expense)/ 贷 2000 或银行 ─────────────────
    -- 【1200 与 5000 在这个函数里一次都没有出现】,这不是巧合,是本刀的全部内容。
    -- 出口运费不是落地成本:它没有一个"这批货还剩多少在库"可读,
    -- 也没有一个批次该背它 —— 给它编一个,就是把它藏进存货。
    v_lines := jsonb_build_array(
        jsonb_build_object('account_code', '6300', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', v_base,
            'line_memo', 'export freight' || COALESCE(' — ' || v_ctr, '')),
        jsonb_build_object(
            'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
            'side', 'credit', 'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_fx,
            'line_memo', 'export freight payable — forwarder'));

    v_je := post_journal_entry(p_doc_date,
        'Export freight ' || v_code, 'freight', v_doc_id, v_lines);

    UPDATE freight_documents SET journal_entry_id = (v_je->>'entry_id')::uuid
     WHERE id = v_doc_id;

    RETURN jsonb_build_object(
        'freight_document_id', v_doc_id, 'code', v_code, 'direction', 'outbound',
        'amount_base', v_base, 'expense_account', '6300',
        'container_id', p_container_id, 'container_code', v_ctr,
        'entry_id', v_je->>'entry_id');
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- (d) 冲销,两个方向共用一条门。
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.reverse_freight_document(
    p_freight_document_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_orig freight_documents%ROWTYPE;
    v_settled numeric;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- 【理由必填,拒绝按名】—— AUDEL 家族那一条。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'FREIGHT_REVERSAL_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM freight_documents WHERE id = p_freight_document_id), '?')
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
    END IF;

    SELECT * INTO v_orig FROM freight_documents
     WHERE id = p_freight_document_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FREIGHT_NOT_FOUND|%', COALESCE(p_freight_document_id::text, '?');
    END IF;
    IF v_orig.status <> 'posted' THEN
        RAISE EXCEPTION 'FREIGHT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 【已被结清的单据不许冲销】—— 冲掉它,账龄里那一行消失,而指向它的核销行
    -- 原样留着:一笔真的付过的钱,从此挂在一张"不欠任何人"的单据上。
    -- 与 FIN-22 的 EXPENSE_HAS_ASSET 同一条:先把下游拆掉,或走人工分录改正。
    SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa
      JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.freight_document_id = p_freight_document_id;
    IF v_settled > 0 THEN
        RAISE EXCEPTION 'FREIGHT_HAS_SETTLEMENT|%|%', v_orig.code, v_settled
          USING HINT = '这张运费单已经被付过款 —— 先冲掉那笔付款,再冲销单据';
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)。
    -- 【镜像的是原分录本身】,所以两个方向自动各自对称:进料侧冲掉 1200/5000,
    -- 出境侧冲掉 6300 —— 这个函数一个科目码都不需要知道。
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, CURRENT_DATE,
        'Freight reversal ' || v_orig.code);

    -- 【状态只能从这里改】—— 守卫认这个标记,PostgREST 够不着它。
    PERFORM set_config('evoltrya.freight_reverse_ctx', '1', true);
    UPDATE freight_documents
       SET status = 'reversed', reversed_at = now(), reversed_by = v_user,
           reversal_reason = btrim(p_reason),
           reversal_entry_id = (v_je->>'reversal_id')::uuid,
           updated_by = v_user
     WHERE id = p_freight_document_id;
    PERFORM set_config('evoltrya.freight_reverse_ctx', '', true);   -- 用毕即清

    RETURN jsonb_build_object(
        'freight_document_id', p_freight_document_id, 'code', v_orig.code,
        'direction', v_orig.direction, 'status', 'reversed',
        'reversed_by', v_user, 'reason', btrim(p_reason),
        'reversal_entry_id', v_je->>'reversal_id', 'journal_code', v_je->>'code');
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- (e) containers.code 的形状 —— 那条 code 里装着 PostgREST 错误负载的行的教训。
--     【NOT VALID】:那一行仍在(已软删),它【违反】这条 CHECK,所以
--     VALIDATE CONSTRAINT 跑不过去。既有行不回改(改历史比留着坏),
--     新写入与既有行的更新则从此被挡住。迁移后另有一条查询证明
--     "线上除那一行外全部满足",报告里写了实测结果。
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.containers
    ADD CONSTRAINT containers_code_format
    CHECK (code ~ '^CTR-[0-9]{4}-[0-9]{4}$') NOT VALID;

COMMENT ON CONSTRAINT containers_code_format ON public.containers IS
    'LOG-4a:CTR-YYYY-NNNN。NOT VALID —— 线上有一行 code 里装着的不是箱号,
是一段 PostgREST 错误负载({"code":"42501",...,"message":"permission denied for function
next_container_code"}),由一条绕过 create_container 的直插留下,已软删。
留着它而不改写历史;这条 CHECK 拦的是【下一次】。';

COMMIT;

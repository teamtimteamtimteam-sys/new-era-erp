-- db/tables/inbound_batches.sql
-- 进料批次 —— 库存与应付两条账的源头单据。
--   * remaining_qty 由库存台账触发器体系维护,quantity 一经写入禁改
--     (trg_inbound_batches_quantity_guard),数量恒等式由 DEFERRABLE 约束触发器
--     check_ledger_invariant 在提交时校验 —— 这四个触发器的【函数】都定义在
--     db/functions/inventory_ledger_triggers.sql,触发器挂载在本文件;
--   * unit_price 是【应付之锚】(应付 = quantity × unit_price,改价即改欠款),
--     只能经 set_inbound_unit_price() 修改 —— 价格守卫触发器
--     trg_inbound_batches_price_guard 挂载在 db/tables/price_history.sql(守卫函数
--     与价格史同住,因为它正是"改价必须留痕"这条规则的执行者);
--   * code 'IN-YYYY-NNNN' 由 BEFORE INSERT 触发器从序列取号(非无缝,单据连号
--     要求只在财务凭证侧);
--   * 无 updated_at 触发器(建表早期漏挂)—— 镜像忠实于线上。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- purchase_order_id / purchase_order_line_id 及 trg_inbound_batches_po_line_match
-- 为 db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql 追加(守卫函数在
-- db/functions/guard_inbound_po_line_match.sql;两列可空 —— 没有 PO 的现场收货
-- 照常工作;列序按线上 attnum,追加列在末尾)。
-- cut 4c(db/migrations/2026-07-31-phase4-cut4c-po-receiving.sql)再追加两个触发器:
--   * trg_inbound_batches_po_receivable —— 已取消/已结束的单拒收(PO_NOT_RECEIVABLE);
--   * trg_inbound_batches_advance_po —— 首次收货把 'confirmed' 推到 'receiving'
--     (机械且无歧义;关单是判断,永远手动走 close_purchase_order)。
-- cut 5a(db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql)追加
-- pricing_formula_id / pricing_status 两列(见列注释;列序按线上 attnum,追加在末尾)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.inbound_code_seq;

CREATE TABLE public.inbound_batches (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,  -- 'IN-YYYY-NNNN',触发器取号
    material_id            uuid NOT NULL REFERENCES public.materials (id),
    supplier_id            uuid NOT NULL REFERENCES public.suppliers (id),
    quantity               numeric NOT NULL,
    unit                   text NOT NULL DEFAULT 'kg',
    remaining_qty          numeric NOT NULL,
    CONSTRAINT inbound_batches_remaining_qty_nonneg CHECK (remaining_qty >= 0),
    arrival_date           date,
    stage                  text NOT NULL DEFAULT '待加工'
                           CHECK (stage IN ('待加工','加工中','已加工完')),
    unit_price             numeric,
    notes                  text,
    status                 text NOT NULL DEFAULT 'draft',
    deleted_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid,
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid,
    purchase_order_id      uuid REFERENCES public.purchase_orders (id),
    purchase_order_line_id uuid REFERENCES public.purchase_order_lines (id),
    -- cut 5a:管这批货价格的公式(手工计价的临时采购可空)与定价状态 ——
    -- 'provisional' = 按估计/申报含量暂定,'final' = 已按正式化验重算
    -- (只有 is_final 化验被 apply 后才升 final;手工定价永远只是 provisional)
    pricing_formula_id     uuid REFERENCES public.pricing_formulas (id),
    pricing_status         text NOT NULL DEFAULT 'provisional'
                           CHECK (pricing_status IN ('unpriced','provisional','final')),
    -- ── AUDEL-1b 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────
    deleted_by    uuid,
    delete_reason text,
    -- ── GRN-1a 追加(同上,排在末尾)────────────────────────────────────────
    -- 供应商【申报】的到货量。NULL = 没记录过,是一个具名状态,永不推断。
    -- 【绝不用采购行的量预填它】—— 详见列注释。
    declared_qty  numeric,
    -- ── PROC-2 追加(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────────
    -- 【遮蔽表加一列 = 三件事一支迁移】列 + 列级授权 + _masked 视图,缺一 gate 红。
    chemistry_certainty_code text REFERENCES public.inbound_chemistry_certainties (code),
    -- ── CMPL-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────────
    -- 【进口尽调】执照正文要求:不得接收已进口至新加坡的废物,除非交货方在
    -- 【进口当时】持有进口准证。那是一件关于【过去】、关于【某一票货】的事实,
    -- 系统确立不了 —— 所以这里【记录一次人的核对】,不加拒绝。见列注。
    imported                  boolean,
    import_permit_ref         text,
    import_permit_verified_by uuid REFERENCES auth.users (id),
    import_permit_verified_at timestamptz,
    -- ── PROC-1B-iii 追加(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- R2:**实际到的货**能不能深度放电。与采购行上的判断【两个值都活着】,
    -- 谁也不覆盖谁;不一致由 grn_discrepancies 报出来。
    -- ★ 它【不是】inbound_batch_safety_states 那条轴上的东西 —— 那条答"现在
    --   放没放电"(状态,起火闸读它),本列答"压根能不能放电"(能力)。见列注释。
    deep_discharge_actual_code text REFERENCES public.deep_discharge_judgements (code),
    -- 核验只有在"是进口货"时才说得通;不是进口货却填着核验人,那一行自相矛盾。
    CONSTRAINT inbound_import_verification_only_when_imported
        CHECK (imported IS TRUE
               OR (import_permit_ref IS NULL
                   AND import_permit_verified_by IS NULL
                   AND import_permit_verified_at IS NULL)),
    -- 核验人与核验时刻【同生同灭】:只有其中一个,说不出"谁核的"或"什么时候核的"。
    CONSTRAINT inbound_import_verified_pair
        CHECK ((import_permit_verified_by IS NULL) = (import_permit_verified_at IS NULL))
);

COMMENT ON COLUMN public.inbound_batches.delete_reason IS
    'AUDEL-1b:为什么注销这一批。由 soft_delete_inbound_batch() 必填写入;守卫不允许在没有它的情况下置 deleted_at。【历史行为空是真的空】—— 本刀之前的软删没有记过理由,不回填(FIN-26:伪造的出处比空白更坏)。';
COMMENT ON COLUMN public.inbound_batches.declared_qty IS
    'GRN-1a:供应商【申报】的到货量,与 quantity(磅秤说的数)是两回事。【NULL = 没有记录过,是一个具名状态,永不推断】。
【绝对不要用采购行的量去预填它】—— 那是【我们下的单】,不是【他们的申报】。一个被预填的申报量,是系统替供应商说了话:它会让"申报与实收一致"这句话在没有任何供应商文件的情况下成立,而那正是这一列存在要回答的问题。收货表单的数量框预填 remaining_qty 是【便利】(操作员必然会照磅改),申报量预填则是【伪造一条记录】,两者不是同一件事。
两个收货 RPC 的 p_declared_qty 因此 DEFAULT NULL:不填就是没记,而不是等于订量。
差异【不拒绝】—— 它是一条被记下来的事实,由 grn_discrepancies 说出来,由人去判断。';

CREATE INDEX idx_inbound_batches_po ON public.inbound_batches (purchase_order_id);

CREATE OR REPLACE FUNCTION public.generate_inbound_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'IN-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('inbound_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_inbound_code
    BEFORE INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION generate_inbound_code();

-- 库存台账体系(函数见 db/functions/inventory_ledger_triggers.sql)
CREATE TRIGGER trg_inbound_batches_emit_receipt
    AFTER INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION emit_batch_receipt_movement();

CREATE TRIGGER trg_inbound_batches_writeoff
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW
    WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION emit_batch_writeoff_movement();

CREATE TRIGGER trg_inbound_batches_quantity_guard
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW
    WHEN (NEW.quantity IS DISTINCT FROM OLD.quantity)
    EXECUTE FUNCTION reject_quantity_change();

CREATE CONSTRAINT TRIGGER trg_inbound_batches_invariant
    AFTER INSERT OR UPDATE ON public.inbound_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_ledger_invariant();

-- PO 关联守卫(cut 4a;函数见 db/functions/guard_inbound_po_line_match.sql)
CREATE TRIGGER trg_inbound_batches_po_line_match
    BEFORE INSERT OR UPDATE OF purchase_order_id, purchase_order_line_id
    ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION guard_inbound_po_line_match();

-- 收货与采购单状态的联动(cut 4c)
CREATE OR REPLACE FUNCTION public.guard_inbound_po_receivable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po record;
    v_cert record;
BEGIN
    -- CMP-1:【block 类型的证书过期 → 本供应商不能收货】,不论这单挂没挂采购单 ——
    -- Doc 1 问的是"有害废物【进场】",进场是物理事件,与单据无关。只在 INSERT 时查
    -- (换采购单的 UPDATE 不重复查:货已在场,换单不是又进了一次场)。
    -- 【disposition 从类型表现读】—— 改一行数据就改行为,这正是类型作为表的全部意义。
    -- 【缺证不挡】:挡的是"过期",不是"没有"—— A3 的答复只到这里。
    IF TG_OP = 'INSERT' AND NEW.supplier_id IS NOT NULL THEN
        SELECT ct.code, ct.name_en, sc.valid_until, s.code AS supplier_code
        INTO v_cert
        FROM supplier_compliance sc
        JOIN certificate_types ct ON ct.code = sc.cert_type_code
        JOIN suppliers s ON s.id = sc.supplier_id
        WHERE sc.supplier_id = NEW.supplier_id
          AND sc.deleted_at IS NULL
          AND ct.disposition = 'block'
          AND sc.valid_until IS NOT NULL
          AND sc.valid_until < CURRENT_DATE
        ORDER BY sc.valid_until
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SUPPLIER_QUALIFICATION_EXPIRED|%|%|%',
                v_cert.supplier_code, v_cert.code, v_cert.valid_until;
        END IF;
    END IF;

    IF NEW.purchase_order_id IS NULL THEN
        RETURN NEW;
    END IF;
    -- UPDATE 时只在换单时把关(同单上改行号之类不重复检查)
    IF TG_OP = 'UPDATE' AND NEW.purchase_order_id IS NOT DISTINCT FROM OLD.purchase_order_id THEN
        RETURN NEW;
    END IF;
    SELECT code, status, approval_status INTO v_po FROM purchase_orders WHERE id = NEW.purchase_order_id;
    IF FOUND AND v_po.status IN ('cancelled', 'closed') THEN
        RAISE EXCEPTION 'PO_NOT_RECEIVABLE|%|%', v_po.code, v_po.status;
    END IF;
    -- APR-2:【未获批的采购单不能收货】。这是审批从"状态列"变成"管控"的那一步:
    -- 收货走的是裸 INSERT,没有 RPC,所以这个触发器就是唯一的咽喉。
    IF FOUND AND v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_inbound_batches_po_receivable
    BEFORE INSERT OR UPDATE OF purchase_order_id ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_po_receivable();

-- SUP-TYPE-1a:不许把货收在一个【不供货】的往来户名下(房东、水电、保险这一类)。
-- 函数见 db/functions/guard_inbound_supplier_supplies_goods.sql。
-- 【为什么是触发器,不是写进两个收货 RPC】实测:authenticated 裸 INSERT 被 RLS 拒
-- (本表有 RLS 却没有 INSERT 策略),但 service_role / postgres 都 rolbypassrls,
-- 服务密钥那条路绕得过 RLS —— 而收货侧其余五条规矩也全是触发器。
-- 【BEFORE INSERT OR UPDATE,函数内部只对 INSERT 与【换了供应商】开火】
-- 写宽一格会让挂在非供货户下的历史收货软删不掉(软删是一次 UPDATE)。
CREATE TRIGGER trg_inbound_batches_supplier_supplies_goods
    BEFORE INSERT OR UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION guard_inbound_supplier_supplies_goods();

CREATE OR REPLACE FUNCTION public.advance_po_on_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.purchase_order_id IS NOT NULL THEN
        -- PUR-2:收货把单据从 confirmed 推到 receiving —— 那是一次【状态转换】,
    -- 不是一次修改。与另外五个转换函数同一个标记,用完立刻清。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
        SET status = 'receiving', updated_by = auth.uid()
        WHERE id = NEW.purchase_order_id AND status = 'confirmed';
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    END IF;
    RETURN NULL;
END;
$function$;

CREATE TRIGGER trg_inbound_batches_advance_po
    AFTER INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.advance_po_on_receipt();

ALTER TABLE public.inbound_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inbound_batches select by permission"
    ON public.inbound_batches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));

-- 【没有面向客户端的 INSERT 策略,这是刻意的】(IOD-1b,2026-08-13)
-- 建批次只有一扇门:create_inbound_batch / receive_inbound_batch_against_po
-- (产出侧是 create_output_batch)。它们是 SECURITY DEFINER,以属主身份写入,
-- 所以不需要这条策略;而撤掉它,直接 POST /rest/v1/<表> 会被 RLS 拒。
-- 【为什么】IOD-2 要在"货落进哪个库位"上设闸,而一个留着侧门的卡口不是卡口 ——
-- 先把门收成一扇,IOD-2 只需在这一扇门上加判断,不必追第二条路径。
-- 【IOD-2 已经落闸(2026-08-13)】判断就加在这一扇门上:check_location_class,
-- 见 storage_location_allowed_classes 表头。这条策略因此是【它的前提】,不是
-- 一次顺手收紧 —— 撤掉它,闸就又有了一条绕过去的路。
-- commit_processing_run 同为 DEFINER,不受影响(fixture 58 D 臂钉住)。

CREATE POLICY "inbound_batches update by permission"
    ON public.inbound_batches
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text)) WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "inbound_batches delete by permission"
    ON public.inbound_batches
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 inbound_batches_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.inbound_batches FROM authenticated, anon;
GRANT SELECT (id, code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, stage, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, purchase_order_id, purchase_order_line_id, pricing_formula_id, pricing_status, deleted_by, delete_reason, declared_qty, chemistry_certainty_code,
    -- CMPL-1:进口尽调那四列。【不敏感】,所以进列清单授权 —— 给遮蔽表加列
    -- 必须同时做三件事(ADD COLUMN + 本授权 + _masked 视图),少一件就"写得进、读不出"。
    imported, import_permit_ref, import_permit_verified_by, import_permit_verified_at,
    -- PROC-1B-iii:实际到的货能不能深度放电。同上,三件事一件都不能少 ——
    -- 而这一列漏掉的后果特别隐蔽:"读不到"会显示成"未记录",
    -- 与本刀刻意设计的"缺一侧就是 NULL"长得一模一样。
    deep_discharge_actual_code)
    ON public.inbound_batches TO authenticated;

-- AUDEL-1a:硬删按名拒(BATCH_NO_HARD_DELETE|批号),【与动没动过无关】。
-- 外键的 RESTRICT 只在批次已有台账行时才拦得住;而一个从未动过的批次删得干净,
-- 并且 inbound_batch_metals 是 CASCADE —— 那些是【化验结果】,会跟着一起消失。
-- 撤销走软删(置 deleted_at),它会写一条 writeoff 流水。守卫只挡 DELETE。
CREATE TRIGGER trg_inbound_batches_no_hard_delete
    BEFORE DELETE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_no_hard_delete();

-- AUDEL-1b:置 deleted_at 必须走【门】(函数),且 deleted_by / delete_reason 必须填好。
-- 光加两列挡不住任何事 —— 软删本来就是一次直连 UPDATE。
CREATE TRIGGER trg_inbound_batches_soft_delete_provenance
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();

COMMENT ON COLUMN public.inbound_batches.chemistry_certainty_code IS
'PROC-2:对【这一批】料的化学体系我们知道多少 —— 逐批不同,只有收货的人看得见。
【与 materials.chemistry 不是同一件事】那一列说"这一种物料【是】什么",
本列说"这一批货我们【知道】什么"。两者可以同时成立、也可以各自独立成立:
一批 NMC 物料的货可能来的时候是混的,一批混合料的货也可能完全如预期。
**同一段话写在 inbound_chemistry_certainties 的表注上,两边一字不差** ——
下一个人无论先打开哪一个,读到的都是同一句(Tim 点名要这样)。
【可空】既有进料批不回填 —— 空的意思是"没有人记过",而那是真话。';

-- PROC-2c:化学体系确定度的适用性守卫(与安全状态共用一个函数,见 db/functions/)。
CREATE TRIGGER trg_inbound_batches_condition_applicable
    BEFORE INSERT OR UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_condition_applicable();


COMMENT ON COLUMN public.inbound_batches.imported IS
    'CMPL-1:这批料是不是【进口进新加坡】的。★三个状态必须分得开,而 NULL 是第四个★:NULL = **还没有人说**(绝不等于"不是进口货" —— 一个空白读成"不是进口"正是本仓库反复付账的那种沉默);false = 明确不是进口;true = 是进口,于是执照条件要求交货方在【进口当时】持有进口准证,核验记录见同表另外三列。';

COMMENT ON COLUMN public.inbound_batches.import_permit_verified_at IS
    'CMPL-1:【谁在什么时候核过】那张进口准证。★它记录的是一次【人的核对】,不是系统的判断★ —— 「交货方在进口当时是否持证」是关于过去、关于某一票货的事实,系统确立不了,所以本刀**只记录、只告警,不加拒绝**。判得了的那一半(交货方【当下】有没有一张在效的 nea_import 准证)**已经由 certificate_types 的 block 处置在收货上拦着了**,本刀不重复它。';

COMMENT ON COLUMN public.inbound_batches.deep_discharge_actual_code IS
'PROC-1B-iii(R2):**实际到的货**能不能深度放电 —— 到货后看过之后记下的。

★【两个值都活着,谁也不覆盖谁】★ 采购行上的判断(purchase_order_lines.
deep_discharge_judgement_code)不因为这里记了一个值就被改写,反之亦然。
**两者不一致必须看得见** —— 那正是 Tim 拿去跟供应商谈的东西。
差异由 grn_discrepancies 报(kinds 里的 deep_discharge_contradicted),
【不另起一套机制】:expected_assay vs 实际化验、declared_qty vs quantity,
仓库里这个"预期 vs 实际"的形状已经有两份了,本条跟其中一份走。

★★【它【不是】安全状态那条轴上的东西 —— 两半理由都写在这里】★★
  ① **同一本字典**(deep_discharge_judgements)让采购侧与到货侧【可比】——
     两侧取值集合不同,那个比较就没有意义。
  ② **不同的表**让【能力轴】离【起火闸】远远的。inbound_batch_safety_states
     答的是"这批料现在放没放电"(状态),guard_processing_input 读它;
     本列答的是"这批料压根能不能放电"(能力)。把本列做成 safety_states 的一行,
     就等于给同一件事造了第二种说法 —— 而那是这个仓库反复付账的那一类缺陷。
  证据:整电池粉料线【受理 charged_not_discharged 却不解决它】,因为它专收
  【放不了电】的料。带电+能放电 → 放电线;带电+放不了电 → 电池粉料线。
  两条轴必须能同时说话。

【NULL = 这一行比这条轴还老】不回填。要记"看过了但说不上来",用 not_assessed。';

-- INV-VAL-1 R9:到货日【不许由有改回空】。建批那一刻的必填由
-- create_inbound_batch 与 receive_inbound_batch_against_po 各自拒
-- (ARRIVAL_DATE_REQUIRED,IOD-2-fu1);本触发器补的是它们拦不住的那一半 ——
-- app/inbound/[id]/edit/actions.ts 直接 UPDATE 本表,空串写成 NULL,
-- 而 RLS 的 UPDATE 策略只问 module.inbound.edit。
-- ★【不是 NOT NULL】★ 线上 7 张进料批没有到货日,全部早于 IOD-2-fu1,
-- 而 R9 明写不许回填 —— NOT NULL 会把那 7 张行锁死。只拒【由有变无】,
-- 让 NULL 保持 NULL 的更新照过。fixture 172 E 臂同时钉这两件事。
CREATE TRIGGER guard_arrival_date_not_cleared
    BEFORE INSERT OR UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_receipt_date_not_cleared();

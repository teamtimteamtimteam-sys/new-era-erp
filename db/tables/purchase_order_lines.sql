-- db/tables/purchase_order_lines.sql
-- 采购订单明细行:一行 = 一种料的下单量与估价。
--
-- estimated_amount_ccy = round(quantity × estimated_unit_price, 2);没给估价则为 0
-- (公式定价的料下单时常常没有单价 —— 那不是错误,是常态)。
-- pricing_formula_id 记的是【谈定用哪张公式结算】,到货计价时照它算;可空。
--
-- expected_assay:谈定/预期的金属含量 [{metal, content_pct}]。这是【预期值】——
-- 最终计价一律以【到货批次的实际化验值】(inbound_batch_metals)为准。两者对不上
-- 是正常的商务现实,本表不做任何强制,也【不参与】任何金额计算。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.purchase_order_lines (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id    uuid NOT NULL REFERENCES public.purchase_orders (id) ON DELETE CASCADE,
    line_no              integer NOT NULL,
    -- EQP-1a:可空 —— 设备行不订物料。与 asset_id 恰一非空(见末尾那条 CHECK)。
    material_id          uuid REFERENCES public.materials (id),
    quantity             numeric NOT NULL CHECK (quantity > 0),
    unit                 text NOT NULL DEFAULT 'kg',
    pricing_formula_id   uuid REFERENCES public.pricing_formulas (id),
    estimated_unit_price numeric CHECK (estimated_unit_price IS NULL OR estimated_unit_price >= 0),
    estimated_amount_ccy numeric NOT NULL DEFAULT 0,
    expected_assay       jsonb,
    notes                text,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    UNIQUE (purchase_order_id, line_no),
    -- ── FIN-26 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 行价出处:记录,不从 expected_assay 推断。NULL = FIN-26 之前的行,不回填。
    price_source         text CHECK (price_source IN ('computed', 'manual')),
    price_provenance     jsonb,
    CONSTRAINT po_lines_provenance_pairing
        CHECK ((price_source = 'computed') = (price_provenance IS NOT NULL)),
    -- ── EQP-1a 追加(ALTER 加的列排在末尾)──────────────────────────────────
    asset_id             uuid REFERENCES public.fixed_assets (id),
    CONSTRAINT purchase_order_lines_material_xor_asset
        CHECK (num_nonnulls(material_id, asset_id) = 1),
    -- ── EQP-1a-TAIL:两条约定变成规则(它们在【表上】,直插也逃不掉)────────
    CONSTRAINT purchase_order_lines_equipment_qty_one
        CHECK (asset_id IS NULL OR quantity = 1),
    CONSTRAINT purchase_order_lines_equipment_unit
        CHECK (asset_id IS NULL OR unit = 'unit'),
    -- ── PROC-1B-iii 追加(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- R1:【能不能深度放电】这个判断在【采购时】做出,在货到之前 —— 那一刻
    -- 进料批还不存在。放在这里不是图方便,是放在它真正发生的地方。
    deep_discharge_judgement_code text REFERENCES public.deep_discharge_judgements (code)
);

COMMENT ON CONSTRAINT purchase_order_lines_equipment_qty_one ON public.purchase_order_lines IS
'EQP-1a-TAIL:一条设备行订的是【一台】机器 —— quantity 恒为 1。
四台机器是四条行(或四张单),不是一条 quantity = 4 的行:它们各有各的资产卡、
各自的投用日与折旧。材料行(asset_id IS NULL)不受这条约束。';

COMMENT ON CONSTRAINT purchase_order_lines_equipment_unit ON public.purchase_order_lines IS
'EQP-1a-TAIL:设备行的计量单位恒为 ''unit''。
【这条 CHECK 存在的全部理由】unit 的列默认值是 ''kg'' —— 省略它的设备行会
无声地变成公斤,而 purchase_order_status.ordered_qty 是一个【不看单位】的
sum(quantity),于是那台机器会被加进公斤里。约定挡不住"忘了填",CHECK 挡得住。';

COMMENT ON COLUMN public.purchase_order_lines.price_source IS
    '行价的出处(FIN-26):computed = 估算按钮产出(必带 price_provenance);manual = 手填。NULL = FIN-26 之前的行,当时没记 —— 【不回填猜测】,界面画"未知"。不要从 expected_assay 推断。';
COMMENT ON COLUMN public.purchase_order_lines.price_provenance IS
    'computed 行的重导出依据(FIN-26):化验、逐金属行情与日期、汇率与 as-of、公式参数快照(公式可编辑,行上的 id 指不住当时的样子)。不能重导出的出处只是标签。';

COMMENT ON COLUMN public.purchase_order_lines.estimated_amount_ccy IS
    '行估算金额 = round(quantity × estimated_unit_price, 2),以【所属单据自己的币种】计 —— 不换算。FIN-28 前列名 estimated_amount_usd。';

COMMENT ON COLUMN public.purchase_order_lines.deep_discharge_judgement_code IS
'PROC-1B-iii(R1):【采购时】做出的那个判断 —— 这批料能不能深度放电。

★【为什么在采购行上,而不是在进料批上】★ 因为**这个判断是在买的时候做出的,
在货到之前** —— 那一刻【进料批还不存在】。这不是把它放在方便的地方,
是放在它真正发生的地方。仓库里已有同一个理由的先例:work_order_lines
按【物料】排产而不按批次,写的也是"排产的时候那个批次常常还不存在"。

【NULL = 这一行比这条轴还老】不回填,不拦人。**要记"看过了但没下判断",
用字典里的 not_assessed —— 那是一个 positive 的事实,不是一个空值。**
★ 一个没设的判断【永远不许被读成"不能"】★。

【R3:它【不拦】收货】这个判断影响的是【怎么路由】,不是【收不收货】——
它不是在门口拒收的理由。receive_inbound_batch_against_po 一个字都没为它改过,
而 fixture 168 把这件事钉住了:一张收货,实际与判断【矛盾】,仍然成功。';

CREATE INDEX idx_purchase_order_lines_po ON public.purchase_order_lines (purchase_order_id);

ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_order_lines select by permission"
    ON public.purchase_order_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));

CREATE POLICY "purchase_order_lines insert by permission"
    ON public.purchase_order_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "purchase_order_lines update by permission"
    ON public.purchase_order_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit'::text)) WITH CHECK (has_permission('module.purchasing.edit'::text));

CREATE POLICY "purchase_order_lines delete by permission"
    ON public.purchase_order_lines
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 purchase_order_lines_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.purchase_order_lines FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, line_no, material_id, quantity, unit, pricing_formula_id, expected_assay, notes, created_at, created_by, price_source, asset_id,
    -- PROC-1B-iii:采购时的那个判断。【不敏感】,进列清单授权 —— 给遮蔽表加列
    -- 必须同时做三件事(ADD COLUMN + 本授权 + _masked 视图),少一件就"写得进、读不出",
    -- 而且【一个字的报错都不会有】。本刀的主迁移漏了后两件,由 fu1 补上。
    deep_discharge_judgement_code)
    ON public.purchase_order_lines TO authenticated;

-- ── PUR-2:已收下限与留痕 ────────────────────────────────────────────────────
-- 【本表此前一个触发器都没有】连 updated_at 都没有 —— 这正是 PUR-2 的起点:
-- "只能作废重开"不是系统在执行的规则,是应用里没有那个按钮。
-- 函数体见 db/functions/guard_po_line_received_floor.sql 与 trg_po_history_line.sql。
CREATE TRIGGER guard_po_lines_received_floor
    BEFORE UPDATE OR DELETE ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_line_received_floor();

CREATE TRIGGER trg_purchase_order_lines_history
    AFTER INSERT OR UPDATE OR DELETE ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.trg_po_history_line();

COMMENT ON COLUMN public.purchase_order_lines.asset_id IS
    'EQP-1a:这一行订的是【一台已经建了卡的固定资产】。
【行不创建资产】—— 资产卡先建、成本后挂,与 record_expense(p_asset := …) 同一条顺序。
与 material_id 恰一非空(purchase_order_lines_material_xor_asset);
两者都空或都有,直插也会被拒。设备行【不可收货】:机器到货不是一次入库
(不产生批次、没有化验、不进库位),由 guard_inbound_po_line_match 按名拒。';

-- EQP-1a · N1:一张采购单不许混装材料行与设备行。
-- 【延迟的约束触发器,不是 CHECK、也不是普通行触发器】—— CHECK 看不见别的行;
-- 而 amend_purchase_order 在一个循环里【按载荷顺序】逐元素增删改,普通行触发器
-- 会因为"载荷把新增排在删除之前"误伤一次正当的改单。延迟到提交时判【最终状态】,
-- 判的才是规则本身。同形先例:journal_lines 的借贷平衡、inbound_batches 的数量恒等式。
CREATE CONSTRAINT TRIGGER trg_po_lines_single_kind
    AFTER INSERT OR UPDATE ON public.purchase_order_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION guard_po_lines_single_kind();

-- ── EQP-1b-ii:expenses → purchase_order_lines 的外键【住在这里】────────────
-- 【为什么不在 db/tables/expenses.sql 里】那三张表构成一个真实的引用环:
--     expenses.purchase_order_line_id → purchase_order_lines   (本刀)
--     purchase_order_lines.asset_id   → fixed_assets           (EQP-1a)
--     fixed_assets.expense_id         → expenses               (FIN-22)
-- check_mirrors 的 toposort 是【按文本里的 REFERENCES public.x】给表镜像排序的
-- (db/check_mirrors.py 的 table_deps),遇到环直接退出并点名参与的文件 ——
-- 本刀第一版把外键写在 expenses 的建表语句里,它当场列了 24 个文件。
-- 环是【线上真实存在】的,不是镜像的毛病;能挪的只有"什么时候把这条边接上"。
-- 所以它挪到环上【最后】被建的那张表(本表)的镜像末尾,用一条 ALTER 补。
--
-- 【下面那个 CREATE INDEX 同时在替 toposort 说话,这一点是刻意的】
-- 它写着 `ON public.expenses`,而 table_deps 正是认 `REFERENCES public.x` 与
-- `ON public.x` 两种写法 —— 于是"本表要在 expenses 之后建"成为一条排序器
-- 【看得见】的边,而不是一句靠 fixed_assets 传递过来、指望它别变的巧合。
-- 这条索引本来就该在这里:它服务的是 guard_po_line_received_floor 的删除支。
ALTER TABLE public.expenses
    ADD CONSTRAINT expenses_purchase_order_line_id_fkey
    FOREIGN KEY (purchase_order_line_id) REFERENCES public.purchase_order_lines (id);

-- guard_po_line_received_floor 的删除支要查这条行上【全部状态】的支出(已冲销的
-- 也算 —— 外键照样指着);uq_expenses_live_po_line 只收 posted 的,谓词不蕴含。
CREATE INDEX idx_expenses_po_line ON public.expenses (purchase_order_line_id);

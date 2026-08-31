-- db/migrations/2026-09-01-eqppay1-b-equipment-milestones-and-retention.sql
-- EQP-PAY-1 第二项:设备付款里程碑 + 质保金(retention)。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【Tim 用系统时发现的缺陷】开一张【设备】采购单,付款计划的里程碑下拉里给的是
-- 【材料】那一套:on order / on shipment / on arrival / AFTER ASSAY / fixed date。
-- 一台机器【永远不会被化验】。这个选项不只是没用 —— 它【选得中】,所以它是错的。
-- 实测:线上 PO-2026-0007(SGD 400,000,一台 Bosch 深放电机 FA-2026-0001)
-- 第 3 期的 trigger_event 就是 post_assay。这不是假想,是已经发生了。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- ★★【设计前的两个假前提,量出来是错的 —— 写在这里,免得下一个人再继承一次】★★
--
-- 【假前提一:"里程碑清单是一部字典,给它加几行就行"】—— 没有字典。
--   那五个值住在【六个地方、零行数据】里:
--     ① purchase_order_payment_terms 上的一条 CHECK;
--     ② payment_term_template_lines 上的另一条 CHECK(同一份清单,抄了第二遍);
--     ③ app/purchasing/orders/new/actions.ts 的 TRIGGERS 集合;
--     ④ app/purchasing/orders/new/NewOrderForm.tsx 的 TRIGGER_OPTIONS 数组;
--     ⑤ messages/en.ts + messages/zh.ts 的 trigger 标签;
--     ⑥ .../pdf/PurchaseOrderDocument.tsx 的 TRIGGER_PHRASE。
--   "加几行"这句话【当时执行不了】。所以本支先把字典【建出来】,再让那六处
--   全部指向它 —— 第七种里程碑将来才可能是一行数据。
--
-- 【假前提二:"一张设备采购单"是数据库叫得出名字的东西】—— 叫不出。
--   purchase_orders 上【没有任何类型列】。设备与材料的区别在【行】上:
--   purchase_order_lines.asset_id XOR material_id(EQP-1a)。而付款计划挂在
--   【表头】上。所以"在设备单上拒绝 after assay"这句话,在有人给"设备单"下定义
--   之前,是一句写不出判据的话。本支的定义:**一张单的种类由它的行决定,
--   而混装单从此被拒**(见下面 guard_po_lines_not_mixed)。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【一部字典,不是两部 —— 而且这是本支最容易做错的一处】
-- on_order 与 fixed_date 对材料和设备【是同一个概念】。拆成"材料集"和"设备集"
-- 两张表,就是把同一个概念写成两行,而两行会漂 —— 改了一边忘了另一边,于是
-- 同一个词在两张单上开始表示不同的事。所以:**一张表,每行两个适用性布尔量。**
--   post_assay            → applies_to_equipment = false(机器不化验)
--   installation/acceptance/training → applies_to_material = false(一吨废料不安装)
-- 【排除的判据是"这件事会不会发生在它身上",不是"清单上有没有列"】——
-- on_shipment 对一台进口机器【完全成立】(凭装运单据付款是设备进口的常规),
-- 所以它留着。唯一排除的是 post_assay。R5 说得对:一个用不上的选项比一个
-- 缺失的选项更糟,因为它选得中 —— 但反过来,把一个用得上的选项拿掉同样是错的。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【质保金是另一种形状的里程碑,这是本支真正要做对的地方】
-- 别的里程碑都是"某件事发生的时候"。质保金是"某件事发生之后【N 个月】"。
--   * 它从【验收合格】起算,不从到货、也不从尾款;
--   * 默认 12 个月,【必须逐台可改】;
--   * 【它是可选的】。有的设备有质保金,有的没有。**没有质保金的机器不该有
--     一条 0% 的质保金行,而该【一行都没有】** —— "0%"与"没有"是两件不同的事,
--     永远不许长得一样。本支把这一条做成【结构】:percentage 的 CHECK 是
--     `> 0`,所以一行 0% 【存不进去】;唯一能表达"没有"的写法就是没有行。
--   * 【到期不自动付】。系统【提示】,由人确认"这台机器在质保期内没出过毛病",
--     应付才成立。质保金的意义就在于它【扣得下来】,自动放款等于把它废掉。
--   * 【可以部分扣留】,扣了多少、为什么扣,都要记下来。
--
-- 【到期日是【推导】出来的,不存字面量】(R6/4d)
-- 存一个算好的日期,等于在验收日期改变的那一刻【悄悄地错】。所以到期日只活在
-- purchase_order_retention_status 这张视图里,由 acceptance_date + N 个月现算。
-- 验收日一改,到期日当场跟着走 —— fixture 里有一帧专门证明这件事。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【锚点:验收日期是【新加】的一列,而这是一次有理由的新增】
-- 实测:全库【没有任何地方记录验收】。fixed_assets 上有 acquisition_date、
-- in_service_date、planned_in_service_date,没有 acceptance_date。
--
-- ★【为什么不能拿 in_service_date 顶替】★ 因为实测它会【错一整年,而且不出声】:
--   FA-2026-0001 的 acquisition_date = 2026-08-21,planned_in_service_date =
--   2027-01-01,而 in_service_date 是 NULL(两台机器都是 —— 厂子没开工)。
--   若 2026 年 9 月验收合格,质保金应当 2027 年 9 月到期;锚在投用日上,
--   它会算成 **2028 年 1 月**。差一年,在一笔真实的应付上,而且没有任何提示。
--   **验收合格与"开始服役"是两件事,FA-2026-0001 就是那个证明。**
--
-- ★【为什么它不是又一个 planned_in_service_date(那条腐烂的列)】★
--   planned_in_service_date 的病根写在它自己的列注释里:**没有一条规则读它**。
--   一个没有规则读的字段会烂掉,因为没填也没有任何后果。acceptance_date 恰恰相反:
--     * 一条规则读它 —— 质保金到期日由它算出来;
--     * 一笔钱等着它 —— 没有它,质保金永远停在"未起算",放不了款;
--     * 交易对方会来催 —— 供应商等着这笔尾款,他会盯着这个日子。
--   **一个空着就会有人来问的字段,不会烂。** 这就是它与那一列的全部区别。
--
--   而它空着的时候【不是缺数据】:视图给出 'clock_not_started'(质保期未起算),
--   这句话今天对两台机器【都是真的】。它不许画成错误,也不许画成零。
--
-- 【永不默认】acceptance_date 不从 in_service_date、不从 acquisition_date、
-- 不从任何东西推出来。只能由人明确填写。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【两道闸,不是一道】(R5 的标准做法,而本支这一层是【新增的】,不是收紧)
-- 实测:create_purchase_order 今天对 trigger_event 【一个字都不校验】——
-- 它直接 INSERT,让表上那条 CHECK 去炸,于是屏幕上拿到的是一条裸约束原文。
-- 所以本支加的是:
--   ① 门上的具名拒绝(create_purchase_order 里,拿得到单号与期次号);
--   ② 表上的触发器(guard_payment_term_applicable)—— 任何人直连 PostgREST
--      都绕不过去。**一个禁用掉的下拉选项不是控制。**
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支【不】接维保模块】(R7)一条故障记录是扣留质保金最自然的证据,把两者
-- 接起来值得做 —— 但那是另一个决定,而且厂子没开工,今天连一条故障记录都没有。
-- 记为待办与触发条件,见 docs/equipment-payment-milestones-and-retention.md。
--
-- NOTE: 备份见 ~/evoltrya-backups/(本支前一份)。apply via db/apply_migration.sh。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 里程碑字典 ════════════════════════════════════════════════════════

CREATE TABLE public.payment_trigger_events (
    code                 text PRIMARY KEY,
    name_en              text NOT NULL,
    name_zh              text NOT NULL,
    -- 单据正文里的介词短语(PDF 用)。【与 name_en 分开】:标签是 "On order",
    -- 而句子里要的是 "on order" —— PurchaseOrderDocument 此前自己 replace('_',' ')
    -- 再补一个 on,印出过 "on on shipment"。介词属于数据,不属于那份模板。
    phrase_en            text NOT NULL,
    applies_to_material  boolean NOT NULL,
    applies_to_equipment boolean NOT NULL,
    -- 【这个事件有没有一个系统真的记得住的日期】—— 只有它为 true 的事件才能
    -- 当质保金的锚。今天只有 acceptance_complete 有(fixed_assets.acceptance_date)。
    -- 别的事件将来若也落了日期,把这一格翻成 true 就行 —— 那是一行数据,不是一次改码。
    can_anchor_retention boolean NOT NULL DEFAULT false,
    sort_order           integer NOT NULL,
    is_active            boolean NOT NULL DEFAULT true,
    created_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT payment_trigger_events_applies_to_something
        CHECK (applies_to_material OR applies_to_equipment)
);

COMMENT ON TABLE public.payment_trigger_events IS
'EQP-PAY-1:付款里程碑字典。【本表存在之前,这份清单住在六个地方、零行数据里】——
两张表各一条 CHECK,加上 actions.ts / NewOrderForm.tsx / messages(en+zh)/ 单据 PDF。
"加一种里程碑"当时意味着改六处代码,而漏掉一处的后果是一个值在一处存在、在另一处不存在。

★【为什么是一张表配两个适用性布尔量,不是"材料字典"与"设备字典"两张表】★
on_order 与 fixed_date 对材料和设备**是同一个概念**。拆成两张表就是把同一个概念
写成两行,而两行会漂:改了一边忘了另一边,同一个词在两张单上开始表示不同的事。

【排除的判据是"这件事会不会发生在它身上"】post_assay 对设备为 false —— 机器不化验。
而 on_shipment 对设备【是 true】:凭装运单据付款是设备进口的常规。R5 说一个用不上的
选项比一个缺失的更糟(因为它选得中);反过来把一个用得上的选项拿掉,同样是错的。';

COMMENT ON COLUMN public.payment_trigger_events.can_anchor_retention IS
'这个事件有没有一个【系统真的记录得下来】的日期 —— 只有为 true 的事件才能当质保金的锚。
今天只有 acceptance_complete 为 true,它的日期在 fixed_assets.acceptance_date。
【为什么必须有这一格】质保金的到期日是"锚事件的日期 + N 个月"。锚在一个没有日期的
事件上(比如 training_complete),到期日就【算不出来】—— 而算不出来的到期日,
要么变成一个永远不到期的行,要么诱使人去编一个日期。两个都比拒绝差。';

INSERT INTO public.payment_trigger_events
    (code, name_en, name_zh, phrase_en, applies_to_material, applies_to_equipment, can_anchor_retention, sort_order) VALUES
    ('on_order',              'On order',              '下单时',   'on order',                       true,  true,  false, 10),
    ('on_shipment',           'On shipment',           '装运时',   'on shipment',                    true,  true,  false, 20),
    ('on_arrival',            'On arrival',            '到货时',   'on arrival',                     true,  true,  false, 30),
    -- 机器不化验。这一行就是 Tim 用系统时撞见的那个缺陷,变成一格数据。
    ('post_assay',            'After assay',           '化验后',   'after assay',                    true,  false, false, 40),
    -- ── 设备专属的三种(R4)。到货/交付由既有的 on_arrival 承担,不新开一行。 ──
    ('installation_complete', 'Installation complete', '安装完成', 'on completion of installation',  false, true,  false, 50),
    ('acceptance_complete',   'Acceptance complete',   '验收合格', 'on acceptance',                  false, true,  true,  60),
    ('training_complete',     'Training complete',     '培训完成', 'on completion of training',      false, true,  false, 70),
    ('fixed_date',            'Fixed date',            '固定日期', 'on the fixed date',              true,  true,  false, 80);

ALTER TABLE public.payment_trigger_events ENABLE ROW LEVEL SECURITY;

-- 字典是【给下拉框读的】,而下拉框出现在采购与财务两处屏幕上。
CREATE POLICY "payment_trigger_events select by permission"
    ON public.payment_trigger_events
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text)
        OR has_permission('module.finance.view'::text));

-- ═══ 2 · 两条 CHECK 退役,换成指向字典的外键 ═══════════════════════════════
-- 【为什么是外键而不是把 CHECK 加宽】加宽 CHECK 就是把清单又抄第三遍。
-- 外键之后,"有哪些里程碑"这个问题【只有一个答案的所在地】。

ALTER TABLE public.purchase_order_payment_terms
    DROP CONSTRAINT purchase_order_payment_terms_trigger_event_check;
ALTER TABLE public.purchase_order_payment_terms
    ADD CONSTRAINT purchase_order_payment_terms_trigger_event_fkey
    FOREIGN KEY (trigger_event) REFERENCES public.payment_trigger_events (code);

ALTER TABLE public.payment_term_template_lines
    DROP CONSTRAINT payment_term_template_lines_trigger_event_check;
ALTER TABLE public.payment_term_template_lines
    ADD CONSTRAINT payment_term_template_lines_trigger_event_fkey
    FOREIGN KEY (trigger_event) REFERENCES public.payment_trigger_events (code);

-- ═══ 3 · 资产卡上的验收日期 ════════════════════════════════════════════════
-- fixed_assets 【不是遮蔽表】(实测:authenticated 持表级 SELECT),
-- 所以这里只有 ADD COLUMN,没有列级 GRANT、也没有 _masked 视图要跟着改。

ALTER TABLE public.fixed_assets ADD COLUMN acceptance_date date;

ALTER TABLE public.fixed_assets
    ADD CONSTRAINT fixed_assets_acceptance_after_acquisition
    CHECK (acceptance_date IS NULL OR acceptance_date >= acquisition_date);

COMMENT ON COLUMN public.fixed_assets.acceptance_date IS
'验收合格日(EQP-PAY-1)—— 这台机器【被验收通过】的那一天。质保金的期限从这一天起算。

**它不是 in_service_date,而这两者不能互相顶替。** 验收合格是一件【商务/合同】上的事
(买方确认机器达到约定标准);投用是一件【会计】上的事(折旧从那天起算)。
实测的证据就在本库里:FA-2026-0001 的 acquisition_date = 2026-08-21、
planned_in_service_date = 2027-01-01、in_service_date 为 NULL(厂子没开工)。
若 2026 年 9 月验收合格,质保金应当 2027 年 9 月到期;拿投用日当锚会算成
**2028 年 1 月** —— 差一整年,在一笔真实的应付上,而且不出声。

★【为什么它不会变成第二个 planned_in_service_date】★ 那一列的病根写在它自己的
注释里:**没有一条规则读它**,所以没填也没有任何后果,于是它烂掉。这一列相反 ——
  * 一条规则读它:质保金到期日 = 本列 + retention_months(现算,不存);
  * 一笔钱等着它:没有它,质保金停在 clock_not_started,放不了款;
  * 交易对方会来催:供应商等着那笔尾款,他会盯着这个日子。
**一个空着就会有人来问的字段不会烂。**

【留空 = 质保期未起算】那不是缺数据,也不是零,更不是错误 ——
purchase_order_retention_status 把它画成 clock_not_started,这句话今天对两台机器都为真。

【永不默认】不从 in_service_date、不从 acquisition_date、不从任何东西推出来。
它只能由人明确填写(set_asset_acceptance)。一个被默认出来的验收日,
是在替一个没发生过的验收签字。';

-- 验收是一件【发生过的事】,所以不许在未来 —— 与 in_service_date 同一句话
-- (FIX-1),但【另立一支】:那支触发器的名字说的是投用日,把验收塞进去会让
-- 名字开始撒谎。
CREATE OR REPLACE FUNCTION public.guard_asset_acceptance_not_future()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.acceptance_date IS NOT NULL AND NEW.acceptance_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSET_ACCEPTANCE_IN_FUTURE|%|%', NEW.code, NEW.acceptance_date
          USING HINT = '验收合格是一件发生过的事 —— 未来的日期填不进来。质保期从它起算,一个未来的锚会让到期日也是假的';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_fixed_assets_acceptance_not_future
    BEFORE INSERT OR UPDATE ON public.fixed_assets
    FOR EACH ROW EXECUTE FUNCTION public.guard_asset_acceptance_not_future();

-- 明确填写验收日的门。SECURITY DEFINER:fixed_assets 没有 UPDATE 策略
-- (它的写入一律经函数,见表抬头)。
CREATE OR REPLACE FUNCTION public.set_asset_acceptance(p_asset_id uuid, p_acceptance_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_acq  date;
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF p_acceptance_date IS NULL THEN
        RAISE EXCEPTION 'ACCEPTANCE_DATE_REQUIRED'
          USING HINT = '验收日期不给默认值 —— 一个默认出来的验收日是在替一次没发生过的验收签字';
    END IF;

    SELECT code, acquisition_date INTO v_code, v_acq
    FROM fixed_assets WHERE id = p_asset_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;
    IF p_acceptance_date < v_acq THEN
        RAISE EXCEPTION 'ASSET_ACCEPTANCE_BEFORE_ACQUISITION|%|%|%', v_code, p_acceptance_date, v_acq;
    END IF;

    UPDATE fixed_assets SET acceptance_date = p_acceptance_date WHERE id = p_asset_id;

    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_code,
                              'acceptance_date', p_acceptance_date);
END;
$function$;

-- ═══ 4 · 一张单的种类,由它的行决定 ════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.purchase_order_kind(p_purchase_order_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 'equipment' / 'material' / NULL(这张单还没有行 —— 判不出来,不许假装判得出)
    -- 【为什么是 SECURITY DEFINER】守卫靠它认主语。若它受 RLS 约束,一个看不见
    -- 行的调用者会拿到 NULL,而守卫会因此【静默放行】—— 那正是 AGENTS.md 里
    -- "守卫对主语缺席这一格是瞎的"那条病。守卫必须永远看得见它要判的东西。
    SELECT CASE
        WHEN count(*) FILTER (WHERE asset_id IS NOT NULL) > 0 THEN 'equipment'
        WHEN count(*) FILTER (WHERE material_id IS NOT NULL) > 0 THEN 'material'
        ELSE NULL
    END
    FROM purchase_order_lines WHERE purchase_order_id = p_purchase_order_id;
$function$;

-- B2:SECURITY DEFINER 且体内没有调用者检查 —— 所以【收回 EXECUTE】。
-- 它只给守卫触发器与本库内的函数用,不是一支面向客户端的 RPC。
REVOKE EXECUTE ON FUNCTION public.purchase_order_kind(uuid) FROM PUBLIC, authenticated, anon;

COMMENT ON FUNCTION public.purchase_order_kind(uuid) IS
'EQP-PAY-1:一张采购单是"设备单"还是"材料单" —— 由它的【行】决定,因为
purchase_orders 上没有任何类型列,而 asset_id XOR material_id 在行上(EQP-1a)。
混装单已被 guard_po_lines_not_mixed 拒掉,所以这两种情形互斥。
返回 NULL = 这张单还没有行,种类【判不出来】—— 调用它的守卫必须把 NULL 当作拒绝的理由,
不是当作放行的理由。';

-- 混装单从此被拒。【表上的那一半】—— 门上那一半在 create_purchase_order 里。
CREATE OR REPLACE FUNCTION public.guard_po_lines_not_mixed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_has_asset    boolean;
    v_has_material boolean;
    v_code         text;
BEGIN
    SELECT count(*) FILTER (WHERE asset_id IS NOT NULL) > 0,
           count(*) FILTER (WHERE material_id IS NOT NULL) > 0
    INTO v_has_asset, v_has_material
    FROM purchase_order_lines WHERE purchase_order_id = NEW.purchase_order_id;

    IF v_has_asset AND v_has_material THEN
        SELECT code INTO v_code FROM purchase_orders WHERE id = NEW.purchase_order_id;
        RAISE EXCEPTION 'PO_LINES_MIXED_KIND|%', COALESCE(v_code, NEW.purchase_order_id::text)
          USING HINT = '一张单要么全是材料行、要么全是设备行 —— 请开两张单。两者的收货路径、成本处理与付款里程碑都不同,混在一张单上没有一套里程碑是对的';
    END IF;
    RETURN NEW;
END;
$function$;

-- 【为什么是 AFTER 而不是 BEFORE】它要看的是"这张单落完这一行之后,两种行是不是
-- 都在了" —— BEFORE 时本行还没进表,数不到自己。create_purchase_order 逐行插入,
-- 所以第二行落地的那一刻就撞上它,拿到的是具名拒绝而不是一张建好的混装单。
CREATE TRIGGER trg_po_lines_not_mixed
    AFTER INSERT OR UPDATE ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_lines_not_mixed();

-- ═══ 5 · 里程碑适用性:表上那一道闸 ════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.guard_payment_term_applicable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind   text;
    v_ok     boolean;
    v_code   text;
    v_label  text;
BEGIN
    v_kind := purchase_order_kind(NEW.purchase_order_id);
    SELECT code INTO v_code FROM purchase_orders WHERE id = NEW.purchase_order_id;

    -- 【主语缺席这一格不许放行】没有行的单判不出种类,也就判不出这一期该不该存在。
    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'PO_TERM_KIND_UNKNOWN|%', COALESCE(v_code, NEW.purchase_order_id::text)
          USING HINT = '这张单还没有明细行,判不出它是设备单还是材料单 —— 判不出就不能判定这一期的里程碑适用。先落行,再落付款计划';
    END IF;

    SELECT CASE WHEN v_kind = 'equipment' THEN applies_to_equipment ELSE applies_to_material END,
           name_zh
    INTO v_ok, v_label
    FROM payment_trigger_events WHERE code = NEW.trigger_event;

    IF NOT COALESCE(v_ok, false) THEN
        RAISE EXCEPTION 'PO_TERM_EVENT_NOT_APPLICABLE|%|%|%|%',
            COALESCE(v_code, NEW.purchase_order_id::text), NEW.seq, NEW.trigger_event, v_kind
          USING HINT = '这一种里程碑在这一类采购单上用不上 —— 例如一台机器永远不会被化验(post_assay)。可选的种类见 payment_trigger_events';
    END IF;
    RETURN NEW;
END;
$function$;

-- 【为什么 UPDATE 那一侧只挂在 trigger_event 上】线上 PO-2026-0007 第 3 期
-- 现在带着一个在设备单上用不上的 post_assay(见迁移抬头与文档)。**本支不改它** ——
-- 它是一份真实单据的条款,改它要有人知道合同上到底写的是什么。
-- 若把闸挂在整行 UPDATE 上,那一行就【连别的列都改不动了】:CASHFLOW-1 的
-- expected_date 恰好要落在 post_assay 这类期次上,于是给它填一个预计付款日会被拒 ——
-- 一个与本刀无关的功能会因为一条历史数据坏掉。挂在 trigger_event 上,
-- 既拦住"把它改成另一个用不上的值",又不牵连别的列。
CREATE TRIGGER trg_po_payment_terms_event_applicable
    BEFORE INSERT OR UPDATE OF trigger_event ON public.purchase_order_payment_terms
    FOR EACH ROW EXECUTE FUNCTION public.guard_payment_term_applicable();

-- ═══ 6 · 质保金 ════════════════════════════════════════════════════════════

CREATE TABLE public.purchase_order_line_retentions (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 【挂在行上,不是挂在单上】—— 逐台。四台机器是四条行(EQP-1a-TAIL),
    -- 各有各的资产卡、各有各的验收日,于是各有各的质保期。挂在表头上就说不出
    -- "这台有、那台没有"这句话,而那正是 Tim 强调了两次的要求。
    purchase_order_line_id uuid NOT NULL UNIQUE
                           REFERENCES public.purchase_order_lines (id) ON DELETE CASCADE,
    -- ★【percentage 的下界是 > 0,这不是抄来的,是本条要求的实现】★
    -- 一行 0% 的质保金【存不进去】。所以"没有质保金"唯一的表达方式就是【没有这一行】——
    -- "0% 质保金"与"没有质保金"从此不可能长得一样,因为前者根本不存在。
    percentage             numeric CHECK (percentage IS NULL OR (percentage > 0 AND percentage <= 100)),
    fixed_amount_ccy       numeric CHECK (fixed_amount_ccy IS NULL OR fixed_amount_ccy > 0),
    CONSTRAINT po_line_retentions_pct_xor_fixed CHECK (num_nonnulls(percentage, fixed_amount_ccy) = 1),
    -- 默认 12 个月,逐台可改(Tim 裁定)。默认值在这里是【一个起点】,不是一条规则。
    retention_months       integer NOT NULL DEFAULT 12 CHECK (retention_months > 0),
    -- 锚事件。只能指向 can_anchor_retention 的那些(guard_retention_row 强制)。
    anchor_event           text NOT NULL DEFAULT 'acceptance_complete'
                           REFERENCES public.payment_trigger_events (code),
    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    -- ── 放款确认(R6:到期【提示】,不自动付)────────────────────────────────
    -- released_at IS NULL = 还没有人确认过。到期只让它进入 awaiting_confirmation,
    -- 应付【不因为到期而成立】。
    released_at            timestamptz,
    released_by            uuid,
    released_amount_ccy    numeric CHECK (released_amount_ccy IS NULL OR released_amount_ccy >= 0),
    withheld_amount_ccy    numeric CHECK (withheld_amount_ccy IS NULL OR withheld_amount_ccy >= 0),
    withholding_reason     text,
    -- 放款是一件【整件事】:要么一个字段都没有,要么四个一起有。
    CONSTRAINT po_line_retentions_release_atomic CHECK (
        (released_at IS NULL AND released_by IS NULL AND released_amount_ccy IS NULL
            AND withheld_amount_ccy IS NULL AND withholding_reason IS NULL)
        OR
        (released_at IS NOT NULL AND released_by IS NOT NULL
            AND released_amount_ccy IS NOT NULL AND withheld_amount_ccy IS NOT NULL)
    ),
    -- 扣了钱就要说为什么。【扣 0 不需要理由】—— 那是"全额放行",不是一次扣留。
    CONSTRAINT po_line_retentions_withholding_needs_reason CHECK (
        withheld_amount_ccy IS NULL OR withheld_amount_ccy = 0 OR withholding_reason IS NOT NULL
    )
);

COMMENT ON TABLE public.purchase_order_line_retentions IS
'EQP-PAY-1:设备质保金(retention)。**一台机器一行,而"没有质保金"= 没有这一行。**

★【为什么不塞进 purchase_order_payment_terms】★ 两个理由,任何一个都够:
  ① 那张表【存不下"某事之后 N 个月"】。它只有 due_date(一个字面日期,而且
     fixed_date 那一种【必须】有它)与 expected_date(一个明说了是估计的值)。
     把算好的到期日写进 due_date,会让一个推导值长得和一条合同条款一模一样,
     并在验收日改变的那一刻【悄悄地错】;
  ② 那张表的抬头【自己声明】它不是账:"计划不是债权……也没有已付/未付状态列",
     并且不参与任何结算。而质保金的放款确认(谁、何时、放了多少、扣了多少、为什么)
     恰恰是一本账。把结算列螺到一张写着"我不做结算"的表上,是让它自相矛盾。

★【为什么挂在【行】上而不是单上】★ 逐台。四台机器是四条行,各有各的资产卡与验收日。
挂在表头上就说不出"这台有质保金、那台没有" —— 而那是 Tim 强调了两次的要求。

★【0% 与"没有"永远不会长得一样】★ percentage 的 CHECK 是 `> 0`,一行 0% 【存不进去】。
所以"没有质保金"唯一的表达方式就是【结构性的缺席】,不是一个零值。

★【到期日不在这张表里】★ 它是【推导】的,活在 purchase_order_retention_status 视图里:
acceptance_date + retention_months。存一个字面量,等于在验收日期改变时悄悄地错。

★【到期不自动付】★ released_at 为 NULL 就是"还没有人确认过"。到期只让状态变成
awaiting_confirmation,应付【不因为到期而成立】。质保金的意义就在于它扣得下来,
自动放款等于把它废掉。放款只经 release_purchase_order_retention。';

COMMENT ON COLUMN public.purchase_order_line_retentions.retention_months IS
'质保期月数。默认 12(Tim 裁定),**逐台可改** —— 默认值是一个起点,不是一条规则。
到期日 = fixed_assets.acceptance_date + 本列个月,【现算,不存】。';

COMMENT ON COLUMN public.purchase_order_line_retentions.percentage IS
'质保金比例,对该采购行的 estimated_amount_ccy 而言。与 fixed_amount_ccy 二选一。
★ 下界是 **> 0**,这一条是刻意的:一行 0% 存不进去,于是"没有质保金"唯一的写法
就是【没有这一行】。"0% 质保金"与"没有质保金"是两个不同的事实,永远不许渲染成同一个样子。';

CREATE INDEX idx_po_line_retentions_line ON public.purchase_order_line_retentions (purchase_order_line_id);

-- 质保金只能挂在【设备行】上,而且锚只能是一个【记得住日期】的事件。
CREATE OR REPLACE FUNCTION public.guard_retention_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_asset uuid;
    v_anchor_ok boolean;
BEGIN
    SELECT asset_id INTO v_asset
    FROM purchase_order_lines WHERE id = NEW.purchase_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', NEW.purchase_order_line_id;
    END IF;
    IF v_asset IS NULL THEN
        RAISE EXCEPTION 'RETENTION_NOT_AN_EQUIPMENT_LINE|%', NEW.purchase_order_line_id
          USING HINT = '质保金是设备的事 —— 一条材料行没有验收,也就没有可以起算的锚';
    END IF;

    SELECT can_anchor_retention INTO v_anchor_ok
    FROM payment_trigger_events WHERE code = NEW.anchor_event;
    IF NOT COALESCE(v_anchor_ok, false) THEN
        RAISE EXCEPTION 'RETENTION_ANCHOR_HAS_NO_DATE|%', NEW.anchor_event
          USING HINT = '锚事件必须是一个系统真的记录得下日期的事件(payment_trigger_events.can_anchor_retention)—— 否则到期日算不出来,而算不出来的到期日会诱人去编一个';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_po_line_retentions_guard
    BEFORE INSERT OR UPDATE ON public.purchase_order_line_retentions
    FOR EACH ROW EXECUTE FUNCTION public.guard_retention_row();

ALTER TABLE public.purchase_order_line_retentions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "purchase_order_line_retentions select by permission"
    ON public.purchase_order_line_retentions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "purchase_order_line_retentions insert by permission"
    ON public.purchase_order_line_retentions
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.purchasing.edit'::text));
CREATE POLICY "purchase_order_line_retentions update by permission"
    ON public.purchase_order_line_retentions
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.purchasing.edit'::text)) WITH CHECK (has_permission('module.purchasing.edit'::text));
CREATE POLICY "purchase_order_line_retentions delete by permission"
    ON public.purchase_order_line_retentions
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.purchasing.edit'::text));

-- 字段级遮蔽:金额是价格类数据,与 purchase_order_payment_terms.fixed_amount_ccy
-- 同一个判据(data.view_prices)。percentage 不遮 —— 那张表也没有遮它。
-- 【三件事一支迁移】:REVOKE/GRANT 在这里,_masked 视图在下面。
REVOKE SELECT ON public.purchase_order_line_retentions FROM authenticated, anon;
GRANT SELECT (id, purchase_order_line_id, percentage, retention_months, anchor_event,
              notes, created_at, created_by, released_at, released_by, withholding_reason)
    ON public.purchase_order_line_retentions TO authenticated;

CREATE VIEW public.purchase_order_line_retentions_masked WITH (security_invoker = off) AS
SELECT id,
    purchase_order_line_id,
    percentage,
        CASE WHEN has_permission('data.view_prices'::text) THEN fixed_amount_ccy
             ELSE NULL::numeric END AS fixed_amount_ccy,
    retention_months,
    anchor_event,
    notes,
    created_at,
    created_by,
    released_at,
    released_by,
        CASE WHEN has_permission('data.view_prices'::text) THEN released_amount_ccy
             ELSE NULL::numeric END AS released_amount_ccy,
        CASE WHEN has_permission('data.view_prices'::text) THEN withheld_amount_ccy
             ELSE NULL::numeric END AS withheld_amount_ccy,
    withholding_reason
   FROM purchase_order_line_retentions
  WHERE has_permission('module.purchasing.view'::text);

-- ═══ 7 · 到期状态:推导,不存储 ════════════════════════════════════════════
-- 【属主权限,不是 SECURITY INVOKER】它 JOIN 了 fixed_assets,而那张表要
-- module.finance.view —— 一个只有采购权限的读者会让 INNER JOIN 【整行消失】,
-- 于是"有没有质保金"这个问题对不同的人给出不同的答案,而且不出声(OPS-14 那一族)。
-- 借来的列是【推导事实】(一个日期、一个状态词)→ 用补救 (a):属主权限 + 把读者
-- 自己的模块谓词原样写回视图体。金额那几列是【钱】→ 用补救 (b):遮成 NULL。

CREATE VIEW public.purchase_order_retention_status WITH (security_invoker = off) AS
SELECT r.id AS retention_id,
    r.purchase_order_line_id,
    pol.purchase_order_id,
    po.code AS purchase_order_code,
    po.currency,
    pol.line_no,
    fa.id AS asset_id,
    fa.code AS asset_code,
    fa.description AS asset_description,
    fa.acceptance_date,
    r.anchor_event,
    r.retention_months,
    -- ★【到期日:现算,永不存储】★ 验收日一改,这个值当场跟着走。
    -- 存一个字面量,等于在验收推迟的那一刻悄悄地错 —— 而没有人会发现。
    CASE WHEN fa.acceptance_date IS NULL THEN NULL::date
         ELSE (fa.acceptance_date + (r.retention_months || ' months')::interval)::date
    END AS maturity_date,
    -- 四态。clock_not_started 【不是错误、不是零】—— 它是"还没验收"这个事实,
    -- 今天对线上两台机器都为真。
    CASE WHEN fa.acceptance_date IS NULL              THEN 'clock_not_started'
         WHEN r.released_at IS NOT NULL               THEN 'released'
         WHEN (fa.acceptance_date + (r.retention_months || ' months')::interval)::date
              <= CURRENT_DATE                         THEN 'awaiting_confirmation'
         ELSE 'running'
    END AS retention_state,
    r.percentage,
        CASE WHEN has_permission('data.view_prices'::text) THEN r.fixed_amount_ccy
             ELSE NULL::numeric END AS fixed_amount_ccy,
        CASE WHEN has_permission('data.view_prices'::text)
             THEN COALESCE(r.fixed_amount_ccy, round(pol.estimated_amount_ccy * r.percentage / 100.0, 2))
             ELSE NULL::numeric END AS retention_amount_ccy,
    r.released_at,
    r.released_by,
        CASE WHEN has_permission('data.view_prices'::text) THEN r.released_amount_ccy
             ELSE NULL::numeric END AS released_amount_ccy,
        CASE WHEN has_permission('data.view_prices'::text) THEN r.withheld_amount_ccy
             ELSE NULL::numeric END AS withheld_amount_ccy,
    r.withholding_reason
   FROM purchase_order_line_retentions r
   JOIN purchase_order_lines pol ON pol.id = r.purchase_order_line_id
   JOIN purchase_orders po ON po.id = pol.purchase_order_id
   JOIN fixed_assets fa ON fa.id = pol.asset_id
  WHERE has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.purchase_order_retention_status IS
'EQP-PAY-1:每一条质保金【现在】处在什么状态。★ maturity_date 是【算出来的】,
不是存下来的 —— fixed_assets.acceptance_date 一改,它当场跟着走(fixture 有一帧证明)。
四态:clock_not_started(还没验收 —— 不是错误,不是零)/ running / awaiting_confirmation
(到期了,【等人确认】,应付尚未成立)/ released。
【属主权限的理由】体内 JOIN 了 fixed_assets(module.finance.view),
一个只有采购权限的读者会让 INNER JOIN 整行消失 —— OPS-14 那一族的病。
所以用属主权限 + 把 module.purchasing.view 原样写回视图体,金额另按 data.view_prices 遮蔽。';

-- ═══ 8 · 放款确认:到期【提示】,由人确认 ═══════════════════════════════════

CREATE OR REPLACE FUNCTION public.release_purchase_order_retention(
    p_retention_id uuid,
    p_released_amount_ccy numeric,
    p_withheld_amount_ccy numeric,
    p_withholding_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_state    text;
    v_total    numeric;
    v_code     text;
    v_maturity date;
    v_user     uuid := auth.uid();
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    -- ★【为什么这里【不】读 purchase_order_retention_status】★ 那张视图体内带着
    -- has_permission('module.purchasing.view') 与按 data.view_prices 的金额遮蔽。
    -- 视图体里的谓词【不因为本函数是 DEFINER 而失效】—— 它是一个过滤条件,不是 RLS。
    -- 于是一个没有 data.view_prices 的调用者会拿到 retention_amount_ccy = NULL,
    -- 下面那条"放款+扣留必须等于总额"的校验会拿 NULL 去比,**结果是它不拦了**。
    -- 一道被遮蔽悄悄关掉的闸比没有闸更糟。所以判据一律从基表现算。
    SELECT po.code,
           CASE WHEN fa.acceptance_date IS NULL THEN NULL::date
                ELSE (fa.acceptance_date + (r.retention_months || ' months')::interval)::date END,
           CASE WHEN fa.acceptance_date IS NULL              THEN 'clock_not_started'
                WHEN r.released_at IS NOT NULL               THEN 'released'
                WHEN (fa.acceptance_date + (r.retention_months || ' months')::interval)::date
                     <= CURRENT_DATE                         THEN 'awaiting_confirmation'
                ELSE 'running' END,
           COALESCE(r.fixed_amount_ccy, round(pol.estimated_amount_ccy * r.percentage / 100.0, 2))
    INTO v_code, v_maturity, v_state, v_total
    FROM purchase_order_line_retentions r
    JOIN purchase_order_lines pol ON pol.id = r.purchase_order_line_id
    JOIN purchase_orders po ON po.id = pol.purchase_order_id
    JOIN fixed_assets fa ON fa.id = pol.asset_id
    WHERE r.id = p_retention_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RETENTION_NOT_FOUND|%', COALESCE(p_retention_id::text, '?');
    END IF;

    IF v_state = 'released' THEN
        RAISE EXCEPTION 'RETENTION_ALREADY_RELEASED|%', v_code;
    END IF;
    -- 【没验收就没有起算点】—— 这不是"还没到期",是【时钟还没开始走】。
    IF v_state = 'clock_not_started' THEN
        RAISE EXCEPTION 'RETENTION_CLOCK_NOT_STARTED|%', v_code
          USING HINT = '这台机器还没有验收日期(fixed_assets.acceptance_date)—— 质保期无从起算,更谈不上到期。先记验收(set_asset_acceptance)';
    END IF;
    -- 【提前放款等于把质保金废掉】质保金的全部意义是它在质保期内扣得下来。
    IF v_state = 'running' THEN
        RAISE EXCEPTION 'RETENTION_NOT_MATURE|%|%', v_code, v_maturity
          USING HINT = '质保期未满 —— 提前放款等于把质保金废掉。到期日由验收日推导,不是一个可以绕过的字面量';
    END IF;

    IF p_released_amount_ccy IS NULL OR p_withheld_amount_ccy IS NULL THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_AMOUNTS_REQUIRED'
          USING HINT = '放多少、扣多少都要明说 —— 两个都不给默认值';
    END IF;
    IF p_released_amount_ccy < 0 OR p_withheld_amount_ccy < 0 THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_AMOUNT_NEGATIVE|%|%', p_released_amount_ccy, p_withheld_amount_ccy;
    END IF;
    IF round(p_released_amount_ccy + p_withheld_amount_ccy, 2) <> round(v_total, 2) THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_DOES_NOT_BALANCE|%|%|%',
            v_code, round(p_released_amount_ccy + p_withheld_amount_ccy, 2), round(v_total, 2)
          USING HINT = '放款 + 扣留必须恰好等于质保金总额 —— 差额若允许存在,那笔钱就没有下落了';
    END IF;
    -- 扣了钱就要说为什么。表上那条 CHECK 也拦,这里【先】说一遍,好让走门的人
    -- 拿到一个具名拒绝,而不是一条约束原文。
    IF p_withheld_amount_ccy > 0 AND COALESCE(btrim(p_withholding_reason), '') = '' THEN
        RAISE EXCEPTION 'RETENTION_WITHHOLDING_NEEDS_REASON|%', v_code
          USING HINT = '扣留了质保金就要写明理由 —— 一笔没有理由的扣款,在供应商问起来的那天答不出来';
    END IF;

    UPDATE purchase_order_line_retentions
    SET released_at         = now(),
        released_by         = v_user,
        released_amount_ccy = p_released_amount_ccy,
        withheld_amount_ccy = p_withheld_amount_ccy,
        withholding_reason  = CASE WHEN p_withheld_amount_ccy > 0
                                   THEN btrim(p_withholding_reason) ELSE NULL END
    WHERE id = p_retention_id;

    RETURN jsonb_build_object(
        'retention_id', p_retention_id,
        'purchase_order_code', v_code,
        'retention_amount_ccy', round(v_total, 2),
        'released_amount_ccy', p_released_amount_ccy,
        'withheld_amount_ccy', p_withheld_amount_ccy,
        'withholding_reason', CASE WHEN p_withheld_amount_ccy > 0 THEN btrim(p_withholding_reason) END);
END;
$function$;

COMMENT ON FUNCTION public.release_purchase_order_retention(uuid, numeric, numeric, text) IS
'EQP-PAY-1:质保金放款【确认】。到期本身不产生任何应付 —— 到期只让状态变成
awaiting_confirmation,然后由一个人来确认这台机器在质保期内没出过毛病。
**自动放款会把质保金废掉**,所以本库里没有任何一支到期自动结算的路径。
可以部分扣留:放款 + 扣留必须恰好等于质保金总额,扣了就必须写理由。';

COMMIT;

-- ═══════════════════════════════════════════════════════════════════════════
-- 9 · create_purchase_order:门上那一半
--
-- 【实测的出发点】这支函数【今天对 trigger_event 一个字都不校验】—— 它直接
-- INSERT,让表上那条 CHECK 去炸。所以下面这两段是【新增的判据】,不是把既有的
-- 判据收紧:此前根本没有判据,屏幕上拿到的是一条裸约束原文。
--
-- 两段各对着一条要求:
--   ① 混装单具名拒绝(A2)——【在插入这一行之前】就拒,好让操作者拿到的是
--      "请开两张单",而不是表上那道 AFTER 触发器的原文;
--   ② 里程碑适用性具名拒绝(R5)—— 与 guard_payment_term_applicable 同一句话,
--      在这里【先】说一遍。两道闸都要在:一个禁用掉的下拉选项不是控制,
--      而一支只在函数里校验的规则挡不住直连 PostgREST 的那条路。
-- ═══════════════════════════════════════════════════════════════════════════

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
    -- ── EQP-PAY-1 ──────────────────────────────────────────────────────────
    v_seen_material boolean := false;  -- A2:混装单具名拒绝
    v_seen_asset    boolean := false;
    v_kind          text;              -- 'equipment' / 'material'
    v_applicable    boolean;           -- R5:这一期的里程碑用不用得上
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

        -- ── EQP-PAY-1(A2):混装单具名拒绝 ─────────────────────────────────
        -- 【在插入之前拒】表上那道 AFTER 触发器也拦得住,但它拿不到"该怎么办"
        -- 这句话。一张单要么全是材料、要么全是设备:两者的收货路径、成本处理
        -- (EQP-1b-ii 设备行一次性费用化)与付款里程碑都不同,混在一张单上
        -- 【没有一套里程碑是对的】—— 这正是本刀要修的那个缺陷的根。
        IF v_material IS NOT NULL THEN v_seen_material := true; END IF;
        IF v_asset    IS NOT NULL THEN v_seen_asset    := true; END IF;
        IF v_seen_material AND v_seen_asset THEN
            RAISE EXCEPTION 'PO_LINES_MIXED_KIND|%', v_code
              USING HINT = '一张单要么全是材料行、要么全是设备行 —— 请开两张单:一张订料,一张订机器';
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

    -- EQP-PAY-1:行落完了,所以这张单的种类【现在】问得出来。混装已在上面拒掉,
    -- 所以这两种情形互斥。
    v_kind := CASE WHEN v_seen_asset THEN 'equipment' ELSE 'material' END;

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
        'order_kind', v_kind
    );
END;
$function$;

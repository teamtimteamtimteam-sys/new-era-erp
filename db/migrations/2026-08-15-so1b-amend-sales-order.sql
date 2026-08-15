-- SO-1b(2026-08-15):销售订单的【改单】—— 而三条下限各自读的是一个真实的事实
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【调查先于设计,而这一次调查的结论与 PUR-2 那次【正好相反】】
-- PUR-2 查下来是"商业字段从来只是够不着,不是被保护"(采购单行一个触发器都没有)。
-- 销售这边反过来:SO-1 一上来就把确认之后的单头与单行【全部焊死】——
-- guard_sales_order_line_confirmed_immutable 对非草稿的增删改一律抛
-- SO_CONFIRMED_IMMUTABLE|lines,连一条合法的改单路径都没有。于是:
--
--   * 一张确认了的单填错一个数,唯一的出路是作废重开 —— 而作废会释放全部预留、
--     作废发票,把一次"把 12 改成 10"演成一次整单重来;
--   * 【而单头上有两列是漏出去的】notes 与 terms_text 不在冻结名单里,RLS 又
--     允许任何持 module.sales.edit 的人直连 UPDATE。也就是说:客户签收的那份
--     PDF 上印着的【条款正文】,今天可以被任何人悄悄改掉,不留任何痕迹,
--     而签发档(so_issues)只记"第几版、什么摘要",不会因为条款变了自己长一版。
--     这就是 §0(b):**一张已经签发出去的单,它的条款可以在客户不知情的情况下
--     与客户手里那份分道扬镳,而系统对此一言不发。**
--
-- 所以这一刀有两半,而且两半必须同一刀:
--   ① 把 notes / terms_text 【收进冻结名单】,只在改单上下文里可改 —— 缺了这一半,
--      加一个改单入口只是给已经通着的那条路加一个门面;
--   ② 给改单一条【可达且被记录】的路 —— 缺了这一半,①就只是把最后两列也焊死,
--      而"填错了只能作废重开"从此变成一条真规则,那不是修好,是把伤口缝上。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【三条下限,三个不同的事实 —— 而它们都不是"订量"】
-- 采购单只有一条下限(已收)。销售这边一条行同时被三件事咬住,而且三件事的
-- 【可逆性完全不同】,所以它们必须分开报、分开给出路:
--
--   已发(shipment_lines) 货离开了台账、收入落了账 —— **不可逆**。
--                        下限【硬】:改不到已发之下。边界在内 —— 改成【正好等于
--                        已发】是允许的,那正是一次短装收尾的写法(订 12 发 8,
--                        改成 8,这张单就发完了)。
--   已开票(invoice_lines) 一张在册的订单流发票认下了债(借 1100 / 贷 2500),
--                        而发票行不可变 —— **可逆,但要先作废那张票**。
--                        所以数量与单价【整个冻住】,消息里同时给出两条出路:
--                        作废发票,或者【另起一行】加量。
--   已预留(活预留)       货扣在 committed 桶里 —— **可逆,而且解铃的人必须留名**。
--                        下限【软】:拒绝,并把还扣着多少说出来,但**绝不替人释放**。
--                        自动释放会让"谁决定放弃这个承诺"这个问题失去答案,
--                        与调高信用额度让告警安静同族。
--
-- 【已发 + 活预留 = line_spoken_for,而那是 SO-3b fu5 留下的那一处推导】
-- 软下限读它,不另写一遍 —— fu5 的抬头已经把理由写死了:两份推导会在写下的
-- 那天一致,此后各自漂移,这个仓库为这条付过四次账。
--
-- 【三条的【顺序】也是判据的一部分:按"这件事有多不可逆"排】
-- 已发 → 已开票 → 已预留。把发票排前面,人会先去【作废一张发票】(总账里的
-- 一笔真冲销),然后才被告知货早就发出去了、这个数字本来就到不了那里 ——
-- 让人为一个注定失败的目标先做一件有后果的事,比拒绝得晚更坏。
--
-- 【一处诚实交代:短装收尾今天还走不通,而它不是这一刀能修的】
-- 选项 C 是先开票后发货,所以一条发过货的行【必然】坐在一张在册发票上,
-- 而 void_invoice 对发过货的票按名拒(INVOICE_SHIPPED_NOT_VOIDABLE)。
-- 于是"把行改到正好等于已发"会落到发票冻结上,被【另一个名字】拒掉。
-- 短装的正解是【贷项凭证】—— 客户已经按 12 被开票、只收到 8,那笔差额是
-- 一张贷项凭证,不是一次改单(sales_records 表头停放的那个未来概念)。
-- 在它落地之前,系统该做的是按名拒绝并说出是哪一张票挡着,而不是让订单
-- 悄悄与发票分道扬镳。fixture 70 把两个名字都钉住(7 → BELOW_SHIPPED、
-- 8 → LINE_INVOICED),那两条不同的拒绝正好证明边界确实在 8 上。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【永久冻结的五列,不分路径】customer_id / currency / fx_rate / order_date / code
-- 改了就是另一笔交易,重开一张,不是改这一张:
--   * customer_id —— 应收、敞口、发票、签发档全挂在这笔交易上,换人等于把它们
--     悄悄重指(与 PO 的 supplier_id 同一条);
--   * currency / fx_rate / order_date —— 【这三列是一体的,而且钱已经按它们动过了】
--     create_order_invoice 按订单存下来的 fx_rate 记 2500,ship_order 再按【发票
--     存下来的】汇率把 2500 换成收入。改动其中任何一列,都是在给一笔已经过账的
--     负债重新定价,而分录不会跟着动。
--     **PUR-2 的"改单据日就重取牌价"在这里【故意不成立】**:那条耦合之所以对,
--     是因为采购单的 fx_rate 只是一个【估价用的锚】,没有任何分录站在它上面;
--     销售这边它是【已经入账的那个数】。同一个动作,一边是重算,一边是改账。
--   * code —— 单号是对外说过的那个名字。
-- 改单函数【根本不接】这五列(草稿也不接:一张写错了客户的草稿,重开一张的成本
-- 是零)。而守卫对【非草稿】另外挡一遍,因为守卫要挡的是那条直连的 UPDATE。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【上下文标记:so_amend_ctx,新的一个,绝不复用 so_status_ctx】
-- so_status_ctx 的含义是"转换函数正在动状态列",而冻结守卫见到它就【整行放行】。
-- 拿它当改单的通行证,等于让改单顺手获得改状态的能力 —— 那正是 PUR-2 关掉的门。
-- 两个标记,两件事,各自 set → 语句 → 立刻清(fu2 的教训:set_config(..., true)
-- 是【事务】局部,不是语句局部;只在函数开头设一次,守卫会在这次调用之后、
-- 整个事务余下的时间里一直关着,一条直连的 UPDATE 就此畅通)。
--
-- 【草稿不设标记 —— 这一句同时兑现了两件事】草稿本来就可以随便改(守卫的第一个
-- 分支),所以它不需要通行证;而留痕触发器只在标记为 '1' 时写行,于是"草稿的
-- 编辑不进改单历史"是【同一个机制的推论】,不是第二条规则(PUR-2 的建单行不记
-- 历史用的就是这一条)。这也正是这张单一直缺的那个【草稿编辑器】的引擎:
-- 同一个函数,草稿态不要理由、不留改单历史。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【可改的状态:draft / confirmed / partially_shipped,加行时还认 shipped】
-- 前三个是"这张单还活着"。shipped 只开一条缝 ——【只许加行】,而加行会让状态
-- 按"已发 vs 已订"重新算出来,于是它自己翻回 partially_shipped。
-- 这不是特例,而是上面那条 SO_AMEND_LINE_INVOICED 的消息里"另起一行"那条出路
-- 【在整单发完之后仍然走得通】的前提:一张发完的单,客户再要 5 吨,今天只能
-- 另开一张单;有了这条缝,它是同一张单的第二段。
-- 状态推导因此从 ship_order 里【抽出来变成一个函数,两个消费方读同一份】——
-- 抄一份进改单,两边会在写下的那天一致、此后各自漂移(第五次付这笔账)。
-- closed / cancelled 一律 SO_NOT_AMENDABLE|单号|状态。
--
-- 【不查信用】开票才是产生敞口的那一步(SO-3a),额度的闸在那里。改单不查,
-- 而且理由不是"忘了":一次改单很可能正是【往下改】,拿信用冻结去拦一次
-- 减量,等于用一个安全机制挡住了唯一能降低敞口的动作。
--
-- 【为什么不撤掉 sales_orders / sales_order_lines 的 UPDATE、DELETE 策略】
-- 建单那一刀撤过 INSERT 策略(SO-2b:建单只有一扇门)。这里【故意不撤】剩下两条:
-- 守卫必须挡得住那条直连的路,而"挡得住"这件事只有在那条路【还通着】的时候
-- 才证明得了。撤掉策略,fixture 里那条直连 UPDATE 就会被 RLS 拒,于是它测的是
-- 策略,不是守卫 —— fixture 52 C 臂为这条区别写过一整段。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1 · 留痕表:成对的 old_*/new_*,与改动类型 ───────────────────────────────
-- 【为什么是成对的列,而不是一段 jsonb 或一句人话】PUR-2 选的就是这个,理由在
-- 那一刀的表注释里:机器读得懂的历史才能被查询、被比对、被做成"这一版与上一版
-- 差在哪"。一句 '数量 12 → 10' 只能被人眼读。
-- 【表头侧只有两列】—— 因为可改的只有这两列。其余的要么永久冻结,要么根本不存在。
ALTER TABLE public.sales_order_history
    ADD COLUMN sales_order_line_id uuid,      -- 行改动才有;删行时这个 id 已经不存在,故无外键
    ADD COLUMN line_no             integer,
    ADD COLUMN old_notes           text,
    ADD COLUMN new_notes           text,
    ADD COLUMN old_terms_text      text,
    ADD COLUMN new_terms_text      text,
    ADD COLUMN old_quantity        numeric,
    ADD COLUMN new_quantity        numeric,
    ADD COLUMN old_unit_price      numeric,
    ADD COLUMN new_unit_price      numeric,
    ADD COLUMN amend_reason        text;      -- 由 RPC 经 set_config 传进来(触发器读不到函数参数)

ALTER TABLE public.sales_order_history
    DROP CONSTRAINT IF EXISTS sales_order_history_change_type_check;
ALTER TABLE public.sales_order_history
    ADD CONSTRAINT sales_order_history_change_type_check CHECK (change_type IN
        ('created','confirmed','closed','cancelled','line_added','line_changed','line_removed','issued',
         'reserved','released','invoiced','invoice_voided','shipped',
         -- SO-1b:改单的四种。【与 line_added/line_changed/line_removed 并存,不是换名】
         -- 那三个是 SO-1 定下的、至今没有任何写入者的空位;这四个是【触发器】写的,
         -- 而且带着成对的 old_/new_ 与理由。把它们合并会让"这一行是怎么来的"
         -- 从两个不同的机制变成一个含混的名字。
         'header_update','line_update','line_add','line_remove'));

COMMENT ON COLUMN public.sales_order_history.amend_reason IS
    'SO-1b:这次改动的理由。由 amend_sales_order 经 set_config(''evoltrya.so_amend_reason'') 递给触发器 —— 触发器读不到函数参数。【草稿的编辑没有理由,也没有本表的行】:草稿还不是承诺,给它要一句解释是在给一件还没发生的事做记录。';

COMMENT ON COLUMN public.sales_order_history.sales_order_line_id IS
    'SO-1b:行改动指向的那一行。【没有外键,这是有意的】—— line_remove 那一行写下的时候,它指向的行正在被删掉。历史要记得住一个已经不存在的东西,否则最激烈的一种编辑(把这一行整个拿掉)会在历史里一言不发,而沉默读起来正好等于"什么都没改"。';

-- ── 2 · 表头守卫:notes / terms_text 加入冻结名单,只在改单上下文里可改 ──────
CREATE OR REPLACE FUNCTION public.guard_sales_order_confirmed_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 草稿随便改;作废/关闭之后也不该再改商业字段
    IF OLD.status = 'draft' THEN
        -- 状态列仍然只走转换函数
        IF current_setting('evoltrya.so_status_ctx', true) IS DISTINCT FROM '1'
           AND NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'SO_STATUS_NOT_EDITABLE|%|%', OLD.status, NEW.status;
        END IF;
        RETURN NEW;
    END IF;

    IF current_setting('evoltrya.so_status_ctx', true) = '1' THEN
        RETURN NEW;   -- 转换函数自己在动状态列
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【永久冻结的五列 —— 不认任何上下文标记】改了就是另一笔交易。
    -- 改单函数根本不接它们,而这里再挡一遍,是因为守卫要挡的是那条直连的 UPDATE
    -- (RLS 今天就允许任何持 module.sales.edit 的人对本表发 UPDATE)。
    -- 三列日期/币种/汇率是一体的:发票的 2500 就是按订单存下来的 fx_rate 记进去的,
    -- 发货再按发票存下来的汇率把它换成收入。动其中任何一列都是在给一笔已经过账的
    -- 负债重新定价,而分录不会跟着动 —— 所以 PUR-2 的"改单据日就重取牌价"在这里
    -- 【故意不成立】:那边 fx_rate 只是个估价用的锚,这边它是已经入账的那个数。
    -- ════════════════════════════════════════════════════════════════════════
    IF NEW.customer_id IS DISTINCT FROM OLD.customer_id THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|customer_id|%', OLD.code;
    END IF;
    IF NEW.currency IS DISTINCT FROM OLD.currency THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|currency|%', OLD.code;
    END IF;
    IF NEW.fx_rate IS DISTINCT FROM OLD.fx_rate THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|fx_rate|%', OLD.code;
    END IF;
    IF NEW.order_date IS DISTINCT FROM OLD.order_date THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|order_date|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|code|%', OLD.code;
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'SO_STATUS_NOT_EDITABLE|%|%', OLD.status, NEW.status;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【§0(b):notes 与 terms_text 此前不在名单里,而 terms_text 会印在客户手里
    -- 那份 PDF 上】—— 于是一张已经签发出去的单,它的条款可以被任何持
    -- module.sales.edit 的人直连改掉,不留痕迹、不升版本、不告诉任何人。
    -- 现在它们【也是冻结的】,唯一的出路是改单上下文 —— 走那条路会留下一行带
    -- 理由的 header_update,而详情页会据此说出"签发之后又改过"。
    -- 【为什么不干脆焊死】条款与备注本来就是要改的东西(付款方式谈定了、
    -- 交货地点变了)。焊死等于把一件日常动作赶回"作废重开"。
    -- ════════════════════════════════════════════════════════════════════════
    IF current_setting('evoltrya.so_amend_ctx', true) IS DISTINCT FROM '1' THEN
        IF NEW.notes IS DISTINCT FROM OLD.notes THEN
            RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|notes|%', OLD.code;
        END IF;
        IF NEW.terms_text IS DISTINCT FROM OLD.terms_text THEN
            RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|terms_text|%', OLD.code;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ── 3 · 行守卫:非草稿仍然全冻,但改单上下文是它的出口 ──────────────────────
CREATE OR REPLACE FUNCTION public.guard_sales_order_line_confirmed_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM sales_orders
     WHERE id = COALESCE(NEW.sales_order_id, OLD.sales_order_id);

    IF v_order.status = 'draft' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    -- SO-1b:【改单是这一堵墙上唯一的门】—— 而门后还有三条下限
    -- (trg_sales_order_lines_floors,按名字排在本守卫【之后】跑,所以直连的
    -- 那条路先撞上"确认之后行是冻的",而不是先撞上下限)。
    -- 【标记是 amend 专用的,不是 so_status_ctx】后者会让整行放行,包括状态列。
    IF current_setting('evoltrya.so_amend_ctx', true) = '1' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|lines|%', v_order.code;
END;
$function$;

-- ── 4 · 行的三条下限:已发 / 已开票 / 已预留 ────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_sales_order_line_floors()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line     record;
    v_status   text;
    v_shipped  numeric;
    v_spoken   numeric;
    v_reserved numeric;
    v_inv      text;
BEGIN
    v_line := CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;

    SELECT status INTO v_status FROM sales_orders WHERE id = v_line.sales_order_id;
    -- 【草稿早退】草稿单的行不可能有发货、发票或预留(三者各自都要求单据已确认),
    -- 所以这三条下限对它恒真 —— 早退是为了不让一次草稿编辑白白查三张表。
    IF v_status = 'draft' THEN
        RETURN v_line;
    END IF;

    -- 已发:货离开了台账。【读 shipment_lines,与 line_spoken_for 同一个理由】——
    -- 它是"货真的离开了"的记录,而 consumed_at 只是预留的终局标记。
    SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
      FROM shipment_lines sl WHERE sl.sales_order_line_id = v_line.id;

    -- 已许出去 = 已发 + 活预留。【一处推导,SO-3b fu5 的那一个】,不另写一遍。
    v_spoken   := line_spoken_for(v_line.id);
    v_reserved := v_spoken - v_shipped;

    -- 在册且已过账的订单流发票行。【与 ship_order 的判据逐字同一条】:
    -- 状态位会与真相漂开(作废一张票之后那个位还亮着),所以每次都现查。
    SELECT i.code INTO v_inv
      FROM invoice_lines il
      JOIN invoices i ON i.id = il.invoice_id
     WHERE il.sales_order_line_id = v_line.id
       AND NOT il.invoice_voided
       AND i.kind = 'order' AND i.status = 'issued'
     LIMIT 1;

    -- ── 删行:按【原因】点名,绝不让外键去报 ────────────────────────────────
    -- 【为什么不能靠外键】shipment_lines / invoice_lines / sales_order_reservations
    -- 都指着这一行,外键当然会拒 —— 但它吐出来的是一句约束名,操作员读到的是
    -- "违反外键约束 shipment_lines_sales_order_line_id_fkey",那句话既没说是哪一行,
    -- 也没说下一步该做什么。三个原因、三条出路,所以是三个名字。
    IF TG_OP = 'DELETE' THEN
        IF v_shipped > 0 THEN
            RAISE EXCEPTION 'SO_LINE_HAS_SHIPMENTS|%|%', OLD.line_no, trim_scale(v_shipped);
        END IF;
        IF v_inv IS NOT NULL THEN
            RAISE EXCEPTION 'SO_LINE_HAS_INVOICE|%|%', OLD.line_no, v_inv;
        END IF;
        IF v_reserved > 0 THEN
            RAISE EXCEPTION 'SO_LINE_HAS_RESERVATIONS|%|%', OLD.line_no, trim_scale(v_reserved);
        END IF;
        RETURN OLD;
    END IF;

    -- ── 改行:【三条下限按"这件事有多不可逆"排序】────────────────────────────
    -- 顺序是判据的一部分,不是随手写的:货已经出去 > 有一张在册的发票 > 货被扣着。
    -- 【为什么最不可逆的先说】把发票那一条排前面,人会去【作废一张发票】——
    -- 那是一次真的过账动作(总账里的一笔冲销)—— 然后才被告知货早就发出去了,
    -- 这个数字本来就到不了那里。让人为一个注定失败的目标先做一件有后果的事,
    -- 比拒绝得晚更坏。
    --
    -- 【已发:硬下限,边界在内】严格小于才拒:货已经出去了,单据不能宣称我们
    -- 答应的比发出去的还少。改成【正好等于已发】不触发这一条 —— 那本该是一次
    -- 短装收尾的写法(订 12 发 8,把行改成 8,这张单就发完了)。
    --
    --   ※【今天它还走不通,而这一句是本刀的一处诚实交代】选项 C 是【先开票
    --     后发货】,所以一条发过货的行【必然】坐在一张在册发票上,而
    --     void_invoice 对发过货的票按名拒(INVOICE_SHIPPED_NOT_VOIDABLE)。
    --     于是"改到正好等于已发"会落到下面那条发票冻结上,被另一个名字拒掉。
    --     那不是这条下限写错了 —— 短装的正解是【贷项凭证】(sales_records 表头
    --     停放的未来概念:客户已经按 12 被开票、只收到 8)。没有贷项凭证之前,
    --     系统该做的是【按名拒绝并说出是哪一张票挡着】,而不是让订单悄悄与
    --     发票分道扬镳。fixture 70 把这两个名字都钉住:7 → BELOW_SHIPPED,
    --     8 → LINE_INVOICED,两条不同的拒绝证明边界确实在 8 上。
    IF NEW.quantity < v_shipped THEN
        RAISE EXCEPTION 'SO_LINE_BELOW_SHIPPED|%|%|%',
            NEW.line_no, trim_scale(v_shipped), trim_scale(NEW.quantity);
    END IF;

    -- 【已开票:数量与单价整个冻住】那张发票认下的债已经过了账(借 1100 / 贷 2500),
    -- 而发票行不可变;而且 create_order_invoice 开的就是【整行的数量】,所以
    -- 任何一次改动都会让两张单据各说各的 —— 而客户手里那张是发票。
    -- 消息里给出【两条】出路,因为它们对应两种不同的意图:
    -- 数字错了 → 作废那张票再改;客户要加量 → 另起一行(整单发完之后仍然走得通,
    -- 见本文件抬头那条 shipped 的缝)。
    IF v_inv IS NOT NULL
       AND (NEW.quantity IS DISTINCT FROM OLD.quantity
            OR NEW.unit_price IS DISTINCT FROM OLD.unit_price) THEN
        RAISE EXCEPTION 'SO_AMEND_LINE_INVOICED|%|%', OLD.line_no, v_inv;
    END IF;

    -- 【已预留:软下限 —— 拒绝,并把数说出来,但绝不替人释放】
    -- 自动释放会让"谁决定放弃这个承诺"这个问题失去答案:release_reservation 要
    -- 理由、记名字、进订单历史,而一次顺手的自动释放三样都没有。
    -- 与调高信用额度让告警安静同族:让系统替操作员做掉那个决定,决定就消失了。
    IF NEW.quantity < v_spoken THEN
        RAISE EXCEPTION 'SO_LINE_BELOW_RESERVED|%|%|%',
            NEW.line_no, trim_scale(v_reserved), trim_scale(NEW.quantity);
    END IF;

    RETURN NEW;
END;
$function$;

-- 【触发器名排在 trg_sales_order_lines_confirmed_immutable 之后】(c < f):
-- 同级 BEFORE 触发器按名字排,于是直连的那条路先撞上"确认之后行是冻的",
-- 而不是先撞上一条下限 —— 后者会让人以为"只要数量够大就能直连改行"。
CREATE TRIGGER trg_sales_order_lines_floors
    BEFORE UPDATE OR DELETE ON public.sales_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_order_line_floors();

-- ── 5 · 留痕触发器:表头与明细各一,【只在改单上下文里写】──────────────────
CREATE OR REPLACE FUNCTION public.trg_so_history_header()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【只在改单上下文里写 —— 这一句同时是"草稿不留改单历史"那条规矩的实现】
    -- 草稿态的 amend_sales_order 根本不设这个标记(它不需要通行证),于是草稿的
    -- 编辑自然不进本表。不是第二条规则,是同一个机制的推论(PUR-2 的建单行不记
    -- 历史用的就是这一条)。
    -- 状态转换也不进来:它们走 so_status_ctx,而且各自已经在 change_type 上有
    -- 自己的一行 —— 记进来会让编辑史被状态噪音淹掉。
    IF current_setting('evoltrya.so_amend_ctx', true) IS DISTINCT FROM '1' THEN
        RETURN NEW;
    END IF;
    -- 只记【商业字段】的改动:updated_at/updated_by 的变化不是编辑史。
    IF NEW.notes IS NOT DISTINCT FROM OLD.notes
       AND NEW.terms_text IS NOT DISTINCT FROM OLD.terms_text THEN
        RETURN NEW;
    END IF;

    INSERT INTO sales_order_history (sales_order_id, change_type,
        old_notes, new_notes, old_terms_text, new_terms_text, amend_reason)
    VALUES (NEW.id, 'header_update',
        OLD.notes, NEW.notes, OLD.terms_text, NEW.terms_text,
        NULLIF(current_setting('evoltrya.so_amend_reason', true), ''));
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_sales_orders_history
    AFTER UPDATE ON public.sales_orders
    FOR EACH ROW EXECUTE FUNCTION public.trg_so_history_header();

CREATE OR REPLACE FUNCTION public.trg_so_history_line()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(current_setting('evoltrya.so_amend_reason', true), '');
BEGIN
    -- 见表头那一支:标记不在就不写。【建单的那一批行因此不记】—— 否则每张新单
    -- 都会先长出一份"全是新增"的历史,把真正的修改埋掉。建单本身有 'created' 那一行。
    IF current_setting('evoltrya.so_amend_ctx', true) IS DISTINCT FROM '1' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO sales_order_history (sales_order_id, sales_order_line_id, line_no,
            change_type, new_quantity, new_unit_price, amend_reason)
        VALUES (NEW.sales_order_id, NEW.id, NEW.line_no, 'line_add',
            NEW.quantity, NEW.unit_price, v_reason);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO sales_order_history (sales_order_id, sales_order_line_id, line_no,
            change_type, old_quantity, old_unit_price, amend_reason)
        VALUES (OLD.sales_order_id, OLD.id, OLD.line_no, 'line_remove',
            OLD.quantity, OLD.unit_price, v_reason);
        RETURN OLD;
    END IF;

    IF NEW.quantity IS NOT DISTINCT FROM OLD.quantity
       AND NEW.unit_price IS NOT DISTINCT FROM OLD.unit_price THEN
        RETURN NEW;
    END IF;
    INSERT INTO sales_order_history (sales_order_id, sales_order_line_id, line_no,
        change_type, old_quantity, new_quantity, old_unit_price, new_unit_price, amend_reason)
    VALUES (NEW.sales_order_id, NEW.id, NEW.line_no, 'line_update',
        OLD.quantity, NEW.quantity, OLD.unit_price, NEW.unit_price, v_reason);
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_sales_order_lines_history
    AFTER INSERT OR UPDATE OR DELETE ON public.sales_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.trg_so_history_line();

-- ── 6 · 履约状态的推导:【一处,两个消费方】────────────────────────────────
CREATE OR REPLACE FUNCTION public.sales_order_fulfilment_status(p_sales_order_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- SO-1b:【已发 vs 已订】—— 这张单是发完了,还是发了一部分。
    --
    -- 【为什么是一个函数】此前它写在 ship_order 的函数体里。改单需要同一个判断
    -- (加一行会让一张发完的单退回 partially_shipped;把一行改到正好等于已发会让
    -- 一张短装的单变成 shipped),抄一份过去,两边会在写下的那天一致、此后各自
    -- 漂移 —— 这个仓库为这条形状付过四次账(验资影响预览、GrantRunner、重估预览、
    -- /finance/payments),SO-3b fu5 的 line_spoken_for 是第五次。
    --
    -- 【只回答这两个值】confirmed(一件没发)不在此列:调用方自己知道该不该问。
    -- 一个"没发货就返回 confirmed"的版本会让改单顺手把状态往回推,而那是一次
    -- 【状态转换】,要走 set_sales_order_status。
    SELECT CASE
        WHEN COALESCE((SELECT sum(sl.qty)
                         FROM shipment_lines sl
                         JOIN shipments s ON s.id = sl.shipment_id
                        WHERE s.sales_order_id = p_sales_order_id), 0)
             >= COALESCE((SELECT sum(l.quantity)
                            FROM sales_order_lines l
                           WHERE l.sales_order_id = p_sales_order_id), 0)
        THEN 'shipped' ELSE 'partially_shipped' END;
$function$;

COMMENT ON FUNCTION public.sales_order_fulfilment_status(uuid) IS
    'SO-1b:一张单的履约状态 —— 已发 vs 已订,只回答 shipped / partially_shipped。【一处推导,两个消费方】:ship_order(发完货之后写状态)与 amend_sales_order(加行/减量之后重算状态)。没有调用者检查,靠的就是调不到(zzz_function_grants 里对 authenticated 收权)—— 它逐张吐露别人订单的发货进度,而那是 module.sales.view 的东西。';

-- ── 7 · ship_order:状态推导改读那一处 ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ship_order(p_sales_order_id uuid, p_ship_date date, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_order    sales_orders%ROWTYPE;
    v_ship_id  uuid := gen_random_uuid();
    v_code     text;
    v_item     jsonb;
    v_res      record;
    v_res_id   uuid;
    v_split    jsonb;
    v_inv      record;
    v_line_ids uuid[] := ARRAY[]::uuid[];
    v_mv       uuid;
    v_sl_id    uuid;
    v_sale_id  uuid;
    v_rev_ccy  numeric := 0;
    v_rev_base numeric := 0;
    v_fx       numeric;
    v_unit     numeric;
    v_cogs     numeric;
    v_je1      jsonb;
    v_je2      jsonb;
    v_rem      numeric;
    v_state    text;
    v_ordered  numeric;
    v_shipped  numeric;
    v_status   text;
    v_n        int;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 与 reserve_stock 逐字同一条:发货【就是】一次销售行为,做它的人是销售。
    -- 给它挑一个"销售与库存都满足"的权限码,只能挑一个比两者都松的 ——
    -- 那不是把关、是把关的样子(zzz_function_grants 给 drain_stock 写的理由)。
    -- 台账的不变量不依赖调用者是谁:check_no_negative_bucket 是约束触发器,
    -- check_ledger_invariant 也是,对任何身份一视同仁。
    --
    -- 【收入与 COGS 的过账也在这里,而它们是财务的事】—— 但把这一步拆成
    -- "销售发货 + 财务过账"两次调用,就等于允许一个【发了货却没记收入】的
    -- 中间态存在。选项 C 的整条链是一个事务,所以它是一个函数。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM require_permission('module.sales.edit');

    -- 【发货日必填,永不默认】物理事件日,而且它决定收入落进哪个会计期间。
    IF p_ship_date IS NULL THEN
        RAISE EXCEPTION 'SHIP_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_order FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_SHIP_ORDER_NOT_SHIPPABLE|%|%', v_order.code, v_order.status;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'SO_SHIP_NO_LINES|%', v_order.code;
    END IF;

    v_code := next_shipment_code(p_ship_date);
    INSERT INTO shipments (id, code, sales_order_id, ship_date, notes, created_by)
    VALUES (v_ship_id, v_code, p_sales_order_id, p_ship_date, NULL, v_user);

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_res_id := NULLIF(v_item->>'reservation_id', '')::uuid;

        SELECT r.id, r.sales_order_line_id, r.output_batch_id, r.location_id, r.qty,
               r.released_at, r.consumed_at,
               l.line_no, l.unit_price, l.sales_order_id,
               l.price_source, l.price_provenance
          INTO v_res
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE r.id = v_res_id
         FOR UPDATE OF r;
        -- 【不是这张单的预留 / 不存在 / 已释放 / 已发过 —— 都是"没有这条预留"】
        IF NOT FOUND OR v_res.sales_order_id <> p_sales_order_id
           OR v_res.released_at IS NOT NULL OR v_res.consumed_at IS NOT NULL THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_RESERVED|%', COALESCE(v_res_id::text, '?');
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【先开票后发货 —— 而判据是【派生】的,不是订单上的一个状态位】
        -- 这一行必须坐在一张【在册且已过账】的订单流发票上。状态位会与真相
        -- 漂开(作废一张票之后那个位还亮着),而这个问题每次都问得起。
        -- 顺带把那张票的【存下来的汇率】取出来:释放负债要按它,不按今天的行情
        -- —— 2500 里躺着的就是按它记进去的那个数(FIN-27 一族)。
        -- ════════════════════════════════════════════════════════════════════
        SELECT i.id, i.code, i.fx_rate, i.currency
          INTO v_inv
          FROM invoice_lines il
          JOIN invoices i ON i.id = il.invoice_id
         WHERE il.sales_order_line_id = v_res.sales_order_line_id
           AND NOT il.invoice_voided
           AND i.kind = 'order' AND i.status = 'issued'
         LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_INVOICED|%|%', v_order.code, v_res.line_no;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【部分发货:先把预留拆开,再整条消耗】(SO-2 的形状,一处实现)
        -- release_reservation(id, 要放回的数量, 理由) = 整笔释放 + 就地重新
        -- 预留剩余。所以要发 q(< 预留量 r)时,先把 (r − q) 放回 available,
        -- 剩下的那条新预留就正好是 q,然后【整条】消耗它。
        -- 【为什么不直接从这条预留里取走 q】那会让"committed 桶 = Σ 活预留"
        -- 不再成立:剩余的 (r − q) 还在桶里,却没有任何一行说它属于谁 ——
        -- 而 create_stock_transfer 的整桶搬正是靠那条不变量。
        -- 【也不在这里抄一份拆分逻辑】拆分只有一处实现,就是 release_reservation。
        -- ════════════════════════════════════════════════════════════════════
        IF (v_item->>'qty') IS NOT NULL AND (v_item->>'qty')::numeric <> v_res.qty THEN
            IF (v_item->>'qty')::numeric <= 0 OR (v_item->>'qty')::numeric > v_res.qty THEN
                RAISE EXCEPTION 'SO_SHIP_EXCEEDS_RESERVATION|%|%', v_item->>'qty', v_res.qty;
            END IF;
            v_split := release_reservation(v_res.id, v_res.qty - (v_item->>'qty')::numeric,
                                           'partial shipment ' || v_code);
            v_res_id := (v_split->'rereserved'->>'reservation_id')::uuid;
            SELECT r.id, r.sales_order_line_id, r.output_batch_id, r.location_id, r.qty,
                   l.line_no, l.unit_price, l.price_source, l.price_provenance
              INTO v_res
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE r.id = v_res_id;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【出库:直接写,不走 drain_stock】—— 预留【就是地址】(哪一批、哪个
        -- 库位、多少),所以这是一次【定址消耗】。drain_stock 是给【没有地址】
        -- 的消耗用的策略排空器(销售直接卖、投料、注销):它按 NULL 桶优先、
        -- 再按库位 code 升序去猜该动哪一份。这里没有可猜的 —— 猜反而会取错桶。
        -- 两个函数的函数头互相指着对方,免得下一个人以为这里漏用了它。
        -- ════════════════════════════════════════════════════════════════════
        INSERT INTO inventory_movements
            (output_batch_id, location_id, movement_type, qty_delta, stock_status,
             business_date, notes, created_by)
        VALUES (v_res.output_batch_id, v_res.location_id, 'sale', -v_res.qty, 'committed',
                p_ship_date, 'shipped ' || v_code, v_user)
        RETURNING id INTO v_mv;

        -- 销售记录:一条腿一行。价格与币种取【订单】的,汇率取【发票存下来的】。
        -- 出处从订单行原样抄过来(FIN-26:记录,不推断)。
        -- sales_order_line_id 就是那个标记 —— 它让这一行【不产生应收】
        -- (ar_open_items 第一支与 customer_ar_exposure_base 第一项都排除它)。
        INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                                   currency, fx_rate, amount_base, sale_date, notes,
                                   created_by, price_source, price_provenance,
                                   sales_order_line_id)
        VALUES (v_res.output_batch_id, v_order.customer_id, v_res.qty, v_res.unit_price,
                v_order.currency, v_inv.fx_rate,
                round(v_res.qty * v_res.unit_price * v_inv.fx_rate, 2),
                p_ship_date, 'shipped ' || v_code || ' · ' || v_order.code,
                v_user, v_res.price_source, v_res.price_provenance,
                v_res.sales_order_line_id)
        RETURNING id INTO v_sale_id;

        -- SO-2b:腿表 —— 一条出库腿一行(这里恰好一条,因为消耗是定址的)
        INSERT INTO sales_record_movements (sales_record_id, movement_id)
        VALUES (v_sale_id, v_mv);

        INSERT INTO shipment_lines (shipment_id, sales_order_line_id, reservation_id,
                                    output_batch_id, location_id, qty, sales_record_id)
        VALUES (v_ship_id, v_res.sales_order_line_id, v_res.id,
                v_res.output_batch_id, v_res.location_id, v_res.qty, v_sale_id)
        RETURNING id INTO v_sl_id;

        -- 预留的第二种终局:【消耗】。没有反向流水 —— 货离开了台账。
        -- 【不回写 shipment_line_id】那一列不存在:shipment_lines.reservation_id
        -- 已经是 UNIQUE,反向指针是冗余的,而两表互指会让镜像循环依赖、
        -- 重建排不出建表顺序(verify_rebuild 当场抓到过)。
        UPDATE sales_order_reservations
           SET consumed_at = now(), consumed_by = v_user
         WHERE id = v_res.id;

        -- 库存缓存:与 record_output_sale 逐字同一套(remaining_qty 与 state)
        SELECT remaining_qty INTO v_rem FROM output_batches WHERE id = v_res.output_batch_id FOR UPDATE;
        v_rem := v_rem - v_res.qty;
        v_state := CASE WHEN v_rem = 0 THEN '已售罄' ELSE '部分售出' END;
        UPDATE output_batches
           SET remaining_qty = v_rem, state = v_state, updated_by = v_user, updated_at = now()
         WHERE id = v_res.output_batch_id;

        -- COGS:与 record_output_sale 逐字同形 —— 有产出腿单位成本才挂,
        -- 没有就等 allocate_processing_costs 补挂(它读 sales_records,
        -- 而这一行就是一条普通的 sales_records,所以它自然看得见)。
        SELECT po.unit_cost_base INTO v_unit
        FROM processing_outputs po WHERE po.output_batch_id = v_res.output_batch_id LIMIT 1;
        IF v_unit IS NOT NULL THEN
            v_cogs := round(v_res.qty * v_unit, 2);
            IF v_cogs <> 0 THEN
                v_je2 := post_journal_entry(
                    p_ship_date,
                    'COGS ' || (SELECT code FROM output_batches WHERE id = v_res.output_batch_id),
                    'shipment', v_sale_id,
                    jsonb_build_array(
                        jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                        jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
                UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
            END IF;
        END IF;

        -- 收入侧按【发票存下来的汇率】累计(一张发货单属于一张订单,所以一个汇率)
        v_fx := v_inv.fx_rate;
        v_rev_ccy := v_rev_ccy + round(v_res.qty * v_res.unit_price, 2);
        v_line_ids := v_line_ids || v_res.sales_order_line_id;
    END LOOP;

    v_rev_base := round(v_rev_ccy * v_fx, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 【过账:借 2500 释放合同负债 / 贷 4000 收入】单据币种,按发票存下来的汇率。
    -- 这就是选项 C 的第二步 —— 开票认了债(借 1100 / 贷 2500),发货把那笔
    -- 负债换成收入。2500 因此在一张单全部发完之后精确归零(fixture 68 钉住)。
    -- ════════════════════════════════════════════════════════════════════════
    v_je1 := post_journal_entry(
        p_ship_date,
        'Shipment ' || v_code || ' · ' || v_order.code,
        'shipment', v_ship_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2500', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_rev_ccy, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_rev_ccy, 'fx_rate', v_fx)));

    -- ════════════════════════════════════════════════════════════════════════
    -- 【订单状态是【现算】出来的,不是人点的】已发 vs 已订,逐行比。
    -- 经 so_status_ctx 写入 —— 冻结守卫据此知道是"函数在动状态列"。
    -- 【SO-1b:这段推导搬进了 sales_order_fulfilment_status,两个消费方读同一份】
    -- 改单也要问同一个问题(加一行 / 把一行改到正好等于已发),抄一份过去,
    -- 两边会在写下的那天一致、此后各自漂移。v_ordered / v_shipped 仍然算,
    -- 因为下面那行历史要把 "已发/已订" 印出来 —— 那是【展示】,不是判据。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT COALESCE(sum(l.quantity), 0) INTO v_ordered
      FROM sales_order_lines l WHERE l.sales_order_id = p_sales_order_id;
    SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
      FROM shipment_lines sl JOIN shipments s ON s.id = sl.shipment_id
     WHERE s.sales_order_id = p_sales_order_id;
    v_status := sales_order_fulfilment_status(p_sales_order_id);

    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status = v_status, updated_at = now(), updated_by = v_user
     WHERE id = p_sales_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (p_sales_order_id, 'shipped',
            v_code || ' · ' || trim_scale(v_shipped)::text || '/' || trim_scale(v_ordered)::text,
            v_user);

    -- 【断言,不是假设】发货行的条数必须等于递进来的条数。将来有人给上面任何
    -- 一段加一个提前 CONTINUE,这里当场炸,而不是留下一张少了几行的发货单
    -- (而那张单的收入分录已经按【全部】行算过了)。
    SELECT count(*) INTO v_n FROM shipment_lines WHERE shipment_id = v_ship_id;
    IF v_n <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'SO_SHIP_LINES_LOST|%|%', jsonb_array_length(p_lines), v_n;
    END IF;

    RETURN jsonb_build_object(
        'shipment_id', v_ship_id,
        'code', v_code,
        'ship_date', p_ship_date,
        'line_count', v_n,
        'revenue_ccy', v_rev_ccy,
        'revenue_base', v_rev_base,
        'currency', v_order.currency,
        'fx_rate', v_fx,
        'order_status', v_status,
        'revenue_journal', v_je1->>'code');
END;
$function$;

-- ── 8 · 改单本身 ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.amend_sales_order(p_order_id uuid, p_reason text, p_header jsonb DEFAULT NULL::jsonb, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_order    sales_orders%ROWTYPE;
    v_draft    boolean;
    v_addonly  boolean;
    v_ctx      boolean;
    v_reason   text;
    v_el       jsonb;
    v_line_id  uuid;
    v_qty      numeric;
    v_price    numeric;
    v_no       integer;
    v_changed  integer := 0;
    v_status   text;
    -- 【为什么不是 FOUND】PERFORM set_config(...) 【自己会重设 FOUND】,而清标记
    -- 那一句正好夹在语句与判断之间 —— 于是 "IF NOT FOUND" 问的会是 set_config 的
    -- 结果,不是那条 DELETE/UPDATE 的。行数当场取走,再清标记。
    v_rows     integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders
     WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    v_draft   := (v_order.status = 'draft');
    v_addonly := (v_order.status = 'shipped');

    -- 【可改的状态,逐个写出来】closed / cancelled 一律拒:一张走完了的单、
    -- 一张作废了的单,要改就先让状态变化成为一次有记录的动作 —— 而这两个都是
    -- 终态,所以真正的答案是"另开一张"。
    IF v_order.status NOT IN ('draft', 'confirmed', 'partially_shipped', 'shipped') THEN
        RAISE EXCEPTION 'SO_NOT_AMENDABLE|%|%', v_order.code, v_order.status;
    END IF;

    -- 【shipped 只开一条缝:加行】—— 见本文件抬头。表头一个字都不能动
    -- (发完的单,它的条款已经履行完了),既有的行也不能动(每一行都在
    -- 发货与发票后面)。加一行是一件【新的承诺】,而状态会自己翻回去。
    IF v_addonly THEN
        IF p_header IS NOT NULL THEN
            RAISE EXCEPTION 'SO_NOT_AMENDABLE|%|%', v_order.code, v_order.status;
        END IF;
        IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array'
           AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) e
                        WHERE NULLIF(e->>'id', '') IS NOT NULL) THEN
            RAISE EXCEPTION 'SO_NOT_AMENDABLE|%|%', v_order.code, v_order.status;
        END IF;
    END IF;

    -- 【理由必填 —— 但草稿不要】一次改动没有理由,历史上就只是一行"数字变了"。
    -- 草稿还不是承诺:给一件还没发生的事要一句解释,只会训练人随手敲一个句号。
    IF NOT v_draft AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'SO_AMEND_REASON_REQUIRED|%', v_order.code;
    END IF;
    v_reason := btrim(COALESCE(p_reason, ''));

    -- 【草稿不设标记】它不需要通行证(守卫的第一个分支就放行),而留痕触发器
    -- 只在标记为 '1' 时写行 —— 于是"草稿的编辑不进改单历史"是同一个机制的推论。
    v_ctx := NOT v_draft;

    -- ── 表头:能改的只有 notes 与 terms_text ────────────────────────────────
    IF p_header IS NOT NULL AND jsonb_typeof(p_header) = 'object' THEN
        -- 【set → 语句 → 立刻清,每一条语句都这样】(PUR-2 fu2 的教训)
        -- set_config(..., true) 是【事务】局部而不是语句局部:只在函数开头设一次,
        -- 守卫会在这次调用之后、整个事务余下的时间里一直关着,一条直连的 UPDATE
        -- 就此畅通。下面重复出现的这三行不是啰嗦,它们【就是】那条规矩。
        IF v_ctx THEN
            PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
            PERFORM set_config('evoltrya.so_amend_reason', v_reason, true);
        END IF;
        UPDATE sales_orders SET
            notes = CASE WHEN p_header ? 'notes'
                         THEN NULLIF(btrim(COALESCE(p_header->>'notes', '')), '') ELSE notes END,
            terms_text = CASE WHEN p_header ? 'terms_text'
                         THEN NULLIF(btrim(COALESCE(p_header->>'terms_text', '')), '') ELSE terms_text END,
            updated_at = now(), updated_by = v_user
        WHERE id = p_order_id;
        IF v_ctx THEN
            PERFORM set_config('evoltrya.so_amend_ctx', '', true);
            PERFORM set_config('evoltrya.so_amend_reason', '', true);
        END IF;
    END IF;

    -- ── 明细 ────────────────────────────────────────────────────────────────
    -- 【五列身份字段一个都不在这里】customer_id / currency / fx_rate / order_date /
    -- code 不接;行的 material_id 也不接 —— 一行的物料就是这一行本身,换掉它
    -- 等于换一行,而"换一行"在这个函数里写得出来:先 remove,再 add(两者各自
    -- 都要过下限守卫,所以这条路不会绕开任何一条规则)。
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_line_id := NULLIF(v_el->>'id', '')::uuid;

            -- 删行
            IF COALESCE((v_el->>'remove')::boolean, false) THEN
                IF v_line_id IS NULL THEN
                    RAISE EXCEPTION 'SO_LINE_REMOVE_NEEDS_ID|%', v_order.code;
                END IF;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
                    PERFORM set_config('evoltrya.so_amend_reason', v_reason, true);
                END IF;
                DELETE FROM sales_order_lines
                 WHERE id = v_line_id AND sales_order_id = p_order_id;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '', true);
                    PERFORM set_config('evoltrya.so_amend_reason', '', true);
                END IF;
                IF v_rows = 0 THEN
                    RAISE EXCEPTION 'SO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
                v_changed := v_changed + 1;
                CONTINUE;
            END IF;

            v_qty   := NULLIF(v_el->>'quantity', '')::numeric;
            v_price := NULLIF(v_el->>'unit_price', '')::numeric;

            IF v_line_id IS NULL THEN
                -- 新增行:与建单同口径(数量与单价都必须为正,CHECK 也这么写着;
                -- 点名拒而不是让约束去报 —— 表单上有二十个格子,一句"违反约束"
                -- 等于让人自己去数是哪一格,SO_CREATE_LINE_INVALID 付过这笔账)
                IF v_qty IS NULL OR v_qty <= 0 THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', '+'), 'quantity';
                END IF;
                IF v_price IS NULL OR v_price <= 0 THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', '+'), 'unit_price';
                END IF;
                IF NULLIF(v_el->>'material_id', '') IS NULL THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', '+'), 'material_id';
                END IF;
                SELECT COALESCE(MAX(line_no), 0) + 1 INTO v_no
                  FROM sales_order_lines WHERE sales_order_id = p_order_id;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
                    PERFORM set_config('evoltrya.so_amend_reason', v_reason, true);
                END IF;
                -- 【price_source / price_provenance 留空,而这不是遗漏】FIN-26:
                -- 出处是【记录】的,不是事后【推断】的。改单上手敲进来的价格
                -- 没有出处可记,编一条("按当时的公式")比留空坏得多。
                INSERT INTO sales_order_lines
                    (sales_order_id, line_no, material_id, quantity, unit_price, notes)
                VALUES (p_order_id, v_no, (v_el->>'material_id')::uuid, v_qty, v_price,
                        NULLIF(btrim(COALESCE(v_el->>'notes', '')), ''));
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '', true);
                    PERFORM set_config('evoltrya.so_amend_reason', '', true);
                END IF;
            ELSE
                -- 改行:数量与单价。三条下限由触发器把关,它看得见每一条路径。
                IF v_qty IS NULL OR v_qty <= 0 THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', v_line_id::text), 'quantity';
                END IF;
                IF v_el ? 'unit_price' AND (v_price IS NULL OR v_price <= 0) THEN
                    RAISE EXCEPTION 'SO_AMEND_LINE_INVALID|%|%',
                        COALESCE(v_el->>'line_no', v_line_id::text), 'unit_price';
                END IF;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
                    PERFORM set_config('evoltrya.so_amend_reason', v_reason, true);
                END IF;
                UPDATE sales_order_lines SET
                    quantity   = v_qty,
                    unit_price = CASE WHEN v_el ? 'unit_price' THEN v_price ELSE unit_price END
                WHERE id = v_line_id AND sales_order_id = p_order_id;
                GET DIAGNOSTICS v_rows = ROW_COUNT;
                IF v_ctx THEN
                    PERFORM set_config('evoltrya.so_amend_ctx', '', true);
                    PERFORM set_config('evoltrya.so_amend_reason', '', true);
                END IF;
                IF v_rows = 0 THEN
                    RAISE EXCEPTION 'SO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
            END IF;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 履约状态重算 ────────────────────────────────────────────────────────
    -- 【只对已经在履约里的单重算】confirmed(一件没发)重算会得到
    -- partially_shipped,那等于让改单顺手把状态往前推 —— 而那是发货干的事。
    -- 两个方向都真的会发生:
    --   * 加一行 → 一张 shipped 的单退回 partially_shipped;
    --   * 把一行改到正好等于已发(短装收尾)→ partially_shipped 变成 shipped。
    -- 【不为这次翻转另写一行历史】状态在这里是【推导出来的】,不是一次动作 ——
    -- 造成它的那次改动已经有自己的一行(line_add / line_update),再写一行
    -- "状态变了"是把一个结果记成一个决定。返回值把新状态带回去。
    v_status := v_order.status;
    IF v_order.status IN ('partially_shipped', 'shipped') THEN
        v_status := sales_order_fulfilment_status(p_order_id);
        IF v_status IS DISTINCT FROM v_order.status THEN
            PERFORM set_config('evoltrya.so_status_ctx', '1', true);
            UPDATE sales_orders
               SET status = v_status, updated_at = now(), updated_by = v_user
             WHERE id = p_order_id;
            PERFORM set_config('evoltrya.so_status_ctx', '', true);
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'sales_order_id', p_order_id,
        'code', v_order.code,
        'status', v_status,
        'lines_changed', v_changed,
        -- 草稿的编辑【不进】改单历史 —— 把这件事说出来,免得调用方以为写了
        'history_written', v_ctx);
END;
$function$;

COMMENT ON FUNCTION public.amend_sales_order(uuid, text, jsonb, jsonb) IS
    'SO-1b:销售订单改单的唯一入口。【判据不在这里,在触发器上】—— 五列身份字段由 guard_sales_order_confirmed_immutable 永久冻结(不认任何上下文),三条行下限(已发硬、已开票冻、已预留软)由 guard_sales_order_line_floors 把关,留痕由两个触发器写。本函数负责的是:权限、状态闸、理由、以及【上下文标记的 set → 语句 → 立刻清】(PUR-2 fu2:set_config 是事务局部而不是语句局部)。草稿态不要理由、不设标记、不留改单历史 —— 那同时就是这张单一直缺的草稿编辑器。shipped 只开一条缝:加行,并由 sales_order_fulfilment_status 把状态翻回 partially_shipped。';

COMMIT;

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
    v_past     integer;
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
    -- 【为什么不能靠外键】四张表指着这一行(sales_records / invoice_lines /
    -- sales_order_reservations / shipment_lines),外键当然会拒 —— 但它吐出来的
    -- 是一句约束名,既没说是哪一行,也没说下一步该做什么。
    -- 【四个名字,前三个可操作、第四个不可操作】—— 见本迁移抬头。
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
        -- ════════════════════════════════════════════════════════════════════
        -- 【SO-1b fu1:已经过去的那一半】走到这里,说明这一行今天没有发货、
        -- 没有在册发票、没有活预留 —— 但它仍然可能【有过去】:一条释放过的
        -- 预留、一行作废了的发票。两者都是只增不改的档案,而外键盯的是行的
        -- 存在,不是它活不活。
        -- 【四张表逐一点出来,不靠一句 EXISTS】—— 数出来的这个数就是消息里
        -- 那个数,而它回答的是"这一行背后还有多少条记录"。
        -- ════════════════════════════════════════════════════════════════════
        SELECT (SELECT count(*) FROM sales_order_reservations r WHERE r.sales_order_line_id = v_line.id)
             + (SELECT count(*) FROM invoice_lines il          WHERE il.sales_order_line_id = v_line.id)
             + (SELECT count(*) FROM shipment_lines sl         WHERE sl.sales_order_line_id = v_line.id)
             + (SELECT count(*) FROM sales_records sr          WHERE sr.sales_order_line_id = v_line.id)
          INTO v_past;
        IF v_past > 0 THEN
            RAISE EXCEPTION 'SO_LINE_HAS_RECORD|%|%', OLD.line_no, v_past;
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
    -- 见 SO-1b 迁移抬头那条 shipped 的缝)。
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
$function$

;

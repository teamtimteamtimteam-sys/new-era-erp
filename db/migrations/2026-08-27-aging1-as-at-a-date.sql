-- db/migrations/2026-08-27-aging1-as-at-a-date.sql
-- AGING-1:AP/AR 账龄的【截至某一天】,以及两侧的 CSV 导出。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么这是函数而不是视图】视图不接参数。今天 ap_open_items / ar_open_items
-- 把 CURRENT_DATE 焊死在视图体里(`CURRENT_DATE - doc_date`,四条档位边界各一次),
-- 所以"截至 6 月 30 日"在那张视图上【没有地方可放】。这是勘察点出的第一条。
--
-- 【第二条:结清额是【现在】的样子】settled_base 由 payment_allocations 现算,
-- 不问那笔钱是哪天付的。于是"截至 6 月 30 日的账龄"会把 7 月付的钱算进去 ——
-- 那不是换一个参数,那是另一个计算。这是勘察说的"更难的那一半"。
--
-- ★【第三条与第四条 —— 勘察没有点出来,而线上数据当场证明它们咬人】★
--   ③ **单据在那一天【存在不存在】** 也是"截至"的一部分:7 月冲销的一笔付款,
--      在 6 月 30 日那天是【好好站着的】;而今天的视图按 `status='posted'` 过滤,
--      于是一份 6 月的账龄会随着 8 月的冲销而改变 —— 它不可复现。
--   ④ **金额本身在那一天是多少。** `ap_open_items` 的应付额 =
--      `quantity × unit_price`,而 unit_price 是【今天的】。实测:
--      IN-2026-0001 与 IN-2026-0003 在 2026-07-06 改过价(53.00→1.48、88.00→600.00),
--      两张今天都还开着;更要命的是 **2026-07-05 之前这九张全部【没有价】**
--      (`price_history` 里那一批 old_unit_price 为空的行就是首次计价),
--      而 `ap_open_items` 明写 `unit_price IS NOT NULL` —— 也就是说
--      **一份"截至 6 月 30 日"的应付账龄,若用今天的价,会印出五张在 6 月 30 日
--      那天【根本还不是一笔可计量应付】的单据,金额还是 7 月才定下来的价。**
--      所以价格必须按 `price_history` 回推。Tim 2026-08-27 裁定:回推。
--
-- 【回推不到的那一半,照直说出来,不假装】`inbound_batches.quantity` 没有历史表,
-- 所以"截至 D 的金额" = 【今天的数量】×【D 那天的价】。函数因此返回
-- `amount_basis`,页面与导出都把这句话带着走。**不因此拒绝** —— 今天没有任何
-- 一张在开的批次有数量变更的痕迹,为一件从未发生过的事拒发整份报表,
-- 是把一个已知的不精确换成一个确定的无用。
--
-- 【`price_history.created_at` 是【录入时刻】,不是业务日期】改价这件事没有业务日,
-- 所以回推的粒度是"按录入顺序",不是"按发生日"。这与 FIN-32 分开 business_date
-- 与录入时刻是同一条区别的另一面,记在这里而不是留给下一个读的人。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【档位边界:本刀把它收成一处】今天这四条边界在库里写了【三遍】——
-- ap_open_items 一遍、ar_open_items 的两支各一遍 —— 再加上本刀的两支就会是五遍。
-- 那正是本仓库反复付账的"同一条规矩两份实现"。所以先抽出 `aging_bucket(integer)`,
-- 再让【五处】全部引用它。两张老视图的列集一字未动,故走 CREATE OR REPLACE。
--
-- 【口径不变,只多一列】档位仍然按【单据日】分档,不按到期日。原因是测量出来的:
-- 供应商 0/8、客户 0/3 填了账期,AP 三支与 AR 的销售支【都没有到期日】。
-- 唯一有到期日的是 AR 的发票支(`invoices.due_date`,实测 6/6 已填,勘察那句
-- 「没有任何 AP 或 AR 单据带到期日」对这一支【已经过时】)。让一份报表里
-- 一支的"账龄"意思是"逾期"、另外四支是"开出至今",比整份都不精确更坏。
-- Tim 2026-08-27 裁定:**档位不动,把 due_date 作为一列露出来**,有就填、没有就空。
--
-- 【拒绝】未来日期按名拒(AGING_AS_OF_FUTURE)。一份"截至 2027 年"的账龄不是
-- 一份报表,是一次推测;而本仓库的规矩是"算得出来却不说话的值就是一个错答案"。
--
-- 【截止日早于 system_start_date 时不拒绝,而是【在报表脸上写清楚】】
-- 实测 system_start_date = 2026-08-01,而单据最早到 2026-06-09 —— 也就是说
-- 唯二两个月末(6/30、7/31)都在它之前。这是本仓库那条"派生的那一半完整、
-- 记录的那一半缺席"的账龄版本,而它的方向是明确的:**若切换前的【结清】没有
-- 全部补录,这份账龄会把欠款报【多】。** 直接拒绝会让这个功能在今天的数据上
-- 完全不可用;静默计算正是本刀要消灭的那种谎。所以返回 `before_system_start`,
-- 由页面与 CSV 抬头各说一句。
--
-- 【为什么是 SECURITY DEFINER】两张老视图在 OPS-14 已经改成属主权限,理由是
-- "行在不在取决于一个财务计算"。函数继承同一条,并且比视图【更进一步】:
-- 没有 module.finance.view 时按名拒绝,而不是返回 0 行 —— 0 行读起来是
-- 「没有未结单据」,那是一句假话(本仓库 mustRows / restRows 同一条)。
-- 数据类边界一字未动:`data.view_prices` 仍然按【调用者】解析。
--
-- 【价格历史读【基表】,不读 price_history_masked —— 这一句是刻意的】
-- `price_history_masked` 的门是 `module.inbound.view`,而这两张报表的读者是财务。
-- 让本函数去读那张遮蔽视图,财务读者会拿到【零行历史】,于是价格静默回退成
-- 今天的价 —— 那正是 AGENTS.md 里 `xmodule` 那一节记的病:跨模块借行,
-- 行悄悄消失,每个读者拿到不同的数字而没有任何东西说一声。
-- 所以按那一节的解法 (a):**属主权限读基表,把【读者自己的】谓词写回函数体** ——
-- 价格本身仍然按 `data.view_prices` 遮成 NULL,与 inbound_batches_masked.unit_price
-- 的遮法逐字同源,于是没有 view_prices 的读者看到的与今天【一模一样】。

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1 · 档位边界:全库唯一一处
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.aging_bucket(p_days integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 账龄档位的【唯一】定义。改这里,ap_open_items / ar_open_items 两支 /
    -- ap_aging_asof / ar_aging_asof 五处一起改 —— 这正是抽出它的全部理由。
    -- 天数为 NULL 时返回 NULL:一个算不出来的档位不是 'b90_plus'。
    SELECT CASE
        WHEN p_days IS NULL THEN NULL
        WHEN p_days <= 30 THEN 'b0_30'
        WHEN p_days <= 60 THEN 'b31_60'
        WHEN p_days <= 90 THEN 'b61_90'
        ELSE 'b90_plus'
    END::text;
$function$;

COMMENT ON FUNCTION public.aging_bucket(integer) IS
    'AGING-1:AP/AR 账龄档位边界的【唯一一处】定义(b0_30 / b31_60 / b61_90 / b90_plus)。五个消费方:ap_open_items、ar_open_items 的两支、ap_aging_asof、ar_aging_asof。抽出来之前这四条边界在库里写了三遍,本刀会写成五遍 —— 那正是本仓库反复付账的「同一条规矩两份实现」。天数为 NULL 返回 NULL:算不出来的档位不是 90 天以上。';

-- ───────────────────────────────────────────────────────────────────────────
-- 2 · 某一天那张批次的单价:从 price_history 回推
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.inbound_unit_price_asof(p_batch_id uuid, p_as_of date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
    -- 【口径:从【今天的价】往回走,不是从历史里往前找】
    -- 两种写法都能给出答案,而它们在【同一笔事务里改了两次价】时分道扬镳:
    -- `price_history.created_at` 默认 `now()`,而 `now()` 是**事务开始时刻** ——
    -- 同一笔事务里的两行【时刻完全相同】,谁先谁后这张表根本表达不出来。
    -- 第一版写的是"取 D 之前最后一次的新价",于是它必须在两个同刻行里挑一个,
    -- 而它挑的依据是 `id DESC` —— 一个随机 uuid。**同一份数据,两次运行两个答案。**
    -- (这是写 fixture 时被抓到的:两次 reprice 落在同一笔事务里,A 臂时红时绿。
    --  线上不显形,因为界面上每次改价各自是一笔事务。)
    --
    -- 现在的写法不需要在同刻行之间排序:
    --   ① D 之后【有】改价 → 取最早那一次的【旧价】,那就是 D 当天的价;
    --      首次计价那一行的 old_unit_price 【就是空的】,于是"那天还没有价"
    --      诚实地表达成 NULL,而不是被今天的价顶上去。
    --   ② D 之后【没有】改价 → 那自 D 以来就没变过,今天的价就是 D 的价。
    --      (含"一行历史都没有"的批次:实测线上这样的在册已计价批次是 0 张。)
    --
    -- 【残余的一处含糊,说出来而不是假装没有】D 严格早于某一天,而那一天里
    -- 【同一笔事务】改了两次以上价 —— 这时"最早那一次"仍然要在同刻行里挑。
    -- 它需要一笔多次改价的事务才制造得出来,而界面走不出这种事务;真要消除它,
    -- 得给 price_history 加一列序号,那是另一刀。
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM price_history ph
                      WHERE ph.inbound_batch_id = p_batch_id
                        AND ph.created_at::date > p_as_of)
            THEN (SELECT ph.old_unit_price FROM price_history ph
                   WHERE ph.inbound_batch_id = p_batch_id
                     AND ph.created_at::date > p_as_of
                   ORDER BY ph.created_at ASC, ph.id ASC LIMIT 1)
        ELSE (SELECT ib.unit_price FROM inbound_batches ib WHERE ib.id = p_batch_id)
    END;
$function$;

COMMENT ON FUNCTION public.inbound_unit_price_asof(uuid, date) IS
    'AGING-1:一张进料批次在【某一天】的单价 —— 从【今天的价】往回走,不是从历史里往前找。D 之后有改价就取最早那一次的 old_unit_price(首次计价那一行它就是空的,于是「那天还没有价」诚实地是 NULL,而 ap_open_items 明写 unit_price IS NOT NULL,那张批次会从当天的账龄里缺席);D 之后没有改价,今天的价就是 D 的价。【为什么不写成「取 D 之前最后一次的新价」】created_at 默认 now() 而 now() 是【事务开始时刻】,同一笔事务里的两行时刻完全相同 —— 那个写法必须在同刻行之间挑一个,而它挑的依据是随机 uuid:同一份数据两次运行两个答案(写 fixture 135 时抓到的)。【残余含糊】D 早于某一天而那天有一笔事务改了两次以上价;界面走不出这种事务,真要消除得给 price_history 加序号列,那是另一刀。【注意】created_at 是录入时刻不是业务日期,改价这件事今天没有业务日。';

-- ───────────────────────────────────────────────────────────────────────────
-- 3 · AP 账龄,截至某一天
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ap_aging_asof(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_as_of    date;
    v_today    date := CURRENT_DATE;
    v_start    date;
    v_base     text;
    v_rows     jsonb;
    v_buckets  jsonb;
    v_total    numeric;
    v_unpriced integer;
BEGIN
    -- 没有财务模块 → 【按名拒绝】,不是 0 行。两张老视图给的是 0 行
    -- (视图没有别的表达方式),而 0 行在页面上读作「没有未结单据」——
    -- 一句假话。函数有更好的表达方式,就该用。
    PERFORM require_permission('module.finance.view');

    -- 只读查询的"截至哪天",默认今天 —— 与 leave_balance / accrued_annual_leave
    -- 一族同一个惯用法,并已记在 docs/empty-string-to-rpc-audit.md 的白名单里。
    -- 【它不是那条"不许给日期默认值"的规矩的例外,是那条规矩的射程之外】:
    -- 那条管的是决定汇率、期间、金额的【写入】日期,而这里什么都不写。
    v_as_of := COALESCE(p_as_of, v_today);

    IF v_as_of > v_today THEN
        RAISE EXCEPTION 'AGING_AS_OF_FUTURE|%|%', v_as_of, v_today;
    END IF;

    SELECT fs.system_start_date INTO v_start FROM finance_settings fs LIMIT 1;
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.doc_date, x.doc_code), '[]'::jsonb)
      INTO v_rows
      FROM (
        -- ── 支一:已计价、在册的进料批次 ────────────────────────────────
        SELECT 'inbound'::text                                   AS doc_kind,
               ib.id                                             AS doc_id,
               ib.code                                           AS doc_code,
               ib.id                                             AS inbound_batch_id,
               ib.supplier_id                                    AS supplier_id,
               sup.legal_name                                    AS supplier_name,
               COALESCE(ib.arrival_date, ib.created_at::date)    AS doc_date,
               NULL::date                                        AS due_date,
               round(ib.quantity * pr.price, 2)                  AS doc_value_base,
               round(COALESCE(s.settled, 0) + COALESCE(pp.applied, 0), 2) AS settled_base,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_base,
               v_base                                            AS currency,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_ccy,
               (v_as_of - COALESCE(ib.arrival_date, ib.created_at::date))   AS days_outstanding,
               aging_bucket(v_as_of - COALESCE(ib.arrival_date, ib.created_at::date)) AS bucket,
               'supplier'::text                                  AS counterparty_kind,
               ib.supplier_id                                    AS counterparty_id,
               sup.legal_name                                    AS counterparty_name
          FROM inbound_batches_masked ib
          JOIN suppliers sup ON sup.id = ib.supplier_id
          -- 价格:D 那天的价,再套上与 inbound_batches_masked.unit_price
          -- 【逐字同源】的那道 data.view_prices 遮罩(见抬头)。
          CROSS JOIN LATERAL (
                SELECT CASE WHEN has_permission('data.view_prices')
                            THEN inbound_unit_price_asof(ib.id, v_as_of)
                       END AS price
          ) pr
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.inbound_batch_id = ib.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_base) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.inbound_batch_id = ib.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND pr.price IS NOT NULL

        UNION ALL

        -- ── 支二:挂账开支 ─────────────────────────────────────────────
        SELECT 'expense'::text, e.id, e.code, NULL::uuid,
               e.supplier_id, sup.legal_name,
               e.expense_date, NULL::date,
               e.amount_base,
               round((COALESCE(s.settled, 0) + COALESCE(pp.applied, 0)) * e.fx_rate, 2),
               round((e.amount_ccy - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0)) * e.fx_rate, 2),
               e.currency,
               round(e.amount_ccy - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2),
               (v_as_of - e.expense_date),
               aging_bucket(v_as_of - e.expense_date),
               CASE WHEN e.employee_id IS NOT NULL THEN 'employee' ELSE 'supplier' END::text,
               COALESCE(e.supplier_id, e.employee_id),
               COALESCE(sup.legal_name, emp.legal_name)
          FROM expenses e
          LEFT JOIN suppliers sup ON sup.id = e.supplier_id
          LEFT JOIN employees emp ON emp.id = e.employee_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.expense_id = e.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_ccy) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.expense_id = e.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE e.expense_date <= v_as_of
           -- 【为什么 payment_status 这个"现在"的标志还留着,而且必须留着】
           -- 实测:EXP-2026-0002 与 EXP-2026-0005 是 payment_status='paid' 却
           -- 【一条核销行都没有】—— 它们是当场付掉的,那笔钱根本不走 allocation。
           -- 所以"已付"在这套系统里【推导不出来】,只有那个标志说得出来。
           -- 于是判据写成:今天还挂着账 【或者】 它的结清发生在 D 【之后】。
           -- D = 今天时,后半永远为假(没有晚于今天的收付款 —— 实测 0 笔),
           -- 于是它逐字退化成今天那张视图的 `payment_status='unpaid'`。
           -- 这就是"默认今天等于今天的行为"在这一支上的落点。
           AND (e.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.expense_id = e.id AND p2.payment_date > v_as_of)
                OR EXISTS (SELECT 1 FROM prepayment_applications ppa2
                             LEFT JOIN journal_entries je2 ON je2.id = ppa2.journal_entry_id
                            WHERE ppa2.expense_id = e.id
                              AND COALESCE(je2.entry_date, ppa2.created_at::date) > v_as_of))
           -- 单据在 D 那天【站着没有】:今天 posted 的站着;今天是 reversed 的,
           -- 若那次冲销发生在 D 之后,它在 D 那天也是站着的。
           AND (e.status = 'posted'
                OR (e.status = 'reversed'
                    AND (SELECT m.expense_date FROM expenses m
                          WHERE m.id = e.reversed_by_expense) > v_as_of))
           -- 镜像行照旧排除(它是冲销的记账凭证,不是一张新的应付单)
           AND NOT EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id)

        UNION ALL

        -- ── 支三:未付运费单 ───────────────────────────────────────────
        SELECT 'freight'::text, fd.id, fd.code, NULL::uuid,
               fd.supplier_id, sup.legal_name,
               fd.doc_date, NULL::date,
               fd.amount_base,
               round(COALESCE(s.settled, 0) * fd.fx_rate, 2),
               round((fd.amount_ccy - COALESCE(s.settled, 0)) * fd.fx_rate, 2),
               fd.currency,
               round(fd.amount_ccy - COALESCE(s.settled, 0), 2),
               (v_as_of - fd.doc_date),
               aging_bucket(v_as_of - fd.doc_date),
               'supplier'::text, fd.supplier_id, sup.legal_name
          FROM freight_documents fd
          JOIN suppliers sup ON sup.id = fd.supplier_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.freight_document_id = fd.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
         WHERE fd.doc_date <= v_as_of
           AND (fd.deleted_at IS NULL OR fd.deleted_at::date > v_as_of)
           AND (fd.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.freight_document_id = fd.id AND p2.payment_date > v_as_of))
           -- 运费单的冲销日:优先取【冲销分录的分录日】(那是业务日),
           -- 取不到才退回 reversed_at 的录入时刻。与 reverse_freight_document
           -- 用 CURRENT_DATE 立那张冲销分录逐字对应。
           AND (fd.status = 'posted'
                OR (fd.status = 'reversed'
                    AND COALESCE((SELECT je.entry_date FROM journal_entries je
                                   WHERE je.id = fd.reversal_entry_id),
                                 fd.reversed_at::date) > v_as_of))
      ) x
     WHERE x.open_ccy > 0;

    -- 档位合计:四档【一档不落】,没有的那一档是 0 而不是缺席 ——
    -- 一个缺席的键在页面上会渲染成空白,读起来像"没算出来"。
    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0))
      INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_rows) e
             WHERE e->>'bucket' = b.bucket
      ) agg ON true;

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0)
      INTO v_total FROM jsonb_array_elements(v_rows) e;

    -- 【被"那天还没有价"挡掉的批次有几张】—— 一个缺席要说得出数目,
    -- 否则它与"本来就没有这笔应付"在屏幕上长得一模一样。
    -- 没有 data.view_prices 时这个数是 NULL 而不是 0:那不是"零张",
    -- 是"你看不到这一栏",与价格本身遮成 NULL 同一个道理。
    IF has_permission('data.view_prices') THEN
        SELECT count(*) INTO v_unpriced
          FROM inbound_batches ib
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND inbound_unit_price_asof(ib.id, v_as_of) IS NULL;
    ELSE
        v_unpriced := NULL;
    END IF;

    RETURN jsonb_build_object(
        'side',                'ap',
        'as_of',               v_as_of,
        'today',               v_today,
        'is_past',             (v_as_of < v_today),
        'system_start_date',   v_start,
        'before_system_start', (v_start IS NOT NULL AND v_as_of < v_start),
        'base_currency',       v_base,
        -- 机器令牌,不是给人读的句子 —— 双语措辞留在 messages/,按语言选一条。
        'amount_basis',        'quantity_now_price_asof',
        'unpriced_excluded',   v_unpriced,
        'total_open_base',     v_total,
        'buckets',             v_buckets,
        'rows',                v_rows
    );
END;
$function$;

COMMENT ON FUNCTION public.ap_aging_asof(date) IS
    'AGING-1:AP 账龄【截至某一天】。视图接不了参数,而"截至"有四层而不是一层:① CURRENT_DATE 焊在视图体里;② 结清额要按付款日回推(晚于 D 的付款不算);③ 单据在 D 那天站着没有(D 之后的冲销/删除不回溯);④ 金额在 D 那天是多少(单价按 price_history 回推 —— 实测 2026-07-05 之前九张在开批次全部无价)。数量没有历史表,所以金额 = 今天的数量 × D 那天的价,由 amount_basis 明说。未来日期按名拒 AGING_AS_OF_FUTURE。截止日早于 system_start_date 不拒绝,返回 before_system_start 由页面与 CSV 各说一句(方向是把欠款报多)。p_as_of 默认今天,且【等于今天时逐行复现今天那张视图】—— db/fixtures/135 的 A 臂钉住。';

-- ───────────────────────────────────────────────────────────────────────────
-- 4 · AR 账龄,截至某一天
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.ar_aging_asof(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_as_of   date;
    v_today   date := CURRENT_DATE;
    v_start   date;
    v_base    text;
    v_rows    jsonb;
    v_buckets jsonb;
    v_total   numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    v_as_of := COALESCE(p_as_of, v_today);

    IF v_as_of > v_today THEN
        RAISE EXCEPTION 'AGING_AS_OF_FUTURE|%|%', v_as_of, v_today;
    END IF;

    SELECT fs.system_start_date INTO v_start FROM finance_settings fs LIMIT 1;
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.sale_date, x.doc_code), '[]'::jsonb)
      INTO v_rows
      FROM (
        -- ── 支一:直接销售记录 ─────────────────────────────────────────
        SELECT sr.id                                     AS sales_record_id,
               ob.code                                   AS doc_code,
               sr.customer_id                            AS customer_id,
               c.legal_name                              AS customer_name,
               sr.sale_date                              AS sale_date,
               -- 销售支的到期日:它自己没有,但它挂着的那张【在册】发票有。
               -- 实测 invoices.due_date 6/6 已填,所以这一列在 AR 上是有内容的。
               inv.due_date                              AS due_date,
               sr.amount_base                            AS amount_base,
               sr.currency                               AS currency,
               round(sr.quantity * sr.unit_price, 2)     AS amount_ccy,
               round(COALESCE(s.settled, 0), 2)          AS settled_ccy,
               round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0), 2) AS open_ccy,
               round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0)) * sr.fx_rate, 2) AS open_base,
               (v_as_of - sr.sale_date)                  AS days_outstanding,
               aging_bucket(v_as_of - sr.sale_date)      AS bucket,
               inv.invoice_id                            AS invoice_id,
               inv.invoice_code                          AS invoice_code,
               'sale'::text                              AS doc_kind,
               round(COALESCE(s.settled, 0) * sr.fx_rate, 2) AS settled_base,
               0::numeric                                AS credited_ccy,
               0::numeric                                AS credited_base
          FROM sales_records_masked sr
          JOIN output_batches ob ON ob.id = sr.output_batch_id
          LEFT JOIN customers c ON c.id = sr.customer_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.sales_record_id = sr.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT i.id AS invoice_id, i.code AS invoice_code, i.due_date
                  FROM invoice_lines_masked il
                  JOIN invoices_masked i ON i.id = il.invoice_id
                 WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
                 LIMIT 1
          ) inv ON true
         WHERE sr.sale_date <= v_as_of
           AND sr.sales_order_line_id IS NULL

        UNION ALL

        -- ── 支二:订单流发票 ───────────────────────────────────────────
        -- 【为什么这里把 order_invoice_balance_all 的算术抄了下来,而不是引用它】
        -- 那张视图是"现在"的算术:已结只认 posted 收款、已贷记不问贷项日、
        -- 发票在不在只看 status。三处都要按 D 回推,而【视图接不了参数】——
        -- 这正是本刀存在的理由本身,在第二支上再出现一次。
        -- 算术本身逐列同源,任何一边改了另一边必须跟着改,两处注释互指。
        SELECT NULL::uuid, i.code, i.customer_id, c.legal_name,
               i.issue_date, i.due_date,
               round(l.amount_ccy * i.fx_rate, 2),
               i.currency, l.amount_ccy,
               round(COALESCE(s.settled, 0), 2),
               round(l.amount_ccy - COALESCE(s.settled, 0) - COALESCE(cn.credited, 0), 2),
               round((l.amount_ccy - COALESCE(s.settled, 0) - COALESCE(cn.credited, 0)) * i.fx_rate, 2),
               (v_as_of - i.issue_date),
               aging_bucket(v_as_of - i.issue_date),
               i.id, i.code, 'invoice'::text,
               round(COALESCE(s.settled, 0) * i.fx_rate, 2),
               round(COALESCE(cn.credited, 0), 2),
               round(COALESCE(cn.credited, 0) * i.fx_rate, 2)
          FROM invoices i
          LEFT JOIN customers c ON c.id = i.customer_id
          JOIN LATERAL (
                SELECT COALESCE(sum(il.amount_ccy), 0) AS amount_ccy
                  FROM invoice_lines il WHERE il.invoice_id = i.id
          ) l ON true
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.invoice_id = i.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                -- 贷项凭证有自己的业务日(note_date),所以它照 D 截断,
                -- 与收款同一条:D 之后开的贷项凭证不往回渗。
                SELECT sum(cl.amount) AS credited
                  FROM credit_note_lines cl
                  JOIN credit_notes cc ON cc.id = cl.credit_note_id
                 WHERE cc.invoice_id = i.id AND cc.note_date <= v_as_of
          ) cn ON true
         WHERE i.kind = 'order'
           AND i.issue_date <= v_as_of
           -- 作废日优先取【那张冲销分录的分录日】(void_invoice 的 p_reversal_date
           -- 就是它),取不到才退回 voided_at 的录入时刻。
           AND (i.status = 'issued'
                OR (i.status = 'void'
                    AND COALESCE((SELECT r.entry_date
                                    FROM journal_entries o
                                    JOIN journal_entries r ON r.id = o.reversed_by
                                   WHERE o.id = i.entry_id),
                                 i.voided_at::date) > v_as_of))
           -- 第二支与今天那张视图同效:显式要 data.view_prices。
           -- 第一支靠 sales_records_masked 把 unit_price 遮成 NULL 自然消失,
           -- 两支对同一读者同进同退。
           AND has_permission('data.view_prices')
      ) x
     WHERE x.open_ccy > 0;

    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0))
      INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_rows) e
             WHERE e->>'bucket' = b.bucket
      ) agg ON true;

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0)
      INTO v_total FROM jsonb_array_elements(v_rows) e;

    RETURN jsonb_build_object(
        'side',                'ar',
        'as_of',               v_as_of,
        'today',               v_today,
        'is_past',             (v_as_of < v_today),
        'system_start_date',   v_start,
        'before_system_start', (v_start IS NOT NULL AND v_as_of < v_start),
        'base_currency',       v_base,
        -- AR 两支的金额都是【冻住的】(销售记录的量价、发票行的生成列),
        -- 没有 AP 那个"数量按今天"的近似,所以基准令牌不同。
        'amount_basis',        'amounts_as_recorded',
        'unpriced_excluded',   NULL,
        'total_open_base',     v_total,
        'buckets',             v_buckets,
        'rows',                v_rows
    );
END;
$function$;

COMMENT ON FUNCTION public.ar_aging_asof(date) IS
    'AGING-1:AR 账龄【截至某一天】。两支:直接销售记录 + 订单流发票。结清按收款日回推、贷记按 note_date 回推、发票在不在按【作废分录的分录日】回推(晚于 D 的作废不回溯)。第二支把 order_invoice_balance_all 的算术抄了下来而不是引用它 —— 那张视图是「现在」的算术且接不了参数,正是本刀存在的理由再出现一次;两处注释互指,一边改另一边必须跟着改。到期日:发票支取 invoices.due_date,销售支取它挂着的在册发票的 due_date(实测 6/6 已填);【档位仍按单据日,不按到期日】。p_as_of 默认今天,等于今天时逐行复现今天那张视图 —— db/fixtures/135 的 A 臂钉住。';

-- ───────────────────────────────────────────────────────────────────────────
-- 5 · 两张老视图改用同一个档位函数(列集一字未动 → CREATE OR REPLACE)
-- ───────────────────────────────────────────────────────────────────────────
-- 【WITH (...) 显式写出来,不靠"CREATE OR REPLACE 会留着它"】AGENTS.md 已经为
-- 「pg_get_viewdef 不吐 reloptions」记过一次账(PAYEE-1a)。这里把它写死,
-- 于是这份迁移读起来就知道这两张视图是【刻意】声明过属主权限的,
-- 而不需要下一个人去 pg_class 里查一遍。
CREATE OR REPLACE VIEW public.ap_open_items WITH (security_invoker = off) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_base,
    settled_base,
    open_base,
    currency,
    open_ccy,
    CURRENT_DATE - doc_date AS days_outstanding,
    aging_bucket(CURRENT_DATE - doc_date) AS bucket,
    counterparty_kind,
    counterparty_id,
    counterparty_name
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_base,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_base,
            ( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base) AS currency,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy,
            'supplier'::text AS counterparty_kind,
            ib.supplier_id AS counterparty_id,
            sup.legal_name AS counterparty_name
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_base) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
         SELECT 'expense'::text AS doc_kind,
            e.id AS doc_id,
            e.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            e.supplier_id,
            sup.legal_name AS supplier_name,
            e.expense_date AS doc_date,
            e.amount_base AS doc_value_base,
            round((COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2) AS settled_base,
            round((e.amount_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric)) * e.fx_rate, 2) AS open_base,
            e.currency,
            round(e.amount_ccy - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_ccy,
                CASE
                    WHEN e.employee_id IS NOT NULL THEN 'employee'::text
                    ELSE 'supplier'::text
                END AS counterparty_kind,
            COALESCE(e.supplier_id, e.employee_id) AS counterparty_id,
            COALESCE(sup.legal_name, emp.legal_name) AS counterparty_name
           FROM expenses e
             LEFT JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN employees emp ON emp.id = e.employee_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_ccy) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.expense_id = e.id) pp ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))
        UNION ALL
         SELECT 'freight'::text AS doc_kind,
            fd.id AS doc_id,
            fd.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            fd.supplier_id,
            sup.legal_name AS supplier_name,
            fd.doc_date,
            fd.amount_base AS doc_value_base,
            round(COALESCE(s.settled, 0::numeric) * fd.fx_rate, 2) AS settled_base,
            round((fd.amount_ccy - COALESCE(s.settled, 0::numeric)) * fd.fx_rate, 2) AS open_base,
            fd.currency,
            round(fd.amount_ccy - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
            'supplier'::text AS counterparty_kind,
            fd.supplier_id AS counterparty_id,
            sup.legal_name AS counterparty_name
           FROM freight_documents fd
             JOIN suppliers sup ON sup.id = fd.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.freight_document_id = fd.id) s ON true
          WHERE fd.payment_status = 'unpaid'::text AND fd.status = 'posted'::text AND fd.deleted_at IS NULL) d
  WHERE open_ccy > 0::numeric AND has_permission('module.finance.view'::text);

CREATE OR REPLACE VIEW public.ar_open_items WITH (security_invoker = off) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_base,
    sr.currency,
    round(sr.quantity * sr.unit_price, 2) AS amount_ccy,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_ccy,
    round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) AS open_ccy,
    round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric)) * sr.fx_rate, 2) AS open_base,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
    aging_bucket(CURRENT_DATE - sr.sale_date) AS bucket,
    inv.invoice_id,
    inv.invoice_code,
    'sale'::text AS doc_kind,
    round(COALESCE(s.settled, 0::numeric) * sr.fx_rate, 2) AS settled_base,
    0::numeric AS credited_ccy,
    0::numeric AS credited_base
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_ccy) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0::numeric), 2) > 0::numeric AND sr.sales_order_line_id IS NULL AND has_permission('module.finance.view'::text)
UNION ALL
 SELECT NULL::uuid AS sales_record_id,
    o.code AS doc_code,
    o.customer_id,
    c.legal_name AS customer_name,
    o.issue_date AS sale_date,
    round(o.amount_ccy * o.fx_rate, 2) AS amount_base,
    o.currency,
    o.amount_ccy,
    o.settled_ccy,
    o.open_ccy,
    o.open_base,
    CURRENT_DATE - o.issue_date AS days_outstanding,
    aging_bucket(CURRENT_DATE - o.issue_date) AS bucket,
    o.invoice_id,
    o.code AS invoice_code,
    'invoice'::text AS doc_kind,
    round(o.settled_ccy * o.fx_rate, 2) AS settled_base,
    o.credited_ccy,
    o.credited_base
   FROM order_invoice_open_all o
     LEFT JOIN customers c ON c.id = o.customer_id
  WHERE has_permission('module.finance.view'::text) AND has_permission('data.view_prices'::text);

COMMIT;

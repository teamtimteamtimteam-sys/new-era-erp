CREATE OR REPLACE FUNCTION public.journal_activity_lines(p_from date, p_to date, p_include_year_close boolean)
 RETURNS TABLE(entry_id uuid, entry_code text, entry_date date, entry_memo text, source_type text, source_id uuid, entry_status text, line_id uuid, line_memo text, account_id uuid, account_code text, account_name_en text, account_name_zh text, account_type text, debit numeric, credit numeric, signed_base numeric)
 LANGUAGE sql
 STABLE
AS $function$
    -- ════════════════════════════════════════════════════════════════════════
    -- 【没有 status 过滤 —— 这是本文件存在的头号理由,不是疏漏】
    --
    -- 被冲销的原分录 status='reversed',冲销分录 status='posted' 且金额等额反向。
    -- 只留 posted 会【丢掉原分录、留下冲销分录】,净额刚好错成 −原分录 ——
    -- 一张不报错、只是符号反了的报表。两个都要数,才净成零。
    --
    -- 这段警告此前是【两份】,分别抄在 pnl_statement 与 balance_sheet 的函数体里,
    -- 靠「改任何一边前先读两边」维持。它现在住在这里,而那两个函数(以及
    -- account_ledger)读的就是这一段代码本身 —— 于是"两边"不再需要被读,
    -- 因为已经没有两边了。
    --
    -- (cash_flow_statement 里那句 e.status='posted' 与此不一致 —— 见 OPS-16
    --  提交信息里的报告。它不读这个函数,那是另一件事,本次不动。)
    -- ════════════════════════════════════════════════════════════════════════
    --
    -- 【符号规则,一条】资产/成本/费用 借正;收入/负债/权益 贷正。
    -- 三个读者共用它:损益表的 amount、资产负债表的 net、科目明细的 amount
    -- 与合计,都是这一列聚合出来的。分开写三遍就是三次漂移机会。
    --
    -- 【LANGUAGE sql + STABLE + 不带 SET search_path,是为了可内联】
    -- 带 SET 子句或 SECURITY DEFINER 的函数,规划器不会内联;不内联,
    -- account_ledger 查一个科目也要先物化全库分录行再过滤。它是 invoker,
    -- 调用它的三个函数都是 SECURITY DEFINER + SET search_path,函数体解析时
    -- 用的是【调用者的】search_path,而那三个都已经把它钉死成 public, pg_temp。
    -- 先例:reprice_split 同样不带 SET。
    --
    -- 【直接调用它是安全的,靠的是 RLS 而不是"调不到"】它没有调用者检查,
    -- 也没有从 authenticated 收回 EXECUTE —— 因为它是 invoker:
    -- journal_lines / journal_entries 的 SELECT 策略就是
    -- has_permission('module.finance.view')(accounts 是 USING (true))。
    -- 直接调它的登录用户走的是自己那条策略,拿不到比 PostgREST 直查更多的东西。
    -- 三个 definer 调用方以属主身份执行、绕过 RLS —— 它们各自先 require_permission,
    -- 问的是同一条,只是问得更早。
    SELECT e.id, e.code, e.entry_date, e.memo,
           e.source_type, e.source_id, e.status,
           l.id, l.line_memo,
           a.id, a.code, a.name_en, a.name_zh, a.account_type,
           l.debit, l.credit,
           CASE WHEN a.account_type IN ('asset', 'cogs', 'expense')
                THEN l.debit - l.credit
                ELSE l.credit - l.debit END
    FROM journal_lines l
    JOIN journal_entries e ON e.id = l.entry_id
    JOIN accounts a ON a.id = l.account_id
    -- 【开关①:日期形状】NULL = 该侧不设界。期间表传 (from, to);
    -- 截至日表传 (NULL, as_of)。两者的差别只有这一处,别处不该再有。
    WHERE (p_from IS NULL OR e.entry_date >= p_from)
      AND (p_to IS NULL OR e.entry_date <= p_to)
    -- 【开关②:年结分录】FIN-23 的刻意不对称,理由写在两个调用点上。
    --
    -- 【IS DISTINCT FROM,不是 <>】source_type 可空。写成 <> 时,NULL 求值为
    -- NULL,于是【source_type 为 NULL 的分录会被整条丢掉】—— 一张少算了一笔
    -- 分录的报表不会报错,只会小一点。
      AND (p_include_year_close OR e.source_type IS DISTINCT FROM 'year_close');
$function$;

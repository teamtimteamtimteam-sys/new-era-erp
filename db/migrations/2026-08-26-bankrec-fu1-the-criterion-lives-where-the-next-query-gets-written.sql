-- BANK-REC 后续:把【求和 vs 判活】那条判据写在 journal_activity_lines 的函数体里。
-- NOTE: apply with ./db/apply_migration.sh
--
-- 【为什么这要一次迁移,而不是改一下仓库里的注释就完事】
-- db/functions/*.sql 是 pg_get_functiondef 的【逐字镜像】,而函数体里的注释
-- 就是函数体的一部分。只改仓库那一份,check_mirrors 当场报漂移 ——
-- 那正是它该报的。判据要住在【下一个写这句过滤的人打开的那个文件】里,
-- 所以它必须真的进到库里那份定义中去。
--
-- 【只动注释,一个字节的逻辑都没改】SQL 部分与 BANK-REC 之前逐字相同。

BEGIN;

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
    --
    -- ────────────────────────────────────────────────────────────────────
    -- 【判据,一句话(BANK-REC,2026-08-26 补)】把分录过滤成 status='posted',
    -- 在【求和】时几乎总是错的,在【判断单张分录还活着没有】时几乎总是对的。
    --
    -- 求和会错,是因为上面那段:丢原分录、留冲销分录,净额错成 −原分录。
    -- 判断单张分录活没活着是一个真问题,posted 就是它的正确判据 ——
    -- guard_gst_switch(那张带税分录还立着吗)、
    -- processing_run_allocation_status(资本化分录还作数吗)、
    -- bank_unmatched_journal_lines(这一行还配得上吗 —— match_bank_line 对
    --   reversed 分录的行直接抛 JL_ENTRY_REVERSED,视图问的是同一条,只是问得更早)
    -- 三处都是对的用法,不要"顺手修好"它们。
    --
    -- 【这个机制至今现身四次】① cash_flow_statement(OPS-17,已修)
    -- ② f5_return / f5_box_detail(GST-2,已修)
    -- ③ bank_reconciliation_status.ledger_balance(BANK-REC,已修 ——
    --    **它一直在线上错着**:1010 上有 2 条被冲销的分录行,银行首页显示
    --    −31,338.70,而总账其实是 −29,753.70,差 USD 1,585.00)
    -- ④ preview_revalue_foreign_balances(BANK-REC 顺带发现,**还没修**,
    --    已按名记在 known-issues —— 它还【会过账】,所以那一条排在前面)
    --
    -- 【读到这里的人,如果正要写一句新的 posted 过滤】先问:我在求和,
    -- 还是在问一张分录死没死?第一种就读这个函数,别自己写。
    -- ────────────────────────────────────────────────────────────────────
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


COMMIT;

-- db/functions/bank_match_lines.sql
-- SYSTEM-MAP-3(Tim 2026-10-27,grilling 第 7 条):单据链条上「银行对账」那一步链到【匹配上的那一行】——
--   对账单页上那一行带着 id="line-<对账单行 id>",<HashTarget> 把它滚进视野并标亮。
--   这一支答:这几笔付款,各自被哪一张对账单的哪一行匹配了。路与 document_relation_arm_ids 的
--   payment_to_bank_statement 那一支逐字同一条(付款 → 分录行 ← 匹配 → 对账单行)。INVOKER。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.bank_match_lines(p_payment_ids uuid[])
 RETURNS TABLE(payment_id uuid, statement_id uuid, line_id uuid)
 LANGUAGE sql
 STABLE
AS $function$
    SELECT DISTINCT p.id, bl.statement_id, bl.id
      FROM public.payments p
      JOIN public.journal_lines jl ON jl.entry_id = p.journal_entry_id
      JOIN public.bank_line_matches m ON m.journal_line_id = jl.id
      JOIN public.bank_statement_lines bl ON bl.id = m.statement_line_id
     WHERE p.id = ANY (p_payment_ids)
$function$;

COMMENT ON FUNCTION public.bank_match_lines(uuid[]) IS
    'SYSTEM-MAP-3:这几笔付款各自被哪一张对账单的哪一行匹配了(单据链条「银行对账」那一步的锚点)。INVOKER。';

-- db/functions/assert_entry_not_bank_matched.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q6):一张分录的银行行已经配上了对账单行,就不许冲它 —— 按名拒,说出怎么办。
--
--   REVERSAL_BANK_MATCHED|<分录编号>|<对账单编号>|<open|reconciled>
--     open       → 先在对账单上把那一行【取消配对】(unmatch_bank_line),再冲;
--     reconciled → 那张对账单已经对完账,先【撤销对账】(unreconcile_statement),再取消配对,再冲。
--   不替人自动取消配对:对完账的单子取消不了配对(STATEMENT_RECONCILED),而悄悄撤销一次对账比拒绝更坏。
--
-- 【为什么四条冲销路都要它】冲销把原分录翻成 reversed,而 bank_line_matches 里那一行仍指着它 ——
--   对账单上那一行从此"配着"一张已经不在账上的分录;match_bank_line 自己对 reversed 分录按名拒(JL_ENTRY_REVERSED),
--   于是这个状态只能从冲销那一侧产生。Step 0 量过:库里没有任何一条冲销路看 bank_line_matches(grep 只命中配对 / 取消配对 /
--   对账行 / 两支留痕函数)。工资付款、付款、行内转账、代扣税缴纳四条冲销引擎都在冲之前调它;
--   提交与批准各自的试跑走的是同一支引擎,所以提、批、执行三处都拒。
--
-- 【INVOKER,不问码】它只在四支 SECURITY DEFINER 引擎里被调(属主身份,bank_line_matches 的 RLS 不参与);
--   authenticated 收回了 EXECUTE(db/views/zzz_function_grants.sql)—— 够不着,而不是靠门。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.assert_entry_not_bank_matched(p_entry_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code   text;
    v_stmt   text;
    v_status text;
BEGIN
    SELECT je.code, s.code, s.status INTO v_code, v_stmt, v_status
      FROM journal_lines jl
      JOIN journal_entries je ON je.id = jl.entry_id
      JOIN bank_line_matches m ON m.journal_line_id = jl.id
      JOIN bank_statement_lines bl ON bl.id = m.statement_line_id
      JOIN bank_statements s ON s.id = bl.statement_id
     WHERE jl.entry_id = p_entry_id
     ORDER BY s.code
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'REVERSAL_BANK_MATCHED|%|%|%', v_code, v_stmt, v_status;
    END IF;
END;
$function$;

-- db/functions/journal_request_dry_run.sql
-- APR-6(2026-09-25):按【批准那一刻会用的同一支过账】把一张手工凭证 / 冲销申请试跑一遍,然后整个回滚 ——
-- 分录、编号、冲销标记一样都不留。提交时跑一次(提单人当场听见引擎的原话)。
--
-- 【为什么不写一份"校验函数"】与 invoice_request_dry_run、payment_request_dry_run、payroll_request_dry_run、
-- receipt_price_request_dry_run 逐字同一条:借贷不平、科目停用、币种、汇率、GST 税码、期间锁、年结、
-- 超出当月、冲销日早于原分录、控制科目 —— 抄一份出来,写下那天一致、之后悄悄分开。试跑【就是】那一份。
-- 返回 journal_request_post_internal 的返回值(变量的赋值不随子事务回滚),所以 amount_base 与
-- credits_bank 从这里来。
--
-- 【借贷平衡是【延迟】触发器】trg_journal_lines_balance 在提交时才判;子事务的回滚不会让它开火。所以试跑里
-- 先把【这一支】约束触发器改成 IMMEDIATE(排着的那几条当场跑掉),再改回 DEFERRED —— 否则一张借贷不平的
-- 申请会在试跑里"过得去",直到批准那一刻的提交才炸,而那时 CFO 已经按过了。只点名这一支,不用 ALL:
-- ALL 会把调用方这笔事务里别处排着的延迟检查(库存恒等式之类)一起提前,那不是试跑该管的事。
--
-- 【怎么做到"整个回滚"】带 EXCEPTION 子句的块就是一个子事务。过账跑完抛专用 SQLSTATE PQ005,
-- 只接这一个 —— 引擎自己的任何拒绝照常往外抛。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := journal_request_post_internal(p_request_id);
        SET CONSTRAINTS trg_journal_lines_balance IMMEDIATE;
        SET CONSTRAINTS trg_journal_lines_balance DEFERRED;
        RAISE EXCEPTION USING ERRCODE = 'PQ005', MESSAGE = 'JOURNAL_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ005' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$;

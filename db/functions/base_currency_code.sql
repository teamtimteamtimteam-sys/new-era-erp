-- db/functions/base_currency_code.sql
-- 本位币的标量取数(OPS-11)。给【表达式位置】用 —— 分录负载里
-- jsonb_build_object('currency', base_currency_code(), …) 之类。
--
-- 已有的 `SELECT c.code INTO v_base FROM currencies c WHERE c.is_base` 保持原样:
-- 那是取进变量后在函数里多处复用,不是散在负载里的字面量,两者不冲突。
--
-- STABLE 而非 IMMUTABLE:它读表。因此【CHECK 约束里用不了它】——
-- fx_rates 那条 CHECK (currency <> 'SGD') 仍然只能手改,理由见
-- docs/currency-literals-audit.md 的"换本位币要手改的地方"。
-- 但 DEFAULT 表达式接受函数调用(参数默认与列默认都实测过),
-- 所以"表达不了"不是任何 DEFAULT 留着字面量的理由。
--
-- NOTE: introduced by db/migrations/2026-08-07-ops11-base-currency-in-journal-payloads.sql.

CREATE OR REPLACE FUNCTION public.base_currency_code()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT c.code FROM currencies c WHERE c.is_base;
$function$;
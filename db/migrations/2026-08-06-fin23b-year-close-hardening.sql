-- db/migrations/2026-08-06-fin23b-year-close-hardening.sql
--
-- FIN-23b:FIN-23 落地后门红两处,都是门该抓的(FIN-22b 的同两类,教训是
-- 【新函数与新写死科目,上迁移前先过一遍这两条】):
--
-- 1.【B1:守卫触发器函数 anon 可执行】reject_year_close_mutation 默认对 PUBLIC
--    授 EXECUTE。触发器以表事件触发,不需要任何人直接 EXECUTE —— 收回。
--    (period_closes 的守卫在它自己的迁移里收过;这次建新守卫时漏了同一步。)
--
-- 2.【3100 被函数写死引用但不是 is_system】close_financial_year 把净结果对
--    3100 过账 —— 操作员停用/改号 3100,年结当场断。升 is_system
--    (seed:accounts 29 → 30;镜像同步挪段)。

BEGIN;

REVOKE EXECUTE ON FUNCTION public.reject_year_close_mutation() FROM PUBLIC, anon;

UPDATE public.accounts SET is_system = true WHERE code = '3100';

DO $mig$
BEGIN
    IF has_function_privilege('anon', 'public.reject_year_close_mutation()', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIN23B_SELFCHECK_FAILED|守卫函数仍 anon 可执行';
    END IF;
    IF NOT (SELECT is_system FROM public.accounts WHERE code = '3100') THEN
        RAISE EXCEPTION 'FIN23B_SELFCHECK_FAILED|3100 未升 is_system';
    END IF;
END
$mig$;

COMMIT;

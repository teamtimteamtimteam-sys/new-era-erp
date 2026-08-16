-- FIN-DRILL fu1:撤掉两句 COMMENT ON FUNCTION —— 镜像里没有它们的位置
--
-- 主迁移给 journal_activity_lines 与 account_ledger 各加了一句
-- COMMENT ON FUNCTION。撤掉,理由是【镜像记不住它们】:
--
--   * 单函数镜像文件按约定就是 pg_get_functiondef 的原样字节,而
--     pg_get_functiondef **不吐 COMMENT**;
--   * check_mirrors 比对函数时比的也是 pg_get_functiondef —— 它比列注释
--     (col_description),但不比函数注释。
--
-- 两者合起来就是一类【没有任何东西看得见的漂移】:线上有注释、重建出来的库
-- 没有,而三条判词全绿。仓库里 ~100 个函数镜像**零处**使用 COMMENT ON FUNCTION,
-- 这不是巧合,是这条约定的结果;主迁移是第一处例外,所以在它长成惯例之前收掉。
--
-- 【那些话没有丢】它们本来就写在函数体里(pg_get_functiondef 吐 prosrc,
-- body 里的注释逐字包含在内),镜像因此记得住。COMMENT ON 是同一段话的
-- 第二份拷贝,而第二份拷贝正是这个仓库反复付学费的那个形状。
BEGIN;

COMMENT ON FUNCTION public.journal_activity_lines(date, date, boolean) IS NULL;
COMMENT ON FUNCTION public.account_ledger(text, date, date, boolean) IS NULL;

COMMIT;

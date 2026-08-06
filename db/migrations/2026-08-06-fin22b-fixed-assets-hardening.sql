-- db/migrations/2026-08-06-fin22b-fixed-assets-hardening.sql
--
-- FIN-22b:FIN-22 落地后门(gate)红了三处 —— 全是门该抓的,逐条修:
--
-- 1.【旧签名的 record_expense 还活着】CREATE OR REPLACE 遇到【新增参数】不是替换,
--    是新建同名重载 —— 10 参旧函数原样留在库里,镜像集合里没有它 → 镜像漂移。
--    DROP 掉;调用方(app action)全部走 11 参新签名。
--
-- 2.【B1:四个新函数 anon 可执行】函数默认对 PUBLIC 授 EXECUTE(platform-prelude
--    在重建侧改了默认权限,所以重建是 0、线上是 4 —— B1 双侧断言正是为抓这种
--    只在一侧存在的洞)。照既有模式收回 PUBLIC/anon;authenticated 保留
--    (应用以它调用,函数体内 require_permission 把关)。
--
-- 3.【1500/1510 被函数引用但不是 is_system】check_mirrors 的科目码扫描:函数写死
--    引用的科目必须 is_system —— 否则操作员能停用/改编号,函数当场断。FIN-22 之前
--    它们只是空架子,现在 record_expense/dispose_fixed_asset 都写死了它们:升为
--    is_system(种子对比 27 → 29,accounts.sql 镜像同步挪进 system 段)。

BEGIN;

-- 1. 旧签名(10 参)—— 参数列表精确匹配,别碰新的 11 参
DROP FUNCTION public.record_expense(date, text, numeric, text, numeric, text, text, uuid, text, text);

-- 2. B1:收回 PUBLIC/anon(authenticated 保留,require_permission 在函数体内把关)
REVOKE EXECUTE ON FUNCTION public.record_expense(date, text, numeric, text, numeric, text, text, uuid, text, text, jsonb) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.preview_depreciate_fixed_assets(date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.depreciate_fixed_assets(date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.dispose_fixed_asset(uuid, date, numeric, text, text) FROM PUBLIC, anon;

-- 3. 1500/1510 升为 is_system(函数写死引用,不许操作员停用/改号)
UPDATE public.accounts SET is_system = true WHERE code IN ('1500', '1510');

-- 自检:不许剩下任何一个 anon 可执行的新函数;两个科目必须已是 system
DO $mig$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname IN ('record_expense','preview_depreciate_fixed_assets',
                            'depreciate_fixed_assets','dispose_fixed_asset')
          AND has_function_privilege('anon', p.oid, 'EXECUTE')
    ) THEN
        RAISE EXCEPTION 'FIN22B_SELFCHECK_FAILED|仍有 anon 可执行的函数';
    END IF;
    IF (SELECT count(*) FROM public.accounts WHERE code IN ('1500','1510') AND is_system) <> 2 THEN
        RAISE EXCEPTION 'FIN22B_SELFCHECK_FAILED|1500/1510 未升为 is_system';
    END IF;
END
$mig$;

COMMIT;

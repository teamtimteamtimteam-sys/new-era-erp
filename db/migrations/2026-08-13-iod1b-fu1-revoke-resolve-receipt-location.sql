-- db/migrations/2026-08-13-iod1b-fu1-revoke-resolve-receipt-location.sql
-- IOD-1b 续:resolve_receipt_location 收回 authenticated 的 EXECUTE
--
-- gate 的 B2 点名它:SECURITY DEFINER、无调用者检查、可执行。走【收权】而不是
-- 【加检查】,理由与 IOD-1 fu2 那两个内层算子完全相同:它的三个调用方分属
-- 两个模块(进料两个 RPC 要 module.inbound.edit,产出那个要 module.output.edit),
-- 给它挑一个权限码只能挑一个比两者都松的 —— 那不是把关,是把关的样子。
-- 而三个调用方【各自已经把过关了】,它只是它们共用的一段翻译。
--
-- 收权之后它只能从别的 definer 函数体内以属主身份被调用 ——"调不到"本身
-- 就是保证,不依赖任何人记得写检查。
--
-- 镜像:db/views/zzz_function_grants.sql、db/check_mirrors.py 的允许清单。

BEGIN;

REVOKE EXECUTE ON FUNCTION public.resolve_receipt_location(uuid) FROM authenticated;

COMMIT;

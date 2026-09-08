-- db/functions/enforce_write_permission.sql
-- SILENT-1(2026-09-08)· 写权限的语句级闸。
--
-- 被 RLS 挡下的 UPDATE/DELETE 匹配零行、**不抛异常**,于是应用读到 error 为 null
-- 并报告成功。这一支让它抛,而且抛的是 `PERMISSION_DENIED|<码>` ——
-- require_permission 用了一年的那个形状,refuseFromCoded 今天就认得它。
--
-- 【为什么是语句级】行级触发器在零行时【根本不会触发】(实测)。语句级会。
-- 【为什么由 row_security_active 守着】触发器不认属主豁免:不加这一格,
--   五支 SECURITY DEFINER 的绩效自评函数会当场断,六个同事被锁在自己的考核外面。
-- 【为什么不是 DEFINER】row_security_active 必须反映【调用者】的视角。
--
-- 装在 133 张表上(带写策略的共 134 张;notification_reads 故意不装 ——
-- 它的谓词是 user_id = auth.uid(),那不是一个权限问题)。
-- NOTE: introduced by db/migrations/2026-09-08-silent1-refused-writes-raise.sql.

CREATE OR REPLACE FUNCTION public.enforce_write_permission()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    -- RLS 对当前身份不生效(属主 / SECURITY DEFINER / 迁移 / 种子)→ 放行。
    -- 没有这一行,自评那条路会当场断。见抬头。
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;

    -- 持有其中【任何一个】码就放行。单码表的 TG_ARGV 长度为 1。
    FOREACH v_code IN ARRAY TG_ARGV LOOP
        IF public.has_permission(v_code) THEN
            RETURN NULL;
        END IF;
    END LOOP;

    -- 一个都不持。抛 require_permission 用了一年的那个形状 ——
    -- refuseFromCoded 今天就认得它,不需要任何新的映射。
    RAISE EXCEPTION 'PERMISSION_DENIED|%', TG_ARGV[0];
END;
$function$;

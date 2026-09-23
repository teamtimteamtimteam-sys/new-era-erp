-- db/functions/guard_lock_reopen_path.sql
-- ROLE-1(Tim 的矩阵,2026-09-23):**重开已关的月只有 CFO 能做** —— 而此前有一扇侧门。
--
-- 【侧门】/finance/settings 的"手动锁"是对 finance_settings.locked_before 的一次直连
-- UPDATE,只要 module.finance.edit(RLS)。把它往回搬 —— 搬到一个已关的月之前,或者清空 ——
-- 效果与 reopen_period 一样(那个月又能过账了),却【不】在 period_closes 上盖重开戳、
-- 不要理由、也不经过 reopen_period 的门。guard_finance_settings_sod 只管【前进】的锁
-- (它的抬头写着"解锁不隐藏任何东西")—— 那句话管的是职责分离,不是【谁可以重开】。
--
-- 【规则】一次【直连】写(row_security_active = true),若把 locked_before 搬到
-- period_close_floor() 之前(或清空,而那条线存在),就拒绝:REOPEN_THROUGH_CLOSE_ONLY|<线-1>。
-- 往回搬但不越过那条线 —— 只是撤掉一次手动锁、没有重开任何已关的月 —— 照常放行:
-- 财务撤销自己的手动锁,不是一次"重开"。
--
-- 【为什么是 INVOKER】要分出"直连写"与属主路径(reopen_period 是 SECURITY DEFINER,
-- 它本身已要求 action.finance_reopen,并盖戳)。在 SECURITY DEFINER 里
-- row_security_active 答的是属主,永远 false —— 与 enforce_write_permission 同一个理由。
-- 线本身经 period_close_floor(属主身份)读,理由写在那支函数的抬头。
--
-- 【为什么不是"持 action.finance_reopen 就放行"】持那个码的 cfo 不持 module.finance.edit,
-- RLS 本来就不让它直连写这张表;而同时持两者的人今天不存在。给直连写开一条"有码就行"的
-- 路,等于给一条【不留戳】的重开路开门。重开只走 reopen_period。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.guard_lock_reopen_path()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_floor date;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF NEW.locked_before IS NOT DISTINCT FROM OLD.locked_before THEN
        RETURN NEW;
    END IF;
    -- 只管往回搬(或清空)
    IF NEW.locked_before IS NOT NULL
       AND (OLD.locked_before IS NULL OR NEW.locked_before >= OLD.locked_before) THEN
        RETURN NEW;
    END IF;

    v_floor := period_close_floor();
    IF v_floor IS NOT NULL
       AND (NEW.locked_before IS NULL OR NEW.locked_before < v_floor) THEN
        RAISE EXCEPTION 'REOPEN_THROUGH_CLOSE_ONLY|%', to_char(v_floor - 1, 'YYYY-MM-DD');
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_lock_reopen_path() IS
'ROLE-1:一次直连写若把 finance_settings.locked_before 搬到最新生效关账之后第一天之前(或清空),拒绝 REOPEN_THROUGH_CLOSE_ONLY —— 重开已关的月只走 reopen_period(action.finance_reopen,CFO),那条路盖戳、要理由。不越线的回搬(撤销一次手动锁)照常放行。INVOKER,以分出直连写与属主路径。';

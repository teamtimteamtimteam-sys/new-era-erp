-- db/functions/guard_environmental_parameter_code.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q16,Tim):environmental_parameters 上 BEFORE INSERT OR UPDATE OR DELETE,行级 ——
--   ① 限值与口径成对:一个不说是上限还是下限的数判不了任何结果,一个没有数的口径什么都没说 → ENV_LIMIT_NEEDS_BASIS
--      (表上的 CHECK 说的是同一句话;这里替它说出名字,不让人撞上一串约束名)。
--   ② 一个参数被结果用过之后,它的代号冻住、不能删 → ENV_PARAMETER_CODE_LOCKED|<代号>|<条数>(结果指着代号)。
--      名字、单位、限值、顺序、说明、启用照常可改 —— 结果在记下那一刻已经把单位与限值抄走了。
--   【DEFINER】数的是【所有】结果,不是读者读得到的那几条。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.guard_environmental_parameter_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n integer;
BEGIN
    IF TG_OP IN ('INSERT', 'UPDATE') AND ((NEW.limit_value IS NULL) <> (NEW.limit_basis IS NULL)) THEN
        RAISE EXCEPTION 'ENV_LIMIT_NEEDS_BASIS'
          USING HINT = '限值要说是上限(不许高于)还是下限(不许低于);要么两样都给,要么两样都空(Not yet set)。';
    END IF;
    IF TG_OP = 'INSERT' THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.code IS NOT DISTINCT FROM OLD.code THEN
        RETURN NEW;
    END IF;
    SELECT count(*) INTO v_n FROM environmental_results r WHERE r.parameter_code = OLD.code;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ENV_PARAMETER_CODE_LOCKED|%|%', OLD.code, v_n
          USING HINT = '这个参数已经有结果 —— 代号是结果指着的东西。名字、单位、限值可以改;要换代号,就新加一个。';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_incident_kind_code.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q4,Tim):【一种事故被用过之后,它的代号冻住】—— incident_kinds 上 BEFORE UPDATE OR DELETE,行级。
--   改代号(或删掉这一种)时,只要还有一件事故是这一种,或者有一次更正把某件事故改成了这一种,就按名拒
--   INCIDENT_KIND_CODE_LOCKED|<代号>|<件数> —— 改代号就是改外键指着的东西,而更正里存的是代号的字,外键看不见它。
--   名字、顺序、说明、启用照常可改(代号不变时直接放行)。
--   【DEFINER】数的是【所有】事故,不是读者读得到的那几件 —— 一个读不到某件事故的人,不能因此把它的种类改掉。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.guard_incident_kind_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n integer;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.code IS NOT DISTINCT FROM OLD.code THEN
        RETURN NEW;
    END IF;
    SELECT count(*) INTO v_n
      FROM (SELECT i.id FROM incidents i WHERE i.kind_code = OLD.code
            UNION
            SELECT u.incident_id FROM incident_updates u
             WHERE u.kind = 'correction' AND u.field = 'kind_code' AND u.new_value = OLD.code) x;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'INCIDENT_KIND_CODE_LOCKED|%|%', OLD.code, v_n
          USING HINT = '这一种已经被事故用过 —— 代号是事故指着的东西,改了或删了,那些事故就说不出自己是哪一种。名字可以改;要换代号,就新加一种。';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$function$;

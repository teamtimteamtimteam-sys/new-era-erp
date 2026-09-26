-- db/functions/guard_contract_write.sql
-- APR-8(2026-09-26,grilling Q2 · Q6):合同只有 active 有效力,所以【进入 active 的每一条路都经 CFO】。
--   INSERT:只许建草稿 —— 别的状态 → CONTRACT_ACTIVATES_THROUGH_REQUEST|编号
--     (旧的 /contracts/new 能选"生效",破窗里它会按名拒;新表单只剩草稿)。
--   UPDATE:
--     · 挂着一张在等的生效申请 → TERMS_REQUEST_FREEZES_CONTRACT|编号|那一张(先撤回)
--     · 改成 active → CONTRACT_ACTIVATES_THROUGH_REQUEST|编号(submit_contract_activation_request)
--     · 一份生效中的合同:只许把状态改成 suspended / expired / terminated(一步 —— 只会让效力变少),
--       其余任何一列变了 → CONTRACT_ACTIVE_IS_FROZEN|编号。改条款 = 暂停、编辑、申请重新生效。
--       ★ side 是生成列:BEFORE 触发器里 NEW.side 还是 NULL(生成列在触发器之后才算),比它会把每一次暂停
--         都读成"改了一列" —— fixture 227 H8 第一次就是这么红的。它由对手方那两列推出,那两列在比。
-- 行级,BEFORE INSERT OR UPDATE。属主路径(row_security_active = false)一律放行 —— 批准时那一次 UPDATE、迁移、
-- fixture 布景走的就是它。没有码的人在这之前已被写策略与 enforce_write_permission 拒掉。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_contract_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_lock text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'CONTRACT_ACTIVATES_THROUGH_REQUEST|%', COALESCE(NEW.code, NEW.title);
        END IF;
        RETURN NEW;
    END IF;
    v_lock := contract_terms_lock_reason(OLD.id);
    IF v_lock LIKE 'request:%' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_FREEZES_CONTRACT|%|%', OLD.code, substr(v_lock, 9);
    END IF;
    IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'CONTRACT_ACTIVATES_THROUGH_REQUEST|%', OLD.code;
    END IF;
    IF OLD.status = 'active'
       AND (NEW.status NOT IN ('suspended', 'expired', 'terminated')
            OR (to_jsonb(NEW) - 'status' - 'side' - 'updated_at' - 'updated_by')
               IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'side' - 'updated_at' - 'updated_by')) THEN
        RAISE EXCEPTION 'CONTRACT_ACTIVE_IS_FROZEN|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

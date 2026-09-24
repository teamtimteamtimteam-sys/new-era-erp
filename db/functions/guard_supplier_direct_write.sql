-- db/functions/guard_supplier_direct_write.sql
-- ROLE-1 · Batch 2a(Batch 2 grilling Q8,Batch 2a grilling Q2):把"建档人不能批自己建的"
-- 那条规矩的【主语】钉死,并把状态的改法收成一扇门。
--
-- Batch 2 的 grilling 量出这条规矩今天有三个洞,本守卫补的是其中两个半:
--   ① 直连 INSERT 可以把 created_by 写成任何人(trg_supplier_creator 只在 NULL 时落笔);
--   ② 直连 UPDATE 可以改写 created_by,或把它清成 NULL(清成 NULL = 规矩不再适用);
--   ③ 直连 INSERT 可以直接生出一家 approved / active 的供应商(跳转触发器跳过 INSERT)。
--
-- 【规则】
--   · created_by【任何路径都不许改】(属主路径也一样:一个会被改写的主语不是主语)
--     → SUPPLIER_CREATED_BY_IMMUTABLE。
--   · 直连写(row_security_active = true):
--       INSERT 的状态必须是 draft → SUPPLIER_INSERT_MUST_BE_DRAFT|<状态>;
--       INSERT 的 created_by 只能是空(由 trg_supplier_creator 落成自己)或自己
--         → SUPPLIER_CREATED_BY_FORGED;
--       INSERT 不许带批准戳;
--       UPDATE 改状态 → SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY(只走 set_supplier_status);
--       UPDATE 改批准戳 → SUPPLIER_APPROVAL_STAMP_THROUGH_FUNCTION_ONLY。
--   · 属主路径(fixture、批量导入、set_supplier_status)只受第一条约束 —— 批量导入本来就
--     不许带 status / created_by / 批准戳(master_import_forbidden_columns)。
--
-- 【触发器顺序】trg_supplier_creator(字典序在前)先把 NULL 落成 auth.uid(),
-- 本守卫(trg_suppliers_direct_write)后跑,看到的就是落笔之后的值 —— 所以
-- "空或自己"在这里读作"等于 auth.uid(),或仍为 NULL(auth.uid() 不是一个真账号)"。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_supplier_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'SUPPLIER_CREATED_BY_IMMUTABLE';
    END IF;
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'draft' THEN
            RAISE EXCEPTION 'SUPPLIER_INSERT_MUST_BE_DRAFT|%', NEW.status;
        END IF;
        IF NEW.created_by IS NOT NULL AND NEW.created_by IS DISTINCT FROM auth.uid() THEN
            RAISE EXCEPTION 'SUPPLIER_CREATED_BY_FORGED';
        END IF;
        IF NEW.approved_by IS NOT NULL OR NEW.approved_at IS NOT NULL THEN
            RAISE EXCEPTION 'SUPPLIER_APPROVAL_STAMP_THROUGH_FUNCTION_ONLY';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY';
    END IF;
    IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
        RAISE EXCEPTION 'SUPPLIER_APPROVAL_STAMP_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_supplier_direct_write() IS
'ROLE-1 Batch 2a:suppliers.created_by 任何路径都不许改(SUPPLIER_CREATED_BY_IMMUTABLE)。直连写(row_security_active)另受四条:INSERT 必须是 draft、created_by 只能是空或自己、不许带批准戳;UPDATE 不许改状态(只走 set_supplier_status)、不许改批准戳。INVOKER,以分出直连写与属主路径。';

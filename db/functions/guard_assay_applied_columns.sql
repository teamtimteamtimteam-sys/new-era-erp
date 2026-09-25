-- db/functions/guard_assay_applied_columns.sql
-- ROLE-1 · Batch 2b(Batch 2 grilling Q15 · Batch 2b grilling Q4):**应用化验结果只归 cto**
-- (action.apply_assay),记录化验结果仍归 module.inbound.edit / module.output.edit。
--
-- 【为什么需要一支守卫】assay_results 的写策略仍开在 inbound.edit / output.edit 上(记录结果
-- 的人要写它),于是一个持这两个码的人可以不经 apply_assay_result / apply_output_assay /
-- unapply_assay_result,直接把 applied_at / applied_by / superseded_by 写成"已应用"或"已撤销"——
-- 批次不重算价、含量不抄,但屏幕与提醒会把它当成应用过。本守卫把这三列收成只走函数:
--   · 直连 INSERT 带着其中任何一列(非 NULL)→ ASSAY_APPLY_THROUGH_FUNCTION_ONLY;
--   · 直连 UPDATE 改动其中任何一列(IS DISTINCT FROM)→ 同上;
--   · 别的列(备注、实验室、证书号……)照旧归记录的人。
-- 三支函数都是 SECURITY DEFINER,row_security_active = false,本守卫看不见它们。
--
-- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q10):**is_final 也只走函数**。
--   is_final 只在 record_assay_result(SECURITY DEFINER)里随那一行生下来;没有任何屏幕改它。
--   4b 起收货的 pricing_status 在 CFO 批准一张化验来源的申请时、且那份化验 is_final 才升 final,
--   而批准时读的是【那一刻】的 is_final(指纹里没有它)—— 直连改它就能左右批准之后是不是 final
--   (ROLE1B4B-ASSAY-IS-FINAL-DIRECT-EDIT)。直连 UPDATE 改它 → ASSAY_FINAL_THROUGH_FUNCTION_ONLY,
--   进料与产出两侧一律。记错了的正式标记,改法是录一份新化验取代旧的,不是改旧的。
--   直连 INSERT 带什么 is_final 都放行:一行没应用的化验,标记还不左右任何东西。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2b-contracts-prices-direct-sale-and-assay.sql.

CREATE OR REPLACE FUNCTION public.guard_assay_applied_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.applied_at IS NOT NULL OR NEW.applied_by IS NOT NULL OR NEW.superseded_by IS NOT NULL THEN
            RAISE EXCEPTION 'ASSAY_APPLY_THROUGH_FUNCTION_ONLY';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.applied_at IS DISTINCT FROM OLD.applied_at
       OR NEW.applied_by IS DISTINCT FROM OLD.applied_by
       OR NEW.superseded_by IS DISTINCT FROM OLD.superseded_by THEN
        RAISE EXCEPTION 'ASSAY_APPLY_THROUGH_FUNCTION_ONLY';
    END IF;
    IF NEW.is_final IS DISTINCT FROM OLD.is_final THEN
        RAISE EXCEPTION 'ASSAY_FINAL_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_assay_applied_columns() IS
'ROLE-1 Batch 2b:直连写(row_security_active)改动 assay_results.applied_at / applied_by / superseded_by,或直连 INSERT 带着其中任何一列,按名拒 ASSAY_APPLY_THROUGH_FUNCTION_ONLY;直连 UPDATE 改 is_final 按名拒 ASSAY_FINAL_THROUGH_FUNCTION_ONLY(ROLE-1 Batch 3a)—— 应用与撤销应用只走 apply_assay_result / apply_output_assay / unapply_assay_result(action.apply_assay,cto)。记录结果的其余列照旧。INVOKER,以分出直连写与属主路径。';

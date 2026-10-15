-- db/functions/guard_coa_mutation.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q31 · Q32):分析证书【签发之后内容一个字都不许改】(trg_certificates_of_analysis_mutation,BEFORE UPDATE OR DELETE)。
--   允许的只有两次改动,都由函数做:
--     ① issued → void(void_coa_internal):只动 status · void_reason · voided_at · voided_by;
--     ② 一张已作废、还没有替代品的证书,填一次 replaced_by_coa_id(issue_coa 签发它的下一张时)。
--   其余 —— 号、批、单、说话的化验、快照、签发时刻与人、作废之后再改回来、替代品改第二次 —— 一律按名拒 COA_ISSUED_IMMUTABLE|<号>;
--   作废不可逆 COA_ALREADY_VOID|<号>;删 COA_NO_DELETE|<号>。属主路径同样受它管 —— 它守的是档案的形状,不是权限。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.guard_coa_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'COA_NO_DELETE|%', OLD.code;
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.code IS DISTINCT FROM OLD.code
       OR NEW.output_batch_id IS DISTINCT FROM OLD.output_batch_id
       OR NEW.sales_order_id IS DISTINCT FROM OLD.sales_order_id
       OR NEW.governing_assay_id IS DISTINCT FROM OLD.governing_assay_id
       OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
       OR NEW.issued_by IS DISTINCT FROM OLD.issued_by
       OR NEW.snapshot IS DISTINCT FROM OLD.snapshot
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'COA_ISSUED_IMMUTABLE|%', OLD.code;
    END IF;
    IF OLD.status = 'void' THEN
        IF NEW.status <> 'void' THEN
            RAISE EXCEPTION 'COA_ALREADY_VOID|%', OLD.code;
        END IF;
        -- 作废之后:作废那几列冻住;替代品只许从空填一次
        IF NEW.void_reason IS DISTINCT FROM OLD.void_reason OR NEW.voided_at IS DISTINCT FROM OLD.voided_at
           OR NEW.voided_by IS DISTINCT FROM OLD.voided_by
           OR (OLD.replaced_by_coa_id IS NOT NULL AND NEW.replaced_by_coa_id IS DISTINCT FROM OLD.replaced_by_coa_id) THEN
            RAISE EXCEPTION 'COA_ISSUED_IMMUTABLE|%', OLD.code;
        END IF;
        RETURN NEW;
    END IF;
    -- OLD.status = 'issued':只许 → void(替代品在作废之后才有)
    IF NEW.replaced_by_coa_id IS NOT NULL THEN
        RAISE EXCEPTION 'COA_ISSUED_IMMUTABLE|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$

CREATE OR REPLACE FUNCTION public.guard_cod_immutable_after_issue()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF OLD.status = 'pending' THEN
        RETURN NEW;   -- 还没发出去,pending → issued / 删除,都由函数把关
    END IF;
    -- 已签发或已作废:身份与内容冻住,只留作废那几列可写。
    IF NEW.code IS DISTINCT FROM OLD.code
       OR NEW.verification_token IS DISTINCT FROM OLD.verification_token
       OR NEW.snapshot IS DISTINCT FROM OLD.snapshot
       OR NEW.issued_at IS DISTINCT FROM OLD.issued_at
       OR NEW.issued_by IS DISTINCT FROM OLD.issued_by
       OR NEW.inbound_batch_id IS DISTINCT FROM OLD.inbound_batch_id
       OR NEW.completed_on IS DISTINCT FROM OLD.completed_on THEN
        RAISE EXCEPTION 'COD_ISSUED_IMMUTABLE|%', COALESCE(OLD.code, OLD.id::text);
    END IF;
    -- 【作废不可逆】—— 与 void_invoice 的 INVOICE_ALREADY_VOID 同一条。
    IF OLD.status = 'void' AND NEW.status <> 'void' THEN
        RAISE EXCEPTION 'COD_ALREADY_VOID|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

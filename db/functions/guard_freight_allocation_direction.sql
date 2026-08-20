CREATE OR REPLACE FUNCTION public.guard_freight_allocation_direction()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_dir text; v_code text;
BEGIN
    SELECT direction, code INTO v_dir, v_code
      FROM public.freight_documents WHERE id = NEW.freight_document_id;
    IF v_dir IS NULL THEN
        RAISE EXCEPTION 'FREIGHT_DOCUMENT_NOT_FOUND|%', NEW.freight_document_id;
    END IF;
    IF v_dir <> 'inbound' THEN
        RAISE EXCEPTION 'EXPORT_FREIGHT_HAS_NO_ALLOCATIONS|%', v_code
          USING HINT = '出口运费是期间费用,不摊进任何批次 —— 给它一条分摊行就是把它塞进存货';
    END IF;
    RETURN NEW;
END;
$function$


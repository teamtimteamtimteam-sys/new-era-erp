CREATE OR REPLACE FUNCTION public.guard_bpca_batch_is_input()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_run_code   text;
    v_batch_code text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.processing_inputs pi
         WHERE pi.run_id = NEW.run_id
           AND pi.inbound_batch_id = NEW.inbound_batch_id
    ) THEN
        SELECT code INTO v_run_code   FROM public.processing_runs  WHERE id = NEW.run_id;
        SELECT code INTO v_batch_code FROM public.inbound_batches  WHERE id = NEW.inbound_batch_id;
        RAISE EXCEPTION 'BPCA_BATCH_NOT_AN_INPUT|%|%',
            COALESCE(v_run_code, NEW.run_id::text),
            COALESCE(v_batch_code, NEW.inbound_batch_id::text)
          USING HINT = '一笔加工成本只能资本化到【它自己那张加工单投过的料】身上。挂到别的批次上,成本会跟着那批货走进别人的产出单位成本里,而每一张分录仍然是平的 —— 错的是货,不是账。';
    END IF;
    RETURN NEW;
END;
$function$

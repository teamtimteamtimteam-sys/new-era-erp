CREATE OR REPLACE FUNCTION public.guard_forwarder_rate_quote()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_type text;
    v_code text;
BEGIN
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.supplier_id;
    IF v_type IS DISTINCT FROM 'forwarder' THEN
        RAISE EXCEPTION 'RATE_QUOTE_VENDOR_NOT_A_FORWARDER|%', COALESCE(v_code, NEW.supplier_id::text)
          USING HINT = '报价只能挂在货代身上;这一家不是货代';
    END IF;

    -- 【同一家、同一航段,有效期不许重叠】。重叠意味着同一天有两个价,
    -- 而"哪个算数"没有任何依据可以回答 —— 与其让读的人去猜,不如按名拒绝。
    IF EXISTS (
        SELECT 1 FROM public.forwarder_rate_quotes q
         WHERE q.supplier_id = NEW.supplier_id
           AND q.lane_id = NEW.lane_id
           AND q.deleted_at IS NULL
           AND q.id IS DISTINCT FROM NEW.id
           AND daterange(q.valid_from, q.valid_to, '[]') && daterange(NEW.valid_from, NEW.valid_to, '[]')
    ) THEN
        RAISE EXCEPTION 'FORWARDER_RATE_QUOTE_OVERLAP|%|%', COALESCE(v_code, ''), NEW.lane_id
          USING HINT = '这家货代在这条航段上已有一份有效期重叠的报价;先把旧的收尾或改期';
    END IF;
    RETURN NEW;
END;
$function$


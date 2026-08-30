CREATE OR REPLACE FUNCTION public.guard_sales_settlement_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:一条结算记录写下来之后就不可改 —— 除了被标成【被取代】那一列。
-- 理由:它是一次**要过钱的陈述**。就地改它会毁掉"当初要的是什么"这个记录,
-- 而那正是 guard_pricing_commitment_immutable 守着同一件事的原因。
-- 改正的办法是**再写一行**,并把旧的这一行的 superseded_by 指过去。
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SETTLEMENT_IMMUTABLE|delete'
          USING HINT = '结算记录不能删 —— 要改正,写一条新的并把这一条标成被取代';
    END IF;
    IF NEW.superseded_by IS DISTINCT FROM OLD.superseded_by
       AND to_jsonb(NEW) - 'superseded_by' = to_jsonb(OLD) - 'superseded_by' THEN
        RETURN NEW;   -- 只动了 superseded_by,那是允许的那一次改动
    END IF;
    RAISE EXCEPTION 'SETTLEMENT_IMMUTABLE|update'
      USING HINT = '结算记录只有 superseded_by 改得动 —— 要改正金额或依据,写一条新的';
END
$function$;

COMMENT ON FUNCTION public.guard_sales_settlement_immutable() IS
    'SETTLE-1:结算记录不可改(只有 superseded_by 一列动得了)。**它是一次要过钱的陈述**,就地改会毁掉「当初要的是什么」这个记录 —— 与 guard_pricing_commitment_immutable 同一条先例。改正 = 再写一行 + 把旧的标成被取代。';

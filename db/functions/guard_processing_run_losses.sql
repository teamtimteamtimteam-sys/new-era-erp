CREATE OR REPLACE FUNCTION public.guard_processing_run_losses()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_run_id  uuid := NEW.run_id;
    v_sum     numeric;
    v_loss    numeric;
    v_code    text;
BEGIN
    SELECT r.loss_qty, r.code INTO v_loss, v_code
      FROM public.processing_runs r WHERE r.id = v_run_id;

    -- MES-4a:只追加之后,一类的【当前】量是它那条更正链的末端(没有被别的行更正过的那一行)
    SELECT COALESCE(sum(l.quantity), 0) INTO v_sum
      FROM public.processing_run_losses l
     WHERE l.run_id = v_run_id
       AND NOT EXISTS (SELECT 1 FROM public.processing_run_losses x WHERE x.corrects_id = l.id);

    -- 【loss_qty 为空时不拦】空的意思是"这张单没有记过损耗总量",
    -- 而不是"总量是零"。拿 0 去比会把一条【没人填过】读成【上限为零】,
    -- 那正是本仓库反复付账的那个错(METAL-1 的 no_reference)。
    IF v_loss IS NOT NULL AND v_sum > v_loss THEN
        RAISE EXCEPTION 'LOSS_CATEGORIES_EXCEED_LOSS_QTY|%|%|%', v_code, v_sum, v_loss
          USING HINT = '有名字的损耗之和超过了这张加工单的损耗总量(投入 − 产出)。剩下的那一截是还没解释的余数,不许被说成比它更多。';
    END IF;
    RETURN NULL;
END;
$function$

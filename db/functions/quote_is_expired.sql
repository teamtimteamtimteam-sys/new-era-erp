CREATE OR REPLACE FUNCTION public.quote_is_expired(p_valid_until date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    -- SO-4a:【过期是算出来的,不存,也没有定时任务】
    -- 三个消费方读这一份:quote_status(列表与详情)、convert_quote 的拒绝。
    --
    -- 【为什么不是一个状态位】位要有人去清 —— 而 valid_until 一改,那个位就
    -- 立刻是假的,并且不会有任何东西提醒谁去改它。两个日期一比,答案永远是
    -- 当下的真相(同 SO-1b 的 amendedSinceIssue、FIN-30 的 ties)。
    --
    -- 【为什么不抄 CMP-1 那一对】证书过期的先例是【视图一遍 + 触发器一遍】,
    -- 它自己的注释写着"改一边要改两边",靠 fixture 37F 钉着两者一致。
    -- 这里不重演:一个函数,三个消费方。
    --
    -- 【边界含当天】valid_until = 今天的报价【仍然有效】—— "有效到 8 月 15 日"
    -- 的字面意思就是 15 日当天还算数。所以是严格小于。
    --
    -- 【不是 SECURITY DEFINER,所以不进 B2 那道判词】它只做日期算术,不读任何
    -- 一行业务数据,没有可保护的东西,也就没有"靠调不到"这回事。
    SELECT p_valid_until < CURRENT_DATE;
$function$

;

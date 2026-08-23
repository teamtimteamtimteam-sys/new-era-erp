CREATE OR REPLACE FUNCTION public.guard_downtime_period()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_s timestamptz;
    v_e timestamptz;
BEGIN
    -- 【① 开始时间不许在未来】
    -- 简报只点名了"结束不许在未来",而同一句话对开始一样成立 ——
    -- 一段"明天开始"的停机记的是【计划】,不是发生过的事。而这正是 B 那一半的
    -- 论点:计划与事件是两回事。**若将来真要记计划中的检修窗口,那是另一列**
    -- (与 planned_in_service_date 同形),不是把它塞进这一列。
    IF NEW.started_at > now() THEN
        RAISE EXCEPTION 'DOWNTIME_START_IN_FUTURE|%',
            to_char(NEW.started_at, 'YYYY-MM-DD HH24:MI');
    END IF;

    -- 【② 结束时间不许在未来】
    -- 【留空才是"还停着"】—— 而不是填一个将来的时刻当占位。
    IF NEW.ended_at IS NOT NULL AND NEW.ended_at > now() THEN
        RAISE EXCEPTION 'DOWNTIME_END_IN_FUTURE|%',
            to_char(NEW.ended_at, 'YYYY-MM-DD HH24:MI');
    END IF;

    -- 【③ 不许与同一台机器的另一段重叠】
    -- 既有的 uq_equipment_downtime_open 只拦【第二段开口】,对"新的一段落在
    -- 一段已关闭的里面"一个字都不说 —— 而线上发生的正是后者。
    --
    -- 【区间语义:左闭右开,所以【相接允许】】未关闭的一段上界当成 'infinity',
    -- 也就是"从那一刻起一直停着" —— 于是任何落在它之后的新段都会被拦,那是对的。
    -- 【先让形状不对的那一段走它自己的路】ended_at < started_at 时,下面的
    -- tstzrange() 会抛一句【原始的】Postgres 错("range lower bound must be..."),
    -- 抢在 equipment_downtime_period_order 这条具名 CHECK 前面 ——
    -- 于是操作员看见的是机器话,而不是"结束早于开始"。
    -- **这是 fixture 108F5 抓出来的**,不是想出来的:那一臂正是钉住那条 CHECK 的。
    IF NEW.ended_at IS NOT NULL AND NEW.ended_at < NEW.started_at THEN
        RETURN NEW;                      -- 交给 CHECK 去拒,它的句子更准
    END IF;

    SELECT d.started_at, d.ended_at INTO v_s, v_e
      FROM public.equipment_downtime d
     WHERE d.equipment_id = NEW.equipment_id
       AND d.id <> NEW.id
       AND tstzrange(d.started_at, COALESCE(d.ended_at, 'infinity'::timestamptz), '[)')
        && tstzrange(NEW.started_at, COALESCE(NEW.ended_at, 'infinity'::timestamptz), '[)')
     ORDER BY d.started_at
     LIMIT 1;
    IF FOUND THEN
        -- D6:把【挡路的那一段】的起止写进句子 —— 改它的人正对着一张列表。
        RAISE EXCEPTION 'DOWNTIME_OVERLAPS|%|%',
            to_char(v_s, 'YYYY-MM-DD HH24:MI'),
            COALESCE(to_char(v_e, 'YYYY-MM-DD HH24:MI'), '(还开着)');
    END IF;

    RETURN NEW;
END;
$fn$;

;

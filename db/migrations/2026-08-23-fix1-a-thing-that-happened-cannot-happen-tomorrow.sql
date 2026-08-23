-- FIX-1:一件【发生过】的事,不可能在明天发生
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一个主题,两个器官】
-- A. 一段停机可以填一个【未来】的结束时间,而且两段可以重叠。
-- B. 一台机器的投用日可以是【未来】,于是每一把锁都锁上了,而折旧一分不提。
-- 两件事是同一句话:**一个记录"世界上发生过什么"的日期,不可以在未来。**
--
-- 【S2 先答,因为它决定机制】PROC-5 与 PROC-6 都实测过:NOT VALID 在【任何一次
-- UPDATE】上都重算整行。而这两张表的行都会被 UPDATE ——
--   * equipment_downtime:**关闭一段停机就是一次 UPDATE**(closeDowntime 只改 ended_at);
--   * fixed_assets:状态、成本、投用日都会改。
-- 所以 NOT VALID 在这里是陷阱,两条规则都由【触发器】执行。
--
-- 【为什么不用 CHECK,而这一条是实测出来的,不是想当然】
-- 先试过:`CHECK (d <= CURRENT_DATE)` **PostgreSQL 是接受的**,而且拦得住 ——
-- 我原以为它会因为"非不可变"被拒,那个判断是错的,测了才知道。
-- 但它仍然不是对的工具,理由有两条,而且都不是风格问题:
--   ① **重叠规则根本写不成 CHECK** —— 它要看【别的行】。
--   ② D6 要求拒绝的句子里带上【冲突本身】(撞上的是哪一段的起止、你填的是哪一天)。
--      一条 CHECK 的消息只带得出约束名;`RAISE ... USING` 带得出参数。
-- **把同一句话的两半放进两种机制,是它们开始漂开的方式** —— 所以两半都用触发器。
--
-- 【为什么不用排他约束(EXCLUDE + tstzrange)】它是重叠这类问题的教科书答案,
-- 但两条挡着:线上【没装 btree_gist】(实测 pg_extension 里 0 行),装它等于给
-- prelude 添一个平台依赖;而且它同样带不出"挡路的是哪一段"。
--
-- 【相接【允许】,重叠不允许 —— 这一条现在就定死,不留给下一次争论】
-- 一段 14:00 结束、下一段 14:00 开始,描述的是"机器回来了又立刻停了" ——
-- 在分钟精度下这是一句真话,拒绝它只会逼人把时间填歪一分钟。
-- 判据用【左闭右开】的区间语义:[started_at, ended_at) —— 相接不算重叠。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- A-D3 · 线上那两行,先处置再立规矩(否则规矩是个陷阱)
--
-- 【它们全文长这样】(FIX-1 落地前从线上抄下来,一个字没改):
--   ① a58b1f9b… FA-2026-0001  14:22:00 → **2026-08-24 14:23:00**  reason 'Test'
--   ② e8fbe3e6… FA-2026-0001  14:23:00 → (还开着)                 reason 'TEst'
--   两者都建于 2026-08-23 14:22/14:23,相隔 57 秒。
--
-- **它们不可能同时为真**:①说这台机器从 23 日 14:22 一直停到【明天】14:23,
-- 而②说它从 23 日 14:23 起【又】开始停 —— 那一刻它按①的说法本来就停着。
--
-- 【处置:两行都删,而这【不是】在编造事实】
--   * 两行的 reason 分别是 'Test' 与 'TEst' —— 它们是 Tim 自己走查时敲的测试行;
--   * ①的结束时间在【未来】,那显然是把 23 日敲成了 24 日的手滑;
--   * 而删【一个不可能的组合】不等于替谁做判断:这里没有"哪一行是真的"要选,
--     因为**两行都是测试**,而真相是"这台机器那天没有真的停过"。
--   * 而且【没有别的路】:app 里只有"开一段"与"关一段"两个动作,
--     **没有删除、也没有更正的门**(S3 实测)。不在这里删,它们就永远卡在那儿,
--     并且会让 A-D2 一落地就拒掉②的关闭 —— 规矩变成陷阱。
-- 记在 docs/known-wrong-until-cutover.md,两行的 id 都点了名。
-- ════════════════════════════════════════════════════════════════════════════
DELETE FROM public.equipment_downtime
 WHERE id IN ('a58b1f9b-ade8-4848-8f39-9414ea9a3309',
              'e8fbe3e6-8385-4429-b4d3-83f50e2437a4');

-- ── A · 停机:不许在未来,不许重叠 ──────────────────────────────────────────
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
REVOKE EXECUTE ON FUNCTION public.guard_downtime_period() FROM PUBLIC, anon;

CREATE TRIGGER trg_equipment_downtime_period
    BEFORE INSERT OR UPDATE ON public.equipment_downtime
    FOR EACH ROW EXECUTE FUNCTION public.guard_downtime_period();

-- ════════════════════════════════════════════════════════════════════════════
-- B · 计划与事件
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.fixed_assets ADD COLUMN planned_in_service_date date;

COMMENT ON COLUMN public.fixed_assets.planned_in_service_date IS
'FIX-1:【计划】投用日 —— 打算什么时候把它投产。

**它可以在未来。它不锁任何东西,不驱动任何规则,【没有一条规则读它】。**

【为什么要有这一列】Tim 在 in_service_date 上填了 2027-01-01,想记的是
"这条线明年投产"。**那一列装不下这个意思**:每一条规则测的都是
`in_service_date IS NOT NULL`,从不测"是不是已经到了那天"。于是那台机器被当成
【已投用】锁了起来 —— 追加成本被拒、冲销被拒、保养基线从一个负的天数起算 ——
而折旧要等到 2027 才会跑。**每一把锁都锁上了,一分钱折旧都没提。**

【给下一个人的一句话:不要让任何规则读这一列】
它一旦被某条规则读了,就又变回了 in_service_date 那个问题 ——
一个"打算"开始产生"已经发生"才该有的后果。要判断在不在役,读 in_service_date。';

COMMENT ON COLUMN public.fixed_assets.in_service_date IS
'投用日 —— 这台机器【真的开始服役】的那一天。折旧从这一天起算,不从购置日。

**它不可以在未来**(FIX-1,由 guard_asset_in_service_not_future 执行)。
投用是一件【发生过的事】;"打算什么时候投用"是 planned_in_service_date。

【为什么必须分开:FIX-1 之前它们挤在一列里,后果是实测到的】
线上 FA-2026-0001 的这一列曾是 2027-01-01。每一条规则测的都是
`IS NOT NULL`(而不是"到了没有"),于是:
  * record_expense 拒绝再追加成本(资产已"投用");
  * reverse_expense 拒绝冲销;
  * set_asset_in_service 拒绝再设;
  * 而 preview_depreciate_fixed_assets 【是】比日期的,所以折旧要等到 2027。
**锁全上,折旧全无** —— 40 万就那么冻着。

【留空 = 还没投用】那不是"不知道",是一个明确的状态:这台机器还没开始服役。';

-- ── B-D2/B-D4 的执行者:投用日不许在未来 ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_asset_in_service_not_future()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 与停机那一条【同一句话】:投用是一件发生过的事。
    -- 【只看 in_service_date,绝不看 planned_in_service_date】——
    -- 后者可以在未来,那正是它存在的全部理由。
    IF NEW.in_service_date IS NOT NULL AND NEW.in_service_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSET_IN_SERVICE_IN_FUTURE|%', NEW.in_service_date;
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_asset_in_service_not_future() FROM PUBLIC, anon;

CREATE TRIGGER trg_fixed_assets_in_service_not_future
    BEFORE INSERT OR UPDATE ON public.fixed_assets
    FOR EACH ROW EXECUTE FUNCTION public.guard_asset_in_service_not_future();

-- ── B-D4 · 那一行:2027-01-01 搬到计划列,投用日置空 ────────────────────────
-- 【这【不是】在丢信息,也不是替 Tim 做判断】那个日期一个字没变,只是搬到了
-- 装得下它的那一列。Tim 想说的("这条线明年投产")从此读得出来,
-- 而"这台机器还没投用"也读得出来 —— 此前这两件事被挤成了一个值。
-- 顺序要紧:先搬,再置空 —— 否则新触发器会拦住这次 UPDATE 自己。
UPDATE public.fixed_assets
   SET planned_in_service_date = in_service_date,
       in_service_date = NULL
 WHERE in_service_date > CURRENT_DATE;

COMMIT;

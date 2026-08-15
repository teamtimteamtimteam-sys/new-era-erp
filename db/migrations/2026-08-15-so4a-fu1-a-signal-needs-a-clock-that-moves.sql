-- SO-4a fu1(2026-08-15):"签发之后又改过"要能【比得出先后】—— now() 比不出来
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【fixture 72 自己抓到的,不是读出来的】G 臂走的是那条最要紧的路:签发 → 改一行
-- 明细 → 信号必须亮。它红了,而红得对:
--
--     now() 是【事务开始的时刻】,在一个事务里是常量。
--     qt_issues.issued_at DEFAULT now(),quotes.updated_at := now()(update_updated_at)。
--     于是同一个事务里"先签发、后改动"这两件事拿到的是【同一个时间戳】,
--     max(issued_at) < updated_at 恒为 false —— 信号永远不亮。
--
-- 【这不只是 fixture 的毛病,虽然它是被 fixture 撞出来的】
-- 生产里签发与编辑是两次请求、两个事务,所以信号照常工作;但只要有人在一个
-- 事务里连着做这两件事(脚本、psql、将来某个把两步合一的 RPC),信号就会
-- 【沉默】—— 而它沉默的方向正是危险的那一边:客户手里那份已经过时了,屏幕上
-- 却什么都不说。一个只在"通常情况下"成立的警报,是最不该被信任的那一种。
--
-- 【而且它连被验证的资格都没有】这个仓库的规矩是"一条从没被看着失败过的检查,
-- 不叫已知可用,只叫暂时安静"。用 now() 的话,这条信号在【任何】fixture 里都
-- 观察不到 —— 因为 fixture 就是一个事务。修掉时钟,它才第一次变得可断言。
--
-- 【修法:这两列改用 clock_timestamp()】
--   quotes.updated_at   —— 由本刀自己的触发器写(不再借用共用的 update_updated_at)
--   qt_issues.issued_at —— 默认值改成 clock_timestamp()
--
-- 【为什么只改这两列,不去动共用的那个 update_updated_at】那个助手服务着十几张
-- 表,而它们的 updated_at 是【审计痕迹】,不是某个比较式的一边:没有人拿它们
-- 与另一个时间戳比先后,所以事务时刻完全够用,改它是一次没有理由的波及。
-- 这两列不同 —— 它们的【全部用途】就是比出先后。列的用途不同,时钟就该不同。
--
-- 【代价说清楚】clock_timestamp() 不是事务一致的:同一个事务里两次调用得到两个
-- 值。对"审计这一行什么时候动的"那种用途这是缺点(同一批改动会显示成不同时刻),
-- 对"谁在谁之后"这种用途它恰恰是唯一能用的东西。这两列属于后者。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 签发时刻:真实的墙上时钟 ────────────────────────────────────────────────
ALTER TABLE public.qt_issues ALTER COLUMN issued_at SET DEFAULT clock_timestamp();

COMMENT ON COLUMN public.qt_issues.issued_at IS
    'SO-4a:这一版签发出去的时刻。【clock_timestamp() 而不是 now()】—— 它是"签发之后又改过"那个比较式的一边,而 now() 是事务开始时刻、在一个事务里是常量:同一事务里先签发后改动会拿到同一个时间戳,信号于是永远不亮(fixture 72 G 臂撞出来的)。列的用途是比出先后,时钟就必须会走。';

-- ── 报价的 updated_at:自己的触发器 ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.quotes_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    -- 【clock_timestamp(),不是 now()】见本迁移抬头:这一列是
    -- amended_since_issue 那个比较式的一边,而不是一条普通的审计痕迹。
    -- 共用的 update_updated_at 仍然服务着其余十几张表 —— 那些列没有人拿去
    -- 比先后,事务时刻对它们完全够用。
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$function$;

DROP TRIGGER trg_quotes_updated_at ON public.quotes;
CREATE TRIGGER trg_quotes_updated_at
    BEFORE UPDATE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.quotes_touch_updated_at();

-- 【行的回 touch 也要走同一个时钟】它写的是同一列;留着 now() 的话,
-- 改明细这条最常见的路仍然比不出先后 —— 而那正是 G 臂要盯的那条路。
CREATE OR REPLACE FUNCTION public.trg_quote_line_touches_parent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【父行已经不在时是一次空更新,而不是一个错误】整张报价被硬删时,级联
    -- 删子行会走到这里,而那时父行在本快照里已经删掉 —— UPDATE 命中 0 行。
    -- 写下来是因为"命中 0 行"在别处通常是要报警的(失败不是空集),这里它
    -- 恰恰是对的:父行没了,没有 updated_at 需要顶。
    -- 【updated_at 交给 BEFORE UPDATE 触发器写】—— 这里只负责"碰一下",
    -- 时钟只有一处(quotes_touch_updated_at),不在两个地方各写一遍。
    UPDATE quotes SET updated_by = auth.uid()
     WHERE id = COALESCE(NEW.quote_id, OLD.quote_id);
    RETURN COALESCE(NEW, OLD);
END;
$function$;

COMMIT;

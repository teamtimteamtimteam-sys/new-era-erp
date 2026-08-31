-- PROC-COST-1 fu2(2026-08-31):成本读取器不许把行【丢】给 RLS
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【实测出来的缺陷,不是推理】
-- batch_processing_cost_base 是 SECURITY INVOKER(照 FRT-1 fu2 的先例:
-- "一个金额读取器不该替调用者绕过 RLS")。而它的函数体里有一个
-- JOIN processing_runs —— 那张表的 SELECT 策略要的是 module.processing.view。
--
-- 于是:**一个只有 module.inbound.view 的读者(仓管、进料),在批次页上调它,
-- 那个 JOIN 会把每一行都丢掉,函数安静地返回 0。** 不报错、不提示 ——
-- 那批料身上明明挂着 500 的加工成本,而屏幕上写着 0。
--
-- **这正是本仓库 OPS-14 命名过的那一族:`colreader` 问的是【列】读不读得到
-- (读不到 → 42501,响亮);`xmodule` 问的是【行】—— 读不到就【无声消失】。**
-- 而 0.00 与「受限」不是同一件事:第一个是谎话(AGENTS.md,lib/permissions.ts
-- 存在的全部理由)。而本刀的验收条件正是"操作员能在屏幕上看见这个数",
-- 所以这条缺陷恰好打在它最要紧的地方。
--
-- 【为什么 batch_freight_base 没有这个毛病,而这一支有】
-- freight_documents 的 SELECT 策略是 inbound.view OR finance.view ——
-- 与运费的读者是同一批人,所以 INVOKER 在那里是安全的。
-- processing_runs 不是:它是【另一个模块】。**照抄一个先例之前,要问的是
-- 那个先例成立的条件在这里成不成立** —— 这一次不成立。
--
-- 【处置:属主权限 + 把读者的判据【写进函数体】】
-- 这是 OPS-14 那张处置表的 (a) 支:借来的是一个【派生事实】(这张单还活着吗),
-- 不是第二道权限边界。属主权限让 JOIN 不再丢行;而把 has_permission 写进体内,
-- 保证边界仍然由调用者决定,不是被属主替换掉 —— has_permission 是
-- SECURITY DEFINER 解析 auth.uid(),问的永远是【调用者】。
--
-- 【无权时返回 NULL,不是 0】—— 「受限」与「没有」必须分得开。
--
-- 【那个 NULL 不会污染成本分摊,而这是【按构造】的,不是指望】
-- allocate_processing_costs 第一行就是 require_permission('module.processing.edit'),
-- 所以任何走到那里的调用者【必然】持有它 —— 而它在下面的白名单里。
-- 于是那条材料成本表达式里,这一支永远不可能是 NULL。
-- (若不把 processing.edit 列进白名单,一个只有 edit 没有 view 的角色会让
--  SUM 里那一项变成 NULL,而 SUM 会把整条腿【跳过】—— 一个静默变小的材料成本。
--  白名单里那一项就是为了让这件事不可能发生,不是为了宽松。)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.batch_processing_cost_base(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【派生,不存冗余列】落地成本 = quantity × unit_price
    --                              + batch_freight_base + 本函数。
    -- 【冲销即解除】回滚把加工单软删(deleted_at),这里就不再计它 ——
    -- 与 batch_freight_base 只认 status = 'posted' 的运费单是同一条。
    -- 【属主权限 + 体内判据】见 fu2 迁移抬头:JOIN processing_runs 会把行丢给
    -- 一个只有 inbound.view 的读者,而丢行是【无声】的。0.00 与「受限」不是
    -- 同一件事,所以无权时返回 NULL。
    SELECT CASE
        WHEN has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          -- 【edit 也在列】allocate_processing_costs 的调用者必然持有它,
          -- 于是那条材料成本表达式里这一支【按构造】不可能是 NULL。
          OR has_permission('module.processing.edit')
        THEN (
            SELECT COALESCE(SUM(a.amount_base), 0)
            FROM batch_processing_cost_allocations a
            JOIN processing_runs r ON r.id = a.run_id
            WHERE a.inbound_batch_id = p_inbound_batch_id
              AND r.deleted_at IS NULL AND r.status = 'committed'
        )
        ELSE NULL
    END;
$function$;

COMMENT ON FUNCTION public.batch_processing_cost_base(uuid) IS
    'PROC-COST-1:一批进料身上已资本化的加工成本合计。【属主权限 + 体内 has_permission】—— 它 JOIN processing_runs(module.processing.view),而 INVOKER 会让一个只有 module.inbound.view 的读者把每一行都丢掉、安静地得到 0(OPS-14 的 xmodule 那一族:丢列响亮、丢行无声)。无权时返回 NULL 而不是 0 —— 「受限」与「没有」必须分得开。白名单里含 module.processing.edit,是为了让 allocate_processing_costs 的材料成本表达式【按构造】不可能读到 NULL。';

COMMIT;

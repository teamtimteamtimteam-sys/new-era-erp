-- db/functions/inbound_batch_landed_unit_cost.sql
-- CLEANUP-A:落地单位成本的【读者】名 —— 自带判据(R3:授权不是控制)。
-- fu1 起算术委托给 inbound_batch_landed_unit_cost_all:要算过账的钱的调用方读 _all,
-- 因为【给人看一个价格】要问权限,【算一笔要过账的钱】不许问权限。

CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【R3:授权不是控制】—— 一个【拿得到 EXECUTE】的调用者仍然被这里拦住。
    -- db/fixtures/174 的 E 臂刻意以那样的身份来问,问的就是这一句。
    -- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q5):原来这里还放行 module.stocktakes.edit
    --   (CLEANUP-A 为盘点 / 注销那条路留的)。fu1 之后那两条路读的是 _all,这一支早已无人走 ——
    --   它只剩一个效果:让持盘点码的仓库读到到岸成本(ROLE1B4A-LANDED-COST-STOCKTAKE-EXCEPTION)。拿掉。
    IF NOT has_permission('data.view_prices'::text) THEN
        RAISE EXCEPTION 'LANDED_COST_PERMISSION_DENIED|%', 'data.view_prices'
          USING HINT = '落地单位成本【是一个价格】—— 要看它得有 data.view_prices。'
                       '这不是"这批货没有金额",是权限:两者在这支函数里必须分得开。'
                       '【要算一笔过账的钱、而不是给人看】的调用方读 _all 那一支。';
    END IF;
    -- 【算术只有一份】委托给 _all,不复制 —— 两份实现会悄悄分开。
    RETURN inbound_batch_landed_unit_cost_all(p_inbound_batch_id);
END
$function$;

COMMENT ON FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid) IS
    'CLEANUP-A:落地单位成本的【读者】名 —— 自带判据 data.view_prices(ROLE-1 Batch 3a 拿掉了 module.stocktakes.edit 那一支;R3:授权不是控制,一个拿得到 EXECUTE 的调用者也被拦)。拒绝用 RAISE 不用 NULL,因为本支的 NULL 已经有主:它是"这批货真的没有金额",inbound_batch_valuation.unpriced 就定义为它 IS NULL。fu1 起算术委托给 inbound_batch_landed_unit_cost_all —— 【要算过账的钱】的调用方读 _all 那一支,因为账上的金额不许取决于按按钮的人有什么读权限。';

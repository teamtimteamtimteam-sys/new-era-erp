-- INV-VAL-1-fu6:属主权限【借不到】函数的 EXECUTE —— /inventory 线上正在报错
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【这是 INV-VAL-1 的一处回归,线上已经错了约一个小时,由 FX-DISPLAY-1 的
--     "亲眼看一遍渲染出来的页面"这一步抓到】★★
--
-- 症状:以任意 authenticated 用户打开 /inventory,整页渲染成一个红框:
--     42501 permission denied for function inbound_batch_landed_unit_cost
-- /inventory/inbound/[materialId] 同样。**HTTP 状态是 200。**
--
-- 【成因,而这条规矩仓库里早就写着,我读过还是踩了】
--   inbound_batch_valuation 是 security_invoker = off 的视图,体内调
--   inbound_batch_landed_unit_cost —— 那支函数【没有】授给 authenticated
--   (刻意如此:它是 definer、直接读基表 unit_price、绕过价格遮蔽)。
--   而 db/functions/aging_bucket.sql 的抬头写得清清楚楚:
--       「属主权限替得了【表】,替不了【函数的 EXECUTE】—— 那仍按当前用户判。
--         收掉它,两页会当场 42501。」
--   视图的属主权限【不改变 current_user】,所以体内那次函数调用仍按调用者判。
--   **SECURITY DEFINER 才改变 current_user** —— 这正是为什么同样调那支函数的
--   inventory_valuation_snapshot(definer + 已授权)一直好好的。
--
-- 【为什么当时没被任何一道闸拦下 —— 三条判据同时看不见它】
--   ① 我在 INV-VAL-1 里的探针是 `SELECT count(*) FROM inbound_batch_valuation`。
--      **计划器把用不到的列剪掉了**,那次函数根本没被调用,于是它是绿的。
--      实测对照:`WHERE remaining_qty > 0` 的 count(*) 【通过】,
--      而一旦 SELECT 到 landed_unit_cost 或按 unpriced 过滤就 42501。
--   ② gate 跑 fixture 是以 postgres 身份,postgres 有 EXECUTE —— 照不到这条。
--   ③ 冒烟的判据是 2xx,而这一页【自己把错误画成了红框】,HTTP 200。
--      scripts/smoke-routes.mjs 的抬头把这个盲区写得一字不差,而它又中了一次。
--
-- 【修法:一支【已授权的 definer 包装】,而不是给那支函数授权】
--   委托书明令:inbound_batch_landed_unit_cost 排在开账前的权限清理里,
--   **本刀不许给它授任何东西**。授了它,采购单价就发给了每一个 authenticated
--   用户(operations 与 warehouse 实测正是没有 data.view_prices 的那两个角色)。
--   所以:新开一支 SECURITY DEFINER 的取数函数,授给 authenticated,
--   **它自己 require_permission + 自己按 data.view_prices 遮蔽价格**;
--   它体内以属主(postgres)身份去调那支未授权的函数 —— current_user 变了,
--   EXECUTE 就过得去。那支函数的授权面【一个字没动】。
--   视图改成 `SELECT * FROM 这支函数()`,于是应用的调用点、列名、列序全不变。
--
-- 【unpriced 为什么不遮蔽】"这批货有没有价"是一个事实,不是价;
--   它是 M9 的判据,而且 /inventory 的"未计价"徽标靠它。
--   它在 definer 体内用【未遮蔽】的结果算出来,所以受限读者拿到的是
--   landed_unit_cost = NULL 而 unpriced = false —— 「你看不到」不是「它没有价」。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.inbound_batch_valuation_rows()
 RETURNS TABLE(id uuid, code text, material_id uuid, supplier_id uuid, unit text,
               quantity numeric, remaining_qty numeric, arrival_date date, stage text,
               landed_unit_cost numeric, landed_value_base numeric, unpriced boolean,
               aging_days integer, aging_bucket text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_prices boolean;
BEGIN
    -- 【definer 必须自己问调用者是谁】—— 授权不是控制。
    PERFORM require_permission('module.inventory.view');
    v_prices := has_permission('data.view_prices');

    RETURN QUERY
    SELECT ib.id, ib.code, ib.material_id, ib.supplier_id, ib.unit,
           ib.quantity, ib.remaining_qty, ib.arrival_date, ib.stage,
           -- 价格遮蔽:没有 data.view_prices 的读者得 NULL,【不是 0】
           CASE WHEN v_prices THEN inbound_batch_landed_unit_cost(ib.id)
                ELSE NULL::numeric END,
           CASE WHEN v_prices
                THEN round(COALESCE(ib.remaining_qty * inbound_batch_landed_unit_cost(ib.id), 0), 2)
                ELSE NULL::numeric END,
           -- 【不遮蔽】有没有价是事实,不是价
           (inbound_batch_landed_unit_cost(ib.id) IS NULL),
           (CURRENT_DATE - ib.arrival_date)::integer,
           aging_bucket((CURRENT_DATE - ib.arrival_date)::integer)
      FROM inbound_batches ib
     WHERE ib.deleted_at IS NULL;
END;
$function$;

COMMENT ON FUNCTION public.inbound_batch_valuation_rows() IS
    'INV-VAL-1-fu6:inbound_batch_valuation 的取数体。★存在的唯一理由:视图的属主权限【替不了函数的 EXECUTE】(aging_bucket 抬头记着这条规矩),而 inbound_batch_landed_unit_cost 刻意没有授给 authenticated —— 于是那张视图一被 SELECT 到计算列就 42501,/inventory 与进料钻取页在线上整页报错。SECURITY DEFINER 会改变 current_user,所以在这里调那支未授权的函数是过得去的;而它【不给那支函数授任何权限】,那一条排在开账前的权限清理里。本函数自己 require_permission、自己按 data.view_prices 遮蔽价格;unpriced 不遮蔽 —— 有没有价是事实,不是价。';

GRANT EXECUTE ON FUNCTION public.inbound_batch_valuation_rows() TO authenticated;

-- 视图改成读那支函数。【列名、列序、授权全不变】,应用的调用点一个字不用改。
-- 【WITH (...) 必须写出来】不写的话 CREATE OR REPLACE 会把既有的 reloptions
-- 【悄悄丢掉】(实测:第一版就把 security_invoker=off 丢了,而姊妹视图
-- output_batch_valuation 还留着 —— 两张同族视图从此长得不一样)。
-- 行为上没变(PostgreSQL 的默认本来就是属主权限,AGENTS.md 记着这一条),
-- 红的是【镜像文本】与【下一个人能不能看出这是刻意声明过的】。
CREATE OR REPLACE VIEW public.inbound_batch_valuation WITH (security_invoker = off) AS
 SELECT id, code, material_id, supplier_id, unit, quantity, remaining_qty,
        arrival_date, stage, landed_unit_cost, landed_value_base, unpriced,
        aging_days, aging_bucket
   FROM inbound_batch_valuation_rows();

COMMENT ON VIEW public.inbound_batch_valuation IS
    'INV-VAL-1:进料批次的【唯一】估值读取器 —— 口径 inbound_batch_landed_unit_cost(采购价 + 运费 + 已资本化加工成本),与注销、盘点、gl_control_reconciliation 同一份定义。fu6 起它只是 inbound_batch_valuation_rows() 的一层壳:视图的属主权限替不了函数的 EXECUTE,而那支成本函数刻意未授权给 authenticated,所以取数必须发生在一支 SECURITY DEFINER 函数里(那才改变 current_user)。landed_* 按 data.view_prices 遮蔽成 NULL(不是 0);unpriced 不遮蔽 —— "有没有价"是事实不是价。';

COMMIT;

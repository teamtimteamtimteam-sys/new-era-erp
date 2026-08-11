-- PUR-2 fu3(2026-08-11):收货推进状态的那个触发器也要声明自己
--
-- 【怎么漏的,值得记一笔】fu1 找"谁会改采购单状态"用的是
--     grep -rln "UPDATE purchase_orders" db/functions/
-- 而 advance_po_on_receipt 是一个【触发器函数】,它住在 db/tables/ 的表镜像里
-- (这个仓库的惯例:守卫与取号这类触发器函数跟着它们的表走)。于是它不在结果里,
-- 上守卫之后收一次货就撞 PO_STATUS_NOT_AMENDABLE|status|confirmed|receiving。
--
-- 【判据应当问目录,不是问文件树】
--     SELECT proname FROM pg_proc WHERE prosrc ~ 'UPDATE\s+purchase_orders' AND prosrc ~ 'status'
-- 目录一次给全 8 个,文件树给的是"我记得去翻的那几个目录"。
-- 与 check_mirrors 用 pg_depend 而不是解析 SQL、xmodule 用 pg_policy 而不是读视图体,
-- 是同一条:【结构性的事实向目录要,不向文本要】。

BEGIN;

CREATE OR REPLACE FUNCTION public.advance_po_on_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.purchase_order_id IS NOT NULL THEN
        -- PUR-2:收货把单据从 confirmed 推到 receiving —— 那是一次【状态转换】,
    -- 不是一次修改。与另外五个转换函数同一个标记,用完立刻清。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
        SET status = 'receiving', updated_by = auth.uid()
        WHERE id = NEW.purchase_order_id AND status = 'confirmed';
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    END IF;
    RETURN NULL;
END;
$function$;

COMMIT;

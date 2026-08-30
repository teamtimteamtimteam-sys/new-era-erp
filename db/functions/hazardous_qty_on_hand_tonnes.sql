-- db/functions/hazardous_qty_on_hand_tonnes.sql
-- CMPL-1:在场危废吨数 —— ★今天【算不出来】,而这一支存在就是为了说出这句话★
--
-- 【为什么它返回 NULL,而 NULL 不是零】
--   要算"在场危废有多少吨",先得说得出【哪些料算危废】。今天说不出:
--     · waste_classifications 线上 **2 行**(focused / non_focused);
--     · 它的 is_controlled 列 **全库零个消费方** —— views 与 functions 里一次都没被读过;
--     · 这两行【对不上】NEA"批准废物类别"那套词汇。
--   把 is_controlled 硬映射成 NEA 的类别是**发明**,不是建模,所以这条推导
--   **排队而不是猜**。触发条件:**分类字典能表达 NEA 的批准废物类别那天**。
--
-- ★【把 NULL 读成 0 的实现,会让任何上限检查都轻松通过】★ —— 那正是 R2 点名的
--   "制造出来的信心",也是本刀最要紧的一条区别。
--   换成真推导那天,licence_storage_within_limit() 一个字都不用改:它读的是
--   "是不是 NULL",不是别的。
CREATE OR REPLACE FUNCTION public.hazardous_qty_on_hand_tonnes()
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【今天无条件返回 NULL = 算不出来】理由在函数抬头,不在这一行。
    -- 分类字典能表达 NEA 的批准废物类别之后,这里换成真的推导,
    -- 而**上面那支判据一个字都不用改** —— 它读的是"是不是 NULL",不是别的。
    RETURN NULL;
END;
$function$;

COMMENT ON FUNCTION public.hazardous_qty_on_hand_tonnes() IS
'CMPL-1:在场危废吨数 —— **今天返回 NULL,而 NULL 的意思是【算不出来】,不是【零吨】**。要算它得先说得出"哪些料算危废",而 waste_classifications 线上只有 focused / non_focused 两行、其 is_controlled 列**全库零个消费方**,两者都对不上 NEA 的批准废物类别词汇。把它们硬映射过去是发明不是建模,所以这条推导**排队而不是猜**:触发条件是【分类字典能表达 NEA 的批准废物类别】。★把 NULL 读成 0 的实现会让任何上限检查轻松通过,那正是 R2 点名的"制造出来的信心"★。';

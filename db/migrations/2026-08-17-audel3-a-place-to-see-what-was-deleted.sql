-- AUDEL-3:一个看得见"删掉了什么"的地方
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【地面先量,而它把这一刀从"政策问题"变回了"页面问题"】
--
-- **RLS 根本不过滤已删的行。** 七张带 delete_reason 的表,SELECT 策略逐条读过,
-- 全部只是 has_permission('module.X.view') —— 没有任何一条带 deleted_at IS NULL。
-- 过滤发生在【应用查询】里(`.is('deleted_at', null)`),不在策略里。
-- 所以不需要动任何一条策略,也不需要新的权限码:一个已经能看那个模块的人,
-- 数据库本来就允许他读到那些已删的行,只是今天没有任何一处把它们画出来。
--
-- 【七张表,16 行已删,其中 14 行没有主人】
--   inbound_batches   7 行删除,6 行 deleted_by 为空
--   output_batches    6 行删除,5 行为空
--   processing_runs   3 行删除,3 行全空
--   stocktakes / purchase_orders / sales_orders / quotes  0 行
-- 那 14 行是 AUDEL-1b 之前删的 —— **不回填,也不猜**(FIN-26)。页面把它们印成
-- 一个【具名的状态】(未记录),而不是空白、更不是一个编出来的名字。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【形状取自 operations_now,一个字不改】
-- 每一支自带 permission 列,外层一次性 has_permission(permission) 按【调用者】裁决:
-- **无权的那一类【整类缺席】,而不是显示成零。** 这正是 /margin 那一课:
-- 不要为一张跨模块的页面合成一个新权限码 —— 那会是"谁能看什么"的第二份定义,
-- 与各模块自己的策略必然漂开。
--
-- 【属主权限,不是 invoker】它跨七个模块。invoker 会让 RLS 把读者无权模块的行
-- 【静默丢掉】,而这里行消失的意思会变成"没有东西被删过" —— 一个错的好消息
-- (OPS-14 的 xmodule 那一课)。属主读全量,外层按调用者裁决。
--
-- 【不提供恢复,而这不是遗漏】撤销删除是一个【没有人做过的决定】:一批料注销之后
-- 台账上已经有一条 writeoff、一张加工单回滚之后投入已经还回去了。在这里放一个
-- "恢复"按钮,等于替所有人把那个决定默默做了。所以本视图是只读的,连一个
-- 可写的入口都不给。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE VIEW public.deleted_records AS
 SELECT a.record_kind,
    a.permission,
    a.record_id,
    a.code,
    a.deleted_at,
    a.deleted_by,
    a.delete_reason,
    a.movement_id,
    a.detail
   FROM ( SELECT 'inbound_batch'::text AS record_kind,
            'module.inbound.view'::text AS permission,
            b.id AS record_id, b.code, b.deleted_at, b.deleted_by, b.delete_reason,
            -- 【那条注销流水】—— 删除在台账上的另一半。取最新一条:一个批次
            -- 只会被注销一次,但历史数据里不保证,所以取而不是断言。
            ( SELECT m.id FROM inventory_movements m
               WHERE m.inbound_batch_id = b.id AND m.movement_type = 'writeoff'
               ORDER BY m.occurred_at DESC LIMIT 1) AS movement_id,
            (b.quantity || ' ' || COALESCE(b.unit, ''))::text AS detail
           FROM inbound_batches b WHERE b.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'output_batch'::text,
            'module.output.view'::text,
            b.id, b.code, b.deleted_at, b.deleted_by, b.delete_reason,
            -- 产出批可能是被【回滚】带走的(reversal_void)而不是单独注销的
            ( SELECT m.id FROM inventory_movements m
               WHERE m.output_batch_id = b.id
                 AND m.movement_type IN ('writeoff', 'reversal_void')
               ORDER BY m.occurred_at DESC LIMIT 1),
            (b.quantity || ' ' || COALESCE(b.unit, ''))::text
           FROM output_batches b WHERE b.deleted_at IS NOT NULL
        UNION ALL
         -- 【被回滚的加工单也在这里】加工单的"删除"就是它的冲销
         -- (status='reversed' + deleted_at),理由记在 delete_reason 上。
         SELECT 'processing_run'::text,
            'module.processing.view'::text,
            r.id, r.code, r.deleted_at, r.deleted_by, r.delete_reason,
            NULL::uuid,
            r.status
           FROM processing_runs r WHERE r.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'stocktake'::text, 'module.stocktakes.view'::text,
            s.id, s.code, s.deleted_at, s.deleted_by, s.delete_reason, NULL::uuid, s.status
           FROM stocktakes s WHERE s.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'purchase_order'::text, 'module.purchasing.view'::text,
            p.id, p.code, p.deleted_at, p.deleted_by, p.delete_reason, NULL::uuid, p.status
           FROM purchase_orders p WHERE p.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'sales_order'::text, 'module.sales.view'::text,
            o.id, o.code, o.deleted_at, o.deleted_by, o.delete_reason, NULL::uuid, o.status
           FROM sales_orders o WHERE o.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'quote'::text, 'module.sales.view'::text,
            q.id, q.code, q.deleted_at, q.deleted_by, q.delete_reason, NULL::uuid, q.status
           FROM quotes q WHERE q.deleted_at IS NOT NULL) a
  WHERE has_permission(a.permission);

COMMENT ON VIEW public.deleted_records IS
    'AUDEL-3:全站被软删的记录,一条一行 —— 编号、种类、时刻、谁、为什么,以及台账上那条注销/冲销流水。被回滚的加工单也在这里(它的"删除"就是它的冲销)。【每一行跟着它自己模块的读权限】(permission 列 + 外层 has_permission),无权的那一类整类缺席而不是显示成零 —— 不为跨模块页面合成新权限码(/margin 那一课)。属主权限:invoker 会让 RLS 静默丢行,而行消失在这里意味着"没有东西被删过"。【只读,永不提供恢复】—— 撤销删除是一个没有人做过的决定,一个按钮会替所有人默默做掉它。';

GRANT SELECT ON public.deleted_records TO authenticated;

COMMIT;

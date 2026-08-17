-- db/views/deleted_records.sql
-- AUDEL-3:全站被软删的记录,一条一行 —— 编号、种类、时刻、谁、为什么,
-- 以及台账上那条注销/冲销流水。被回滚的加工单也在这里(它的"删除"就是它的冲销)。
--
-- 【地面:RLS 根本不过滤已删的行】七张带 delete_reason 的表,SELECT 策略全部只是
-- has_permission('module.X.view') —— 没有任何一条带 deleted_at IS NULL。过滤发生在
-- 【应用查询】里。所以这一刀不需要动任何策略、也不需要新权限码。
--
-- 【每一行跟着它自己模块的读权限】permission 列 + 外层 has_permission(调用者)——
-- 无权的那一类【整类缺席】,不是显示成零。这是 /margin 那一课:为跨模块页面合成
-- 一个新权限码,会是"谁能看什么"的第二份定义,与各模块的策略必然漂开。
--
-- 【属主权限,不是 invoker】跨七个模块;invoker 会让 RLS 静默丢行,而行消失在这里
-- 的意思会变成"没有东西被删过"(OPS-14 的 xmodule 那一课)。
--
-- 【只读,永不提供恢复】撤销删除是一个没有人做过的决定 —— 注销流水已经进台账、
-- 回滚的投入已经还回去。一个按钮会替所有人默默把那个决定做掉。
--
-- 【record_kind 的取值就是下面那几个字面量】—— check-i18n 的 deleted.kind. 前缀
-- 现读本文件,加一支就自动被查到。
--
-- NOTE: introduced by db/migrations/2026-08-17-audel3-a-place-to-see-what-was-deleted.sql.

CREATE OR REPLACE VIEW public.deleted_records AS
 SELECT record_kind,
    permission,
    record_id,
    code,
    deleted_at,
    deleted_by,
    delete_reason,
    movement_id,
    detail
   FROM ( SELECT 'inbound_batch'::text AS record_kind,
            'module.inbound.view'::text AS permission,
            b.id AS record_id,
            b.code,
            b.deleted_at,
            b.deleted_by,
            b.delete_reason,
            ( SELECT m.id
                   FROM inventory_movements m
                  WHERE m.inbound_batch_id = b.id AND m.movement_type = 'writeoff'::text
                  ORDER BY m.occurred_at DESC
                 LIMIT 1) AS movement_id,
            (b.quantity || ' '::text) || COALESCE(b.unit, ''::text) AS detail
           FROM inbound_batches b
          WHERE b.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'output_batch'::text AS text,
            'module.output.view'::text AS text,
            b.id,
            b.code,
            b.deleted_at,
            b.deleted_by,
            b.delete_reason,
            ( SELECT m.id
                   FROM inventory_movements m
                  WHERE m.output_batch_id = b.id AND (m.movement_type = ANY (ARRAY['writeoff'::text, 'reversal_void'::text]))
                  ORDER BY m.occurred_at DESC
                 LIMIT 1) AS id,
            (b.quantity || ' '::text) || COALESCE(b.unit, ''::text) AS text
           FROM output_batches b
          WHERE b.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'processing_run'::text AS text,
            'module.processing.view'::text AS text,
            r.id,
            r.code,
            r.deleted_at,
            r.deleted_by,
            r.delete_reason,
            NULL::uuid AS uuid,
            r.status
           FROM processing_runs r
          WHERE r.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'stocktake'::text AS text,
            'module.stocktakes.view'::text AS text,
            s.id,
            s.code,
            s.deleted_at,
            s.deleted_by,
            s.delete_reason,
            NULL::uuid AS uuid,
            s.status
           FROM stocktakes s
          WHERE s.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'purchase_order'::text AS text,
            'module.purchasing.view'::text AS text,
            p.id,
            p.code,
            p.deleted_at,
            p.deleted_by,
            p.delete_reason,
            NULL::uuid AS uuid,
            p.status
           FROM purchase_orders p
          WHERE p.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'sales_order'::text AS text,
            'module.sales.view'::text AS text,
            o.id,
            o.code,
            o.deleted_at,
            o.deleted_by,
            o.delete_reason,
            NULL::uuid AS uuid,
            o.status
           FROM sales_orders o
          WHERE o.deleted_at IS NOT NULL
        UNION ALL
         SELECT 'quote'::text AS text,
            'module.sales.view'::text AS text,
            q.id,
            q.code,
            q.deleted_at,
            q.deleted_by,
            q.delete_reason,
            NULL::uuid AS uuid,
            q.status
           FROM quotes q
          WHERE q.deleted_at IS NOT NULL) a
  WHERE has_permission(permission);

COMMENT ON VIEW public.deleted_records IS
    'AUDEL-3:全站被软删的记录,一条一行 —— 编号、种类、时刻、谁、为什么,以及台账上那条注销/冲销流水。被回滚的加工单也在这里(它的"删除"就是它的冲销)。【每一行跟着它自己模块的读权限】(permission 列 + 外层 has_permission),无权的那一类整类缺席而不是显示成零 —— 不为跨模块页面合成新权限码(/margin 那一课)。属主权限:invoker 会让 RLS 静默丢行,而行消失在这里意味着"没有东西被删过"。【只读,永不提供恢复】—— 撤销删除是一个没有人做过的决定,一个按钮会替所有人默默做掉它。';

GRANT SELECT ON public.deleted_records TO authenticated;

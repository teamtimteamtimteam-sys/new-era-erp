-- db/functions/supplier_status_moves.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §6,Batch 2 grilling Q8):供应商状态机 —— 【哪一步合法、要哪一个码】的唯一定义。
--
-- 【三个读者,一份定义】
--   · validate_supplier_status_transition(触发器):一步不在这张表里 → INVALID_STATUS_TRANSITION;
--   · set_supplier_status:这一步要哪个码 → require_permission;
--   · /suppliers/[id]/edit 的状态面板:画哪些钮、哪一个钮要什么码(禁用时说出那个码)。
-- 此前合法跳转写在触发器体里、页面上另抄一份(statusMachine.ts)—— 两份迟早各说各话。
--
-- 【Tim 的 Q8,原样】
--   CFO(action.supplier_approve):→ approved、→ rejected(都只能从 pending_review 来)、
--       任何 → blacklisted、blacklisted → archived(「恢复」:拉黑之后回头的唯一一步)。
--   module.suppliers.edit:其余每一步 —— 送审、撤回送审、启用、暂停、重新启用、归档、归档后回草稿。
-- 跳转图本身【一步没改】(与 ROLE-1 之前触发器体里那一份逐条相同);改的只是每一步归谁。
--
-- 【返回 text,不返回 supplier_status】镜像函数的签名只许内置类型(AGENTS.md):重建时
-- db/functions 先于 db/tables 重放,那时枚举还不存在。比较的一方各自 ::text。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.supplier_status_moves()
 RETURNS TABLE(from_status text, to_status text, required_code text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT f, t, c
      FROM (VALUES
        ('draft',          'pending_review', 'module.suppliers.edit'),
        ('draft',          'archived',       'module.suppliers.edit'),
        ('pending_review', 'approved',       'action.supplier_approve'),
        ('pending_review', 'rejected',       'action.supplier_approve'),
        ('pending_review', 'draft',          'module.suppliers.edit'),
        ('rejected',       'draft',          'module.suppliers.edit'),
        ('rejected',       'archived',       'module.suppliers.edit'),
        ('approved',       'active',         'module.suppliers.edit'),
        ('approved',       'suspended',      'module.suppliers.edit'),
        ('approved',       'archived',       'module.suppliers.edit'),
        ('active',         'suspended',      'module.suppliers.edit'),
        ('active',         'blacklisted',    'action.supplier_approve'),
        ('active',         'archived',       'module.suppliers.edit'),
        ('suspended',      'active',         'module.suppliers.edit'),
        ('suspended',      'blacklisted',    'action.supplier_approve'),
        ('suspended',      'archived',       'module.suppliers.edit'),
        ('blacklisted',    'archived',       'action.supplier_approve'),
        ('archived',       'draft',          'module.suppliers.edit')
      ) m(f, t, c)
$function$;

COMMENT ON FUNCTION public.supplier_status_moves() IS
'ROLE-1 Batch 2a:供应商状态机的唯一定义 —— 每一步合法跳转与它要的码。触发器、set_supplier_status 与状态面板三处都读它。CFO(action.supplier_approve)管 → approved / → rejected / → blacklisted / blacklisted → archived;其余归 module.suppliers.edit(Tim,Q8)。';

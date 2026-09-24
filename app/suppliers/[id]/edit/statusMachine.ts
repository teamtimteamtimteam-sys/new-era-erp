import type { Database } from '@/lib/database.types'

type SupplierStatus = Database['public']['Enums']['supplier_status']

// 状态机定义(纯数据,无副作用,可以在 Server 和 Client 都用)
// 显示文案已移到 i18n 消息目录(suppliers.status.* / suppliers.statusAction.*)

// 8 个规范状态值(顺序与 DB enum supplier_status 一致)。
// 用于状态筛选下拉:value 用规范值,label 用 t('suppliers.status.'+value)。
export const SUPPLIER_STATUSES: SupplierStatus[] = [
    'draft',
    'pending_review',
    'approved',
    'rejected',
    'active',
    'suspended',
    'blacklisted',
    'archived',
]

// ★ ROLE-1 Batch 2a:合法状态流转表【不再住在这里】。它此前是数据库触发器体里那一份的
//   手抄本("必须跟数据库 trigger 一致" —— 一句要人记着的话)。现在唯一的定义是
//   supplier_status_moves()(库里),状态面板由页面向它要【这一家此刻能走哪几步、每一步要哪个码】。

// 需要二次确认的"重要"流转
export const DESTRUCTIVE_TRANSITIONS = new Set<SupplierStatus>([
    'blacklisted',
    'archived',
    'rejected',
])

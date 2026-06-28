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

// 合法状态流转表(必须跟数据库 trigger 一致)
export const ALLOWED_TRANSITIONS: Record<SupplierStatus, SupplierStatus[]> = {
    draft: ['pending_review', 'archived'],
    pending_review: ['approved', 'rejected', 'draft'],
    rejected: ['draft', 'archived'],
    approved: ['active', 'suspended', 'archived'],
    active: ['suspended', 'blacklisted', 'archived'],
    suspended: ['active', 'blacklisted', 'archived'],
    blacklisted: ['archived'],
    archived: ['draft'],
}

// 需要二次确认的"重要"流转
export const DESTRUCTIVE_TRANSITIONS = new Set<SupplierStatus>([
    'blacklisted',
    'archived',
    'rejected',
])

// app/components/inventory/movementTypes.ts
// 库存流水时间线的共享类型。普通模块(无 'use server'/'use client')。
// occurred_at 在服务端按当前语言预格式化成 occurred_at_display,避免客户端水合不一致。
export type MovementRow = {
    id: string
    movement_type: string
    qty_delta: number
    business_date: string | null
    notes: string | null
    occurred_at_display: string
    run: { id: string; code: string } | null
}

// 与 DB 的 movement_type CHECK 集合一致(8 类)。
export const MOVEMENT_TYPE_VALUES = [
    'receipt',
    'processing_consume',
    'processing_produce',
    'reversal_restore',
    'reversal_void',
    'sale',
    'writeoff',
    'adjustment',
] as const

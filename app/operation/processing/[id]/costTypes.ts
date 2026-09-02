// app/operation/processing/[id]/costTypes.ts
// 加工成本条目的共享选项 + 行类型。value = 存入数据库的规范值(与 DB CHECK 集合一致)。
export type CostTypeOption = { value: string; labelKey: string }

export const COST_TYPE_OPTIONS: CostTypeOption[] = [
    { value: 'labour', labelKey: 'processing.costTypes.labour' },
    { value: 'electricity', labelKey: 'processing.costTypes.electricity' },
    { value: 'gas', labelKey: 'processing.costTypes.gas' },
    { value: 'depreciation', labelKey: 'processing.costTypes.depreciation' },
    { value: 'consumables', labelKey: 'processing.costTypes.consumables' },
    { value: 'waste_treatment', labelKey: 'processing.costTypes.waste_treatment' },
    { value: 'other', labelKey: 'processing.costTypes.other' },
]

export const COST_TYPE_VALUES: readonly string[] = COST_TYPE_OPTIONS.map((o) => o.value)

export function costTypeLabelKey(value: string | null | undefined): string | null {
    if (!value) return null
    return COST_TYPE_OPTIONS.find((o) => o.value === value)?.labelKey ?? null
}

// created_at 在服务端按当前语言预格式化成 created_at_display(避免客户端水合不一致)。
export type CostEntryRow = {
    id: string
    cost_type: string
    // cut 2b:没有 data.view_prices 时,遮蔽视图把金额返回 null。
    // 【保持可空】—— 界面据此显示「受限」,而不是空白(像缺数据)或 0(是撒谎)。
    amount_base: number | null
    is_estimate: boolean
    notes: string | null
    created_at_display: string
    // FIN-8:改过就要看得见。原本只显示创建日期,于是一条 100 改成 200 的条目
    // 看上去和从来就是 200 一模一样 —— 数据里其实一直有 updated_at/updated_by。
    edited_at_display: string | null
    edited_by_name: string | null
}

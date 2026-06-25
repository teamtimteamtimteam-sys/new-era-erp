// app/materials/options.ts
// 物料模块共享的下拉选项
// value = 写入数据库的规范值(保持不变);labelKey = i18n 显示文案的键

export type MaterialSelectOption = { value: string; labelKey: string }

export const CATEGORY_OPTIONS: MaterialSelectOption[] = [
    { value: '进料-电池', labelKey: 'materials.category.inboundBattery' },
    { value: '进料-黑粉', labelKey: 'materials.category.inboundBlackMass' },
    { value: '产出-黑粉', labelKey: 'materials.category.outputBlackMass' },
    { value: '产出-金属', labelKey: 'materials.category.outputMetal' },
    { value: '产出-其他', labelKey: 'materials.category.outputOther' },
    { value: '耗材辅料', labelKey: 'materials.category.consumable' },
    { value: '其他', labelKey: 'materials.category.other' },
]

export const CHEMISTRY_OPTIONS: MaterialSelectOption[] = [
    { value: 'NMC', labelKey: 'materials.chemistry.nmc' },
    { value: 'NCA', labelKey: 'materials.chemistry.nca' },
    { value: 'LFP', labelKey: 'materials.chemistry.lfp' },
    { value: 'LCO', labelKey: 'materials.chemistry.lco' },
    { value: 'LMO', labelKey: 'materials.chemistry.lmo' },
    { value: 'LTO', labelKey: 'materials.chemistry.lto' },
    { value: '钠离子', labelKey: 'materials.chemistry.sodiumIon' },
    { value: '混合', labelKey: 'materials.chemistry.mixed' },
    { value: '不适用', labelKey: 'materials.chemistry.na' },
    { value: '其他', labelKey: 'materials.chemistry.other' },
]

export const UNIT_OPTIONS: MaterialSelectOption[] = [
    { value: 'kg', labelKey: 'materials.unit.kg' },
    { value: '吨', labelKey: 'materials.unit.ton' },
    { value: '克', labelKey: 'materials.unit.gram' },
    { value: '件', labelKey: 'materials.unit.piece' },
]

// 选中此值时,显示自由文本输入框。既是存储值,也是 CustomSelect 的 sentinel —— 不要改。
export const CUSTOM_VALUE = '其他'

// value → labelKey 反查;找不到(自定义自由文本)返回 null
export function labelKeyForValue(
    options: MaterialSelectOption[],
    value: string | null | undefined
): string | null {
    if (!value) return null
    return options.find((o) => o.value === value)?.labelKey ?? null
}

// app/materials/options.ts
// 物料模块共享的下拉选项
// value = 写入数据库的规范值(保持不变);labelKey = i18n 显示文案的键

export type MaterialSelectOption = { value: string; labelKey: string }

// 【PROC-1:CATEGORY_OPTIONS 已移除 —— 它是这套系统的【第三份命名权威】】
// 它按【方向】切在最前面(进料- / 产出-),而方向不是物料的属性:
// MAT-2026-0001 标着「进料-电池」却有 10 个产出批。
// 它还把黑粉切成两个值(进料-黑粉 / 产出-黑粉)—— 那会给同一种东西两个
// material_id,库存合计与批次血缘就地裂开。而它自带一个「其他」逃生门。
// 取而代之的是 material_kinds 那张【带外键的字典】(见 materialKindQuery.ts)。
// 【本文件其余部分留着】CHEMISTRY_OPTIONS 是 G18 的地盘,UNIT_OPTIONS 无关 ——
// brief 说"移除 options.ts",而那会顺手杀掉两件本刀不管的东西。

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
    { value: 'kg', labelKey: 'units.kg' },
    { value: '吨', labelKey: 'units.ton' },
    { value: '克', labelKey: 'units.gram' },
    { value: '件', labelKey: 'units.piece' },
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

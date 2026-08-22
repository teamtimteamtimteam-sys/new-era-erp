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

// 【PROC-5:CHEMISTRY_OPTIONS 与 CUSTOM_VALUE 已移除 —— 它是【第五份命名权威】】
// 它同时定着哪些值合法、怎么排、叫什么;而且**自带一个逃生门**:
// `其他` 是一个 sentinel,选中它会打开自由文本框。那个门已经被走过了 ——
// 线上 MAT-2026-0002 的 chemistry 是「Special Chemistry Structure」,
// 不在这份清单里,读起来像占位符。materials.category 长出四种命名法走的就是这条路。
// 取而代之的是 battery_chemistries 那张带外键的字典
// (见 app/components/dictionaries/dictionaryQuery.ts)。
// 【本文件其余部分留着】UNIT_OPTIONS 与 labelKeyForValue 与本刀无关,
// 而后者还被 inbound / output / inventory 几处共用。

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

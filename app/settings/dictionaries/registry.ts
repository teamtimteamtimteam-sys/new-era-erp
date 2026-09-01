// DICT-ADMIN:五张字典的【声明】—— 一个通用屏幕 + 按字典的小节(Tim 的裁定)。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么是"通用 + 小节",而不是五份表单或者一个全自动屏幕 —— 证据在这里】
// 实测五张字典【共用六列】:code / name_en / name_zh / is_active / sort_order / notes。
// 额外的列只有四个,集中在三张表上:
//     substances            + symbol                 (可空文本,无关痛痒)
//     inbound_safety_states + may_be_fed             (规则布尔)
//     material_kinds        + may_ever_be_processed  (规则布尔)
//                           + has_condition_axes     (规则布尔)
// 也就是说 **2/5 压根不需要特例**,第三个只是一个可空文本 ——
// 真正要特例的只有两张表上的三个布尔。五份表单会把那六个字段连同它们的校验、
// 拒绝、排序逻辑抄五遍;而一个【全自动】屏幕会把 may_be_fed 画成一个叫
// "may be fed" 的裸勾选框 —— **而它拦的是起火**。
// 所以:共用的写一遍,额外的由这张表【逐个声明,连同那一句解释】。
//
// 【加一张新字典要做什么】在这里加一条 —— 而不是加一个页面。
// ════════════════════════════════════════════════════════════════════════════

import type { Database } from '@/lib/database.types'

/** 库里真实存在的表名 —— **从生成的类型里取,不在这里抄第二份清单**。
 *  写错一个表名会在编译期红,而不是在运行期变成一次静默的空查询。 */
export type TableName = keyof Database['public']['Tables']

/** 这五张字典本身。**窄到这五个**,而不是"任何表" ——
 *  它们共用 code / name_en / name_zh / is_active / sort_order / notes 六列,
 *  编译器据此知道 .select('code') 是成立的;写成全表联合就什么都推不出来了。 */
export type DictTable =
    | 'substances' | 'battery_chemistries' | 'material_kinds'
    | 'inbound_safety_states' | 'laboratories' | 'inbound_source_reasons'

/** 额外字段的声明。boolean 的 hint 是【必填的】—— 一个没有句子的规则开关比没有开关更坏。 */
export type ExtraField = {
    column: string
    kind: 'boolean' | 'text'
    labelKey: string
    /** 这个开关到底管什么 —— 画在勾选框旁边,不是 tooltip。 */
    hintKey: string
    /** boolean 且没有数据库默认值时必须显式选,不能靠"没勾就是 false"。 */
    required?: boolean
}

export type DictSpec = {
    table: DictTable
    titleKey: string
    /** 数据库上真正把门的那个权限码 —— 不新造(/margin 那一课)。 */
    permission: string
    extras: ExtraField[]
    /** 指着它的表:用来数"有多少行在用这个值"(D4)。取自 pg_constraint 实测。 */
    referencedBy: { table: TableName; column: string }[]
}

export const DICTIONARIES: DictSpec[] = [
    {
        table: 'substances',
        titleKey: 'dict.substances',
        permission: 'module.materials.edit',
        extras: [{ column: 'symbol', kind: 'text', labelKey: 'dict.f.symbol', hintKey: 'dict.h.symbol' }],
        referencedBy: [
            { table: 'assay_result_metals', column: 'metal' },
            { table: 'inbound_batch_metals', column: 'metal' },
            { table: 'material_required_metals', column: 'metal' },
            { table: 'metal_prices', column: 'metal' },
            { table: 'output_batch_metals', column: 'metal' },
            { table: 'pricing_formula_history', column: 'metal' },
            { table: 'pricing_formula_metals', column: 'metal' },
            { table: 'pricing_term_commitment_metals', column: 'metal' },
        ],
    },
    {
        table: 'battery_chemistries',
        titleKey: 'dict.battery_chemistries',
        permission: 'module.materials.edit',
        extras: [],
        referencedBy: [{ table: 'materials', column: 'chemistry' }],
    },
    {
        table: 'material_kinds',
        titleKey: 'dict.material_kinds',
        permission: 'module.materials.edit',
        extras: [
            { column: 'may_ever_be_processed', kind: 'boolean', required: true,
              labelKey: 'dict.f.may_ever_be_processed', hintKey: 'dict.h.may_ever_be_processed' },
            { column: 'has_condition_axes', kind: 'boolean', required: true,
              labelKey: 'dict.f.has_condition_axes', hintKey: 'dict.h.has_condition_axes' },
        ],
        referencedBy: [{ table: 'materials', column: 'kind_code' }],
    },
    {
        table: 'inbound_safety_states',
        titleKey: 'dict.inbound_safety_states',
        permission: 'module.materials.edit',
        extras: [
            { column: 'may_be_fed', kind: 'boolean', required: true,
              labelKey: 'dict.f.may_be_fed', hintKey: 'dict.h.may_be_fed' },
        ],
        referencedBy: [{ table: 'inbound_batch_safety_states', column: 'safety_state_code' }],
    },
    {
        // 【它的权限与另外四张【不一样】】实测:laboratories 由 module.inbound.edit
        // 把门,其余四张是 module.materials.edit。所以这个屏幕【逐小节判权限】——
        // 一个只有进料权限的人看得见实验室那一节、看不见另外四节,反之亦然。
        table: 'laboratories',
        titleKey: 'dict.laboratories',
        permission: 'module.inbound.edit',
        extras: [],
        referencedBy: [{ table: 'assay_results', column: 'lab_name' }],
    },
    {
        // RECV-SOURCE-1(R2):无单收货的理由 —— 第五个理由必须是【这里的一行】,
        // 不是一次改码。material_sources / loss_categories 当年没有登进本表,
        // 那是那两刀的缺口,不是先例(docs/receipt-source.md 记着这一句)。
        table: 'inbound_source_reasons',
        titleKey: 'dict.inbound_source_reasons',
        permission: 'module.inbound.edit',
        extras: [
            { column: 'requires_explanation', kind: 'boolean', required: true,
              labelKey: 'dict.f.requires_explanation', hintKey: 'dict.h.requires_explanation' },
        ],
        referencedBy: [{ table: 'inbound_batches', column: 'source_reason_code' }],
    },
]

/** 屏幕上用到的全部权限码(去重)—— 导航那一项据此决定显不显示。 */
export const DICT_PERMISSIONS = [...new Set(DICTIONARIES.map((d) => d.permission))]

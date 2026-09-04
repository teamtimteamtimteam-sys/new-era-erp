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
    /** ★【写】这张字典要哪个码 —— 数据库上真正把门的那一个,不新造(/margin 那一课)。
     *
     *  ⚠★【C-1b:这一行是【界面的门】,数据库那一侧的真相在别处】★
     *    真正拦住写入的是这张表自己的 RLS 谓词(`<table> insert/update by permission`)。
     *    两者【必须写同一个码】,而**本仓库没有任何机器在检查它们一致** ——
     *    check-permission-predicate 回答的是另外三个问题(求值一处 / 一功能多模块 /
     *    进不去要说出来),它对这条一致性无话可说。
     *    ★ C-1b 把下面两张表的这一行从 inbound.edit 改成 materials.edit 时,
     *      是【连同那四条 RLS 策略一起改的】(见那支迁移)。
     *      只改这里会得到【一张藏起来的表单 + 一个敞开的写入】—— 比不改更坏,
     *      因为矩阵会被后来的人当成真的。 */
    permission: string
    /** ★【读】这张字典要哪个码。C-1b 加的那一半。
     *
     *  【为什么读与写可以是两个不同的码,而这不是投机取巧】
     *    实验室名录与无单收货理由服务的是【进料】那条业务:现场的人必须【看得见】
     *    有哪些实验室、有哪些理由,否则他填不了单;而决定"名录里该有谁"是物料
     *    主数据的事。所以那两张 view = inbound.view、edit = materials.edit ——
     *    这正是 Tim 对 Fu Sheng 的裁定(那两节对他只读),而它【一个新码都不需要】。
     *
     *  【它不会撒谎】六张字典的 SELECT 策略都是 `USING (true)`,任何登录用户本来
     *    就读得到。把一节渲染成只读,与数据库允许的事情【完全一致】。 */
    viewPermission: string
    extras: ExtraField[]
    /** 指着它的表:用来数"有多少行在用这个值"(D4)。取自 pg_constraint 实测。 */
    referencedBy: { table: TableName; column: string }[]
}

export const DICTIONARIES: DictSpec[] = [
    {
        table: 'substances',
        titleKey: 'dict.substances',
        permission: 'module.materials.edit',
        viewPermission: 'module.materials.view',
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
        viewPermission: 'module.materials.view',
        extras: [],
        referencedBy: [{ table: 'materials', column: 'chemistry' }],
    },
    {
        table: 'material_kinds',
        titleKey: 'dict.material_kinds',
        permission: 'module.materials.edit',
        viewPermission: 'module.materials.view',
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
        viewPermission: 'module.materials.view',
        extras: [
            { column: 'may_be_fed', kind: 'boolean', required: true,
              labelKey: 'dict.f.may_be_fed', hintKey: 'dict.h.may_be_fed' },
        ],
        referencedBy: [{ table: 'inbound_batch_safety_states', column: 'safety_state_code' }],
    },
    {
        // ★★【C-1b(2026-09-04):这一节的【写】从 inbound.edit 抬到了 materials.edit】★★
        // 【为什么】warehouse 持 module.inbound.edit(现场收货要用),于是在此之前
        //   一个仓储现场负责人【建得了实验室、也改得动来源理由的规则】。那不是他的活。
        // 【为什么不是收回 inbound.edit】那会把现场收货一起弄坏 —— Tim 点名不许。
        // 【所以改的是这一节要哪个码】写要 materials.edit(他没有),
        //   读要 inbound.view(他有)—— 于是这一节对他【只读】,而不是消失。
        // ★ 连同改的还有【四条 RLS 策略】(laboratories / inbound_source_reasons 的
        //   insert 与 update),否则表单藏起来了而写入照样进得去。
        table: 'laboratories',
        titleKey: 'dict.laboratories',
        permission: 'module.materials.edit',
        viewPermission: 'module.inbound.view',
        extras: [],
        referencedBy: [{ table: 'assay_results', column: 'lab_name' }],
    },
    {
        // RECV-SOURCE-1(R2):无单收货的理由 —— 第五个理由必须是【这里的一行】,
        // 不是一次改码。material_sources / loss_categories 当年没有登进本表,
        // 那是那两刀的缺口,不是先例(docs/receipt-source.md 记着这一句)。
        // ★ C-1b:与 laboratories 同一次改动 —— 写要 materials.edit,读要 inbound.view。
        //   requires_explanation 是一条【规则】开关,不该由现场的人翻。
        table: 'inbound_source_reasons',
        titleKey: 'dict.inbound_source_reasons',
        permission: 'module.materials.edit',
        viewPermission: 'module.inbound.view',
        extras: [
            { column: 'requires_explanation', kind: 'boolean', required: true,
              labelKey: 'dict.f.requires_explanation', hintKey: 'dict.h.requires_explanation' },
        ],
        referencedBy: [{ table: 'inbound_batches', column: 'source_reason_code' }],
    },
]

/** 【写】这块屏用到的全部编辑码(去重)。 */
export const DICT_PERMISSIONS = [...new Set(DICTIONARIES.map((d) => d.permission))]

/** ★【读】这块屏用到的全部查看码(去重)—— **导航那一项据此决定显不显示**。
 *
 *  【C-1b 为什么把导航的判据从"编辑码"换成"查看码"】这一页从此对
 *  【只读得到、改不动】的人也是有意义的(那正是 Fu Sheng 在实验室那两节的处境)。
 *  判据若还停在编辑码上,导航会把入口藏起来,而页面其实让他进 ——
 *  「谁看得见入口」与「谁进得去」各错一次,正是 NAV-REG-1 的 3d 要消灭的形状。
 *  ★ lib/modules.ts 的 P_DICTIONARIES 必须与本行【同一组码】(那里是手抄的第二份)。 */
export const DICT_VIEW_PERMISSIONS = [...new Set(DICTIONARIES.map((d) => d.viewPermission))]

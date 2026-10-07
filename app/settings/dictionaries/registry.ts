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

/** 这六张字典本身(AUDIT-TRAIL-1d-1:这里以前写着"五张",而联合类型里一直是六张 —— AT-0 量过,Step 0 Q38 照改)。
 *  **窄到这六个**,而不是"任何表" ——
 *  它们共用 code / name_en / name_zh / is_active / sort_order / notes 六列,
 *  编译器据此知道 .select('code') 是成立的;写成全表联合就什么都推不出来了。 */
export type DictTable =
    | 'substances' | 'battery_chemistries' | 'material_kinds'
    | 'inbound_safety_states' | 'laboratories' | 'inbound_source_reasons'
    | 'nea_waste_categories'   // MES-3a(2026-10-06,V29):第七张 —— 同样只有那六列
    | 'dangerous_goods_codes' | 'label_templates'   // MES-3b(2026-10-07,V30 · Q5):第八、九张 —— 同样有那六列
    | 'shifts' | 'processing_event_types'   // MES-4a(2026-10-07,Q5 · Q15):第十、十一张 —— 同样有那六列
    | 'cell_constructions' | 'contamination_streams'   // MES-4b(2026-10-07,Q3 · Q21):第十二、十三张 —— 同样有那六列

/** 额外字段的声明。boolean 的 hint 是【必填的】—— 一个没有句子的规则开关比没有开关更坏。 */
export type ExtraField = {
    column: string
    /** MES-3a 加了 number(滞留提醒天数):空 = NULL = "Not yet set",不是 0。
     *  MES-3b 加了 choice(标签模板的"给哪一种东西 / 纸多大"):只能在 options 里挑 —— 表上的 CHECK 是同一张清单,
     *  这里只是不让人去敲一个必然被拒的字。 */
    kind: 'boolean' | 'text' | 'number' | 'choice' | 'time'
    /** kind = choice 时的取值,每一个带一个字面量的文案键(check-i18n 按字面量核对)。 */
    options?: { value: string; labelKey: string }[]
    labelKey: string
    /** 这个开关到底管什么 —— 画在勾选框旁边,不是 tooltip。 */
    hintKey: string
    /** boolean 且没有数据库默认值时必须显式选,不能靠"没勾就是 false"。
     *  不必填的 boolean(MES-3a 的 requires_quarantine)有第三个值:空 = NULL = "Not yet set"。 */
    required?: boolean
    /** MES-3a:这一列也画在清单里(规则列 —— 停用前、改之前就该看得见它现在是什么)。 */
    showInTable?: boolean
    /** MES-4a(Q5):kind = time 的那一对(班次的开始 / 结束)—— 要么都给、要么都空(表上的 shifts_hours_paired 是同一句话)。
     *  只有一头的班次说不出它覆盖哪一段,于是在这里按名拒,不让人撞上一串约束名。 */
    pairedWith?: string
    /** MES-4b(V11):kind = number 时可以是 0 与小数(一个百分数),不是 MES-3a 那种从 1 起的天数。 */
    decimal?: boolean
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
            // ★ MES-3a(2026-10-06,MES-0 Q35 · Q34;MES-3a Step 0 Q14 · Q18,Tim):滞留提醒天数(V3)与要不要隔离(V4)。
            //   两列都可以是空的 —— 空的意思是"还没有人给",在 /settings/pending-values 上列着;没有一个数是编出来的。
            { column: 'dwell_warning_days', kind: 'number', showInTable: true,
              labelKey: 'dict.f.dwell_warning_days', hintKey: 'dict.h.dwell_warning_days' },
            { column: 'requires_quarantine', kind: 'boolean', showInTable: true,
              labelKey: 'dict.f.requires_quarantine', hintKey: 'dict.h.requires_quarantine' },
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
    {
        // ★ MES-3a(2026-10-06,MES-0 Q32 · V29;MES-3a Step 0 Q4 · Q12,Tim):NEA 批准的废物类别 —— 库存上限按"执照 × 类别"判。
        //   【从空开始】类别的代号与名字由 NEA 执照给,不是这里编的;一个都没有时 /settings/pending-values 上有一行 V29。
        //   写与其余几本同一个码(module.materials.edit,与那张表的写策略同一个);读的门更宽(执照、库存、进料、产出也要读)。
        table: 'nea_waste_categories',
        titleKey: 'dict.nea_waste_categories',
        permission: 'module.materials.edit',
        viewPermission: 'module.materials.view',
        extras: [],
        referencedBy: [
            { table: 'materials', column: 'nea_waste_category_code' },
            { table: 'licence_storage_limits', column: 'category_code' },
        ],
    },
    {
        // ★ MES-3b(2026-10-07,MES-0 Q38 · V30;MES-3b Step 0 Q11,Tim):危险品 UN 编号 —— 引导四行(UN3480 · UN3481 · UN3090 · UN3091,第 9 类)。
        //   包装标记文字、包装说明、标签尺寸三列【从空开始】:由有 DG 资质的货代在第一次出口之前给(V30);清单里空的写 Not yet set。
        //   写码与那张表的写策略同一个(module.materials.edit);读的门更宽(库存、进料、产出、物流、销售也要读)。
        table: 'dangerous_goods_codes',
        titleKey: 'dict.dangerous_goods_codes',
        permission: 'module.materials.edit',
        viewPermission: 'module.materials.view',
        extras: [
            { column: 'dg_class', kind: 'text', required: true, showInTable: true,
              labelKey: 'dict.f.dg_class', hintKey: 'dict.h.dg_class' },
            { column: 'marking_text', kind: 'text', showInTable: true,
              labelKey: 'dict.f.marking_text', hintKey: 'dict.h.marking_text' },
            { column: 'packing_instruction', kind: 'text', showInTable: true,
              labelKey: 'dict.f.packing_instruction', hintKey: 'dict.h.packing_instruction' },
            { column: 'label_size', kind: 'text', showInTable: true,
              labelKey: 'dict.f.label_size', hintKey: 'dict.h.label_size' },
        ],
        referencedBy: [{ table: 'materials', column: 'dg_code' }],
    },
    {
        // ★ MES-3b(2026-10-07,MES-0 Q40;MES-3b Step 0 Q5,Tim):标签模板 —— 固定形状里选:给哪一种东西、A6 还是 A5、印不印危险品那一行。
        //   引导六行(三种东西 × A6 / A5)。版式只有一份(labelHtml.ts),模板永远塞不进一段标记。
        //   写码与那张表的写策略同一个(module.inventory.edit —— 标签是仓库的事);读要库存查看码。
        table: 'label_templates',
        titleKey: 'dict.label_templates',
        permission: 'module.inventory.edit',
        viewPermission: 'module.inventory.view',
        extras: [
            { column: 'object_kind', kind: 'choice', required: true, showInTable: true,
              labelKey: 'dict.f.object_kind', hintKey: 'dict.h.object_kind',
              options: [
                  { value: 'inbound_batch', labelKey: 'dict.o.inbound_batch' },
                  { value: 'output_batch', labelKey: 'dict.o.output_batch' },
                  { value: 'storage_location', labelKey: 'dict.o.storage_location' },
              ] },
            { column: 'page_size', kind: 'choice', required: true, showInTable: true,
              labelKey: 'dict.f.page_size', hintKey: 'dict.h.page_size',
              options: [
                  { value: 'A6', labelKey: 'dict.o.A6' },
                  { value: 'A5', labelKey: 'dict.o.A5' },
              ] },
            { column: 'show_dg', kind: 'boolean', required: true, showInTable: true,
              labelKey: 'dict.f.show_dg', hintKey: 'dict.h.show_dg' },
        ],
        referencedBy: [{ table: 'label_prints', column: 'template_code' }],
    },
    {
        // ★ MES-4a(2026-10-07,MES-4a Step 0 Q5 · V6,Tim):班次 —— 从此在这里编辑(V6 的链接搬到这里)。
        //   开始 / 结束两个时刻【可以空】:空的意思是"还没有人说过几点到几点"(V6),不是 00:00。要么都给、要么都空。
        //   一炉从 MES-4a 起必须说出它是哪一个班(processing_runs.shift_code);交接班也指着它。
        //   写码与那张表的写策略同一个(module.processing.edit);读要加工查看码。
        table: 'shifts',
        titleKey: 'dict.shifts',
        permission: 'module.processing.edit',
        viewPermission: 'module.processing.view',
        extras: [
            { column: 'starts_at', kind: 'time', showInTable: true, pairedWith: 'ends_at',
              labelKey: 'dict.f.starts_at', hintKey: 'dict.h.starts_at' },
            { column: 'ends_at', kind: 'time', showInTable: true, pairedWith: 'starts_at',
              labelKey: 'dict.f.ends_at', hintKey: 'dict.h.ends_at' },
        ],
        referencedBy: [
            { table: 'processing_runs', column: 'shift_code' },
            { table: 'shift_handovers', column: 'shift_code' },
        ],
    },
    {
        // ★ MES-4a(2026-10-07,MES-4a Step 0 Q15,Tim):一炉里异常事件的种类 —— 引导三行(非计划停机 · 设备报警 · 安全报警),没有"其它"。
        //   一件说不出是哪一种的异常没有审计价值;要一种新的,在这里加一行。表上的 CHECK 拒 code = other。
        table: 'processing_event_types',
        titleKey: 'dict.processing_event_types',
        permission: 'module.processing.edit',
        viewPermission: 'module.processing.view',
        extras: [],
        referencedBy: [{ table: 'processing_run_events', column: 'event_type_code' }],
    },
    {
        // ★ MES-4b(2026-10-07,MES-0 Q45;MES-4b Step 0 Q3,Tim):电芯结构 —— 引导三行(卷绕 · 叠片 · 未知)。
        //   "确定的结构"是一条规则开关:只有它为真的值过得了极片分离与自动极片线的投料闸(INPUT_CELL_CONSTRUCTION_REQUIRED)。
        //   写码与那张表的写策略同一个(module.processing.edit —— 路由是加工的事实);读要加工查看码。
        table: 'cell_constructions',
        titleKey: 'dict.cell_constructions',
        permission: 'module.processing.edit',
        viewPermission: 'module.processing.view',
        extras: [
            { column: 'is_determined', kind: 'boolean', required: true, showInTable: true,
              labelKey: 'dict.f.is_determined', hintKey: 'dict.h.is_determined' },
        ],
        referencedBy: [
            { table: 'inbound_batches', column: 'cell_construction_code' },
            { table: 'output_batches', column: 'cell_construction_code' },
        ],
    },
    {
        // ★ MES-4b(2026-10-07,MES-0 Q52 · V11;MES-4b Step 0 Q21,Tim):交叉污染抽检的流 —— 引导两行(正极 · 负极)。
        //   警戒线(V11)【从空开始】:由 Tim / 第一份黑粉承购合同的规格给;空的时候一次抽检判不了超没超,不是"在范围内"。
        //   抽哪一种极片、找哪一种外来物只在两种极片里挑(表上的外键 + "两者不同"那一句)。写码 module.processing.edit;读要加工查看码。
        table: 'contamination_streams',
        titleKey: 'dict.contamination_streams',
        permission: 'module.processing.edit',
        viewPermission: 'module.processing.view',
        extras: [
            { column: 'sheet_form_code', kind: 'choice', required: true, showInTable: true,
              labelKey: 'dict.f.sheet_form_code', hintKey: 'dict.h.sheet_form_code',
              options: [
                  { value: 'cathode_sheet', labelKey: 'dict.o.cathode_sheet' },
                  { value: 'anode_sheet', labelKey: 'dict.o.anode_sheet' },
              ] },
            { column: 'foreign_form_code', kind: 'choice', required: true, showInTable: true,
              labelKey: 'dict.f.foreign_form_code', hintKey: 'dict.h.foreign_form_code',
              options: [
                  { value: 'anode_sheet', labelKey: 'dict.o.anode_sheet' },
                  { value: 'cathode_sheet', labelKey: 'dict.o.cathode_sheet' },
              ] },
            { column: 'warning_pct', kind: 'number', decimal: true, showInTable: true,
              labelKey: 'dict.f.warning_pct', hintKey: 'dict.h.warning_pct' },
        ],
        referencedBy: [{ table: 'contamination_checks', column: 'stream_code' }],
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

// lib/chains.ts
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-3 · 四条单据链 —— 步骤的【顺序】与【名字】只写在这里(Tim 2026-10-26 裁定 2.4 (12);2026-10-27 SYSTEM-MAP-3)
// ════════════════════════════════════════════════════════════════════════════
//
// 读它的三处:
//   ① 单据链条(app/components/chain/ChainBar.tsx)—— 把一条链原样交给 document_chain_walk();
//   ② 构建检查(scripts/check-chain-bar.mjs)—— 每一种单据的详情页都要画它;fixture 296 里抄着的四份必须逐字等于这里;
//   ③ fixture 296(db/fixtures/296-…)—— 四条链各一套完整单据,任两步互相找得到。
// 【关系】不写在这里:哪两张单据有关系,由关联图回答(外键推出来的边 + document_relation_arms 声明的边),
//   与关联页(/related/…)同一份定义。这里只说:一条链有哪几步、每一步是哪几种单据、哪几对步骤之间走得通。
//
// ★ 一步 = 一种或几种单据(`keys`,document_types.key)。产出批是 13 个前缀、一张表 —— 13 个都列出来,
//   check-chain-bar.mjs 核对它们恰好是 document_types 里 table_name = 'output_batches' 的那 13 个。
// ★ 没有自己页面的那五步住在宿主单据里(Tim 裁定:不造新页面):
//     定价 → 进料批页 #pricing · 应付 → /finance/payables/<批 id> · 预留 → 销售订单页 #reservations ·
//     成本分摊 → 加工页 #cost-allocation · 银行对账 → 对账单页上匹配的那一行 #line-<行 id> · 付薪 → 它那张分录。
//   `filter` = 这一步在宿主单据上存在的判据(document_chain_step_admits);`page` / `anchor` = 链到哪里;
//   `permission` = 打不开这一步要哪个码(只给宿主步骤写;单据步骤读 document_types.view_permission)。
// ★ `edges` = 哪几对步骤之间走得通(无向)。不只是相邻的两步:采购那一条的付款可以不经付款申请
//   (线上今天 0 张付款申请、13 笔付款),所以「应付 → 付款」也是一条边。
//   ⚠ 而「采购单 → 付款」(预付)【不是】一条边:步骤图上的距离决定从哪一侧去找,一条在数据上常常是空的捷径
//     会让采购单"离对账单很近"、于是只从付款那一侧去找它 —— 而那一侧没有预付时它就找不到了(fixture 296 实测)。
//     预付款照旧画在采购单页自己的付款那一节里。
//
// ⚠ 下面 CHAINS-BEGIN 与 CHAINS-END 之间是一个【纯 JSON 形状的 JS 字面量】(没有类型标注):
//   scripts/check-chain-bar.mjs 不经 TypeScript 读它。改它的形状,同一个提交改那支检查与 fixture 296。

export type ChainStep = {
    id: string
    keys: readonly string[]
    filter?: 'payable' | 'reservation' | 'cost_allocation' | 'payroll_payment'
    /** 宿主步骤链到哪一页:默认是那张单据自己的页面(document_detail_href);'payable' = /finance/payables/<id> */
    page?: 'payable'
    /** 页内锚点(宿主步骤);'line' = 对账单页上匹配的那一行 */
    anchor?: string
    /** 宿主步骤打不开时要的码(单据步骤不写,读 document_types.view_permission) */
    permission?: string
}
export type Chain = { id: string; steps: readonly ChainStep[]; edges: readonly (readonly [number, number])[] }

export const CHAINS: readonly Chain[] =
// CHAINS-BEGIN
[
    {
        id: 'purchasing',
        steps: [
            { id: 'purchase_order', keys: ['purchase_order'] },
            { id: 'inbound_batch', keys: ['inbound_batch'] },
            { id: 'assay', keys: ['assay_result'] },
            { id: 'pricing', keys: ['inbound_batch'], anchor: '#pricing', permission: 'module.inbound.view' },
            { id: 'payable', keys: ['inbound_batch'], filter: 'payable', page: 'payable', permission: 'module.finance.view' },
            { id: 'payment_request', keys: ['payment_request'] },
            { id: 'payment', keys: ['payment_out'] },
            { id: 'bank_reconciliation', keys: ['bank_statement'], anchor: 'line' },
        ],
        edges: [[0, 1], [1, 2], [1, 3], [2, 3], [3, 4], [4, 5], [5, 6], [4, 6], [6, 7]],
    },
    {
        id: 'processing',
        steps: [
            { id: 'work_order', keys: ['work_order'] },
            { id: 'processing_run', keys: ['processing_run'] },
            { id: 'input_batches', keys: ['inbound_batch'] },
            {
                id: 'output_batches',
                keys: ['output_batch', 'output_aluminium_foil', 'output_anode_powder', 'output_anode_sheet', 'output_casing',
                    'output_cathode_powder', 'output_cathode_sheet', 'output_cell', 'output_collected_dust', 'output_copper_foil',
                    'output_harness_bms_busbar', 'output_separator', 'output_structural_parts'],
            },
            { id: 'cost_allocation', keys: ['processing_run'], filter: 'cost_allocation', anchor: '#cost-allocation', permission: 'module.processing.view' },
        ],
        edges: [[0, 1], [1, 2], [1, 3], [1, 4]],
    },
    {
        id: 'sales',
        steps: [
            { id: 'quote', keys: ['quote'] },
            { id: 'sales_order', keys: ['sales_order'] },
            { id: 'reservation', keys: ['sales_order'], filter: 'reservation', anchor: '#reservations', permission: 'module.sales.view' },
            { id: 'shipment', keys: ['shipment'] },
            { id: 'container', keys: ['container'] },
            { id: 'invoice', keys: ['invoice'] },
            { id: 'receipt', keys: ['payment_receipt'] },
            { id: 'credit_note', keys: ['credit_note'] },
        ],
        edges: [[0, 1], [1, 2], [1, 3], [2, 3], [3, 4], [1, 5], [5, 6], [5, 7]],
    },
    {
        id: 'people',
        steps: [
            { id: 'attendance', keys: ['attendance_period'] },
            { id: 'overtime', keys: ['overtime_batch'] },
            { id: 'leave', keys: ['leave_request'] },
            { id: 'payroll_period', keys: ['payroll_period'] },
            { id: 'payroll_payment', keys: ['journal_entry'], filter: 'payroll_payment' },
        ],
        edges: [[0, 3], [1, 3], [2, 3], [3, 4]],
    },
]
// CHAINS-END

export type ChainId = 'purchasing' | 'processing' | 'sales' | 'people'

export function chainById(id: ChainId): Chain {
    const c = CHAINS.find((x) => x.id === id)
    if (!c) throw new Error(`CHAIN_UNKNOWN|${id} —— lib/chains.ts 里没有这一条链`)
    return c
}

/** 一条链交给 document_chain_walk() 的那一份:只有 keys / filter 与边 —— 名字与锚点是页面的事。 */
//   (可变的数组 —— 它要过 PostgREST 的 Json 类型,而 Json 不收 readonly)
export type ChainWalkDefinition = { steps: { keys: string[]; filter: string | null }[]; edges: number[][] }
export function chainWalkDefinition(c: Chain): ChainWalkDefinition {
    return { steps: c.steps.map((s) => ({ keys: [...s.keys], filter: s.filter ?? null })), edges: c.edges.map(([a, b]) => [a, b]) }
}

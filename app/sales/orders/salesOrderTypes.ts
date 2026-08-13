// SO-1:销售订单在应用这一侧的形状与共用零件。
//
// 【权限:module.finance.*】—— 线上【没有】 module.sales.* 这对码(查过目录)。
// 销售这条链今天是分开的:record_output_sale 要 module.output.edit,而
// sales_records 的 RLS 与 create_invoice / attribute_sale_customer 都是
// module.finance.*。订单四张表跟着 sales_records 自己的策略走,页面因此也用
// requireModule(MOD.finance)。【这留下一个真实的分叉】:今天录入销售的人持的是
// output.edit,与打开这张订单页所需的不是同一对码 —— 记在这里,等 Tim 决定是
// 开一个 module.sales.*,还是把销售入口整体挪进财务。

export const SO_STATUSES = ['draft', 'confirmed', 'closed', 'cancelled'] as const
export type SoStatus = (typeof SO_STATUSES)[number]

// 状态 → 文案键。静态映射,不拼动态键(check-i18n 的键样字面量收网直接验到)。
export const SO_STATUS_KEY: Record<string, string> = {
    draft: 'sales.status.draft',
    confirmed: 'sales.status.confirmed',
    closed: 'sales.status.closed',
    cancelled: 'sales.status.cancelled',
}
export const soStatusKey = (s: string) => SO_STATUS_KEY[s] ?? 'sales.status.unknown'

// 【允许的去处,与数据库那一份同一张表】set_sales_order_status 里逐个状态写着
// 同样的允许表;界面据它决定画哪几个按钮。两处都写是【故意】的:数据库那份是
// 闸,这份是"不给人看见一个必然被拒的按钮"。它们不一致时,数据库赢 ——
// 所以界面永远不该比数据库更宽松。fixture 63 E 臂钉的是数据库那一份。
export const SO_ALLOWED_NEXT: Record<string, SoStatus[]> = {
    draft: ['confirmed', 'cancelled'],
    confirmed: ['closed', 'cancelled'],
    closed: [],
    cancelled: [],
}

export type CreditRow = {
    customer_id: string
    credit_limit_base: number | null
    credit_hold: boolean
    exposure_base: number | null
    headroom_base: number | null
    sales_blocked: boolean
}

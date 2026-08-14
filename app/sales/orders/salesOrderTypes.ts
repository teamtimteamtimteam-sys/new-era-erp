// SO-1:销售订单在应用这一侧的形状与共用零件。
//
// 【权限:module.sales.view / module.sales.edit】(SO-1-fu)
// 销售是一个真模块:自己的单据、自己的角色、自己的操作面。上一刀曾把这四张表
// 挂在 module.finance.* 上(理由是"跟着数据自己的策略走"),那是错的 ——
// 那条经验用来避免给【既有】数据换一套没人想过的权限,而这四张表就是新策略本身。
// 订单先于财务:财务拥有的是事后那条链(sales_records / invoices / AR)。
// 三条理由完整写在 db/migrations/2026-08-13-so1-fu1-sales-module-permission.sql。

export const SO_STATUSES = ['draft', 'confirmed', 'partially_shipped', 'shipped', 'closed', 'cancelled'] as const
export type SoStatus = (typeof SO_STATUSES)[number]

// 状态 → 文案键。静态映射,不拼动态键(check-i18n 的键样字面量收网直接验到)。
export const SO_STATUS_KEY: Record<string, string> = {
    draft: 'sales.status.draft',
    confirmed: 'sales.status.confirmed',
    // SO-3b:履约两态 —— 由 ship_order 现算后写入,不是人点的
    partially_shipped: 'sales.status.partially_shipped',
    shipped: 'sales.status.shipped',
    closed: 'sales.status.closed',
    cancelled: 'sales.status.cancelled',
}
export const soStatusKey = (s: string) => SO_STATUS_KEY[s] ?? 'sales.status.unknown'

// 【允许的去处,与数据库那一份同一张表】set_sales_order_status 里逐个状态写着
// 同样的允许表;界面据它决定画哪几个按钮。两处都写是【故意】的:数据库那份是
// 闸,这份是"不给人看见一个必然被拒的按钮"。它们不一致时,数据库赢 ——
// 所以界面永远不该比数据库更宽松。fixture 63 E 臂钉的是数据库那一份。
// SO-3b:与 set_sales_order_status 的允许表【逐字同一张】。
// partially_shipped / shipped 不在任何一行的右边 —— 它们由 ship_order 按
// "已发 vs 已订"现算后写入,不是人能点的;这张表只管人能点的那些。
// confirmed → closed 那条路【关掉了】:一张还没发货的订单"走完了"说不通。
// partially_shipped 没有任何去处:发出去的货收不回来,更正走贷项凭证。
export const SO_ALLOWED_NEXT: Record<string, SoStatus[]> = {
    draft: ['confirmed', 'cancelled'],
    confirmed: ['cancelled'],
    partially_shipped: [],
    shipped: ['closed'],
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

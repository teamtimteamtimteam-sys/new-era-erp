// app/operation/orders/woTypes.ts
// 工单状态 → i18n 键的反查。列表页与详情页共用同一个 mapper
// (与 app/operation/status.ts、app/sales/quotes/quoteTypes.ts 同一形状)。
//
// 【后缀集合接的是 work_orders.status 的 CHECK】check-i18n 的清单从那张表现读,
// 所以数据库里加一个状态,这里的键检查会自动跟着变宽 —— 而不是等到屏幕上出现
// 一个键名才有人发现。
export function workOrderStatusKey(status: string | null): string {
    return 'processing.wo.status.' + (status ?? 'draft')
}

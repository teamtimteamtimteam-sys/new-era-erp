// METAL-1:行情异常判词在【应用这一侧】的形状。
//
// 判据本身一份实现,住在数据库里(metal_price_anomaly / preview_metal_price_anomalies)——
// 页面【不自己算】。理由与 preview_revalue_foreign_balances、reprice_split 同一条:
// 两份算术会在写下的那天一致,此后各自漂移,而屏幕上那份是人相信的那份。
//
// 【三种判词,no_reference 不是 false】线上 7 个金属里有 4 个只有一条报价,
// 它们【没有可比的对象】。把"没法查"画成"查过、没问题"正是这套检查存在的理由的
// 反面 —— 所以它是第三种判词,界面照三种画。补上它需要 per-metal 的绝对区间
// (7 个金属 × 上下界),那是一个决定,不是一次实现。

export type AnomalyVerdict = {
    verdict: 'outside' | 'inside' | 'no_reference'
    metal: string
    price_usd_per_tonne: number
    price_date: string
    threshold_pct: number
    reference_price: number | null
    reference_date: string | null
    reference_side: 'previous' | 'later' | null
    change_pct: number | null
}

// 只有 outside 需要拦人确认。inside 与 no_reference 都直接保存 ——
// 【no_reference 不弹提示,但也不该冒充"检查通过"】:它在列表上有自己的徽标。
export function outsideOnly(list: AnomalyVerdict[]): AnomalyVerdict[] {
    return list.filter((v) => v.verdict === 'outside')
}

// 表单第二次提交时带上它 —— 人已经看过两个数字并确认了。
// 【服务端不因为缺了它而拒绝任何东西】:这是提醒,不是闸门。它只决定
// "这一次提交要不要先把提示画出来"。
export const ACK_FIELD = 'anomaly_ack'

// 【确认的是【这些数字】,不是"下一次提交"】。确认位里带上被提示的那一组
// (金属 + 价格);提交时重算一遍,签名对不上就【再提示一次】。
//
// 少了这一层,先被提示、再把价格改成另一个同样离谱的数字,第二次提交会带着
// 上一次的确认位直接存下去 —— 那是一句"我看过了"被用在一个没人看过的数字上。
export function ackSignature(items: AnomalyVerdict[]): string {
    return items
        .map((v) => `${v.metal}:${Number(v.price_usd_per_tonne)}`)
        .sort()
        .join(',')
}

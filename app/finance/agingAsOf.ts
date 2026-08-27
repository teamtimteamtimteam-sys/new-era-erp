// app/finance/agingAsOf.ts
// AP/AR 账龄「截至某一天」的共享读取层 —— **四个消费方读的是这一份**:
//   /finance/payables            /finance/payables/export
//   /finance/receivables         /finance/receivables/export
//
// 【为什么是一份而不是四份】屏幕上那个数与导出文件里那个数必须是同一个数。
// 各写各的解析与调用,它们第一天相等、之后悄悄漂开 —— 这正是本仓库
// 「一条规矩两份实现」反复付账的那个形状,而账龄这件事上它的表现形式是:
// 有人对着屏幕报了一个数,附件里是另一个数,而两边都说自己是"截至 6 月 30 日"。
//
// 【本层不做算术】档位、合计、缺席的数目全部由 ap_aging_asof / ar_aging_asof
// 给出。页面与导出只负责画 —— 与损益表/资产负债表/现金流量表同一个形状
// (OPS-16:本页不算账)。
//
// 【as_of 缺省时【不传】,而不是在这里算一个今天】
// `new Date().toISOString().slice(0,10)` 是 **UTC 的今天**,而这套系统的"今天"
// 是新加坡的今天(db/fixtures/15 把它钉住)。UTC+8 的清晨那几个钟头里,
// 两者差一天 —— 于是一份"截至今天"的账龄会悄悄变成"截至昨天"。
// 所以这里把 p_as_of 留空,让函数自己用 CURRENT_DATE:那是库的今天,
// 也就是这套系统唯一认的那个今天。

import { createClient } from '@/lib/supabase/server'
import { isYmd } from '@/lib/dateFilter'

export type AgingRowAp = {
    doc_kind: 'inbound' | 'expense' | 'freight'
    doc_id: string
    doc_code: string
    inbound_batch_id: string | null
    supplier_id: string | null
    supplier_name: string | null
    counterparty_kind: 'supplier' | 'employee'
    counterparty_id: string
    counterparty_name: string
    doc_date: string
    due_date: string | null
    doc_value_base: number
    settled_base: number
    open_base: number
    currency: string
    open_ccy: number
    days_outstanding: number
    bucket: string
}

export type AgingRowAr = {
    sales_record_id: string | null
    doc_kind: string
    doc_code: string
    invoice_id: string | null
    invoice_code: string | null
    customer_id: string | null
    customer_name: string | null
    sale_date: string
    due_date: string | null
    amount_base: number
    settled_base: number
    credited_base: number
    open_base: number
    currency: string
    amount_ccy: number
    settled_ccy: number
    open_ccy: number
    credited_ccy: number
    days_outstanding: number
    bucket: string
}

// 【金额口径的令牌集合 —— 一处声明,三个读者】
// ① TypeScript 的类型从它派生;② scripts/check-i18n.mjs 的 MANIFEST 从这一行
// 现读后缀集合,所以将来多一种口径,两个语言都必须补上句子才过得了构建;
// ③ db/fixtures/135 断言两支函数【真的】只吐这两个令牌 —— 少了它,库那侧改了
// 令牌名,这里只会安安静静地把一个原始机器串印到屏幕上
// (docs/machine-text-reaching-humans.md 记的正是这一类)。
export const AMOUNT_BASES = ['quantity_now_price_asof', 'amounts_as_recorded'] as const
export type AmountBasis = (typeof AMOUNT_BASES)[number]

export type AgingReport<R> = {
    side: 'ap' | 'ar'
    as_of: string
    today: string
    is_past: boolean
    system_start_date: string | null
    before_system_start: boolean
    base_currency: string
    /** 机器令牌,不是给人读的句子 —— 措辞按语言在 messages/ 里选一条 */
    amount_basis: AmountBasis
    /** AP 专有:那一天【还没有价】而被挡掉的单据数。无 data.view_prices 时为 null */
    unpriced_excluded: number | null
    total_open_base: number
    buckets: Record<string, number>
    rows: R[]
}

/** 从 searchParams 取截至日;非法或缺省 → 空串(交给函数自己用库的今天)。 */
export function parseAsOf(sp: { as_of?: string }): string {
    const raw = (sp.as_of ?? '').trim()
    return isYmd(raw) ? raw : ''
}

/**
 * 读一侧的账龄。**错误一律抛出,绝不返回一份空报表** —— 一份读成空的账龄
 * 在屏幕上是「没有未结单据」、在 CSV 里是一个只有抬头的文件,两者都是假话。
 * 与 lib/db-helpers 的 mustRows 同一条规矩(一次失败不是一个空集),
 * 只是这里的返回值是一个对象而不是一组行。
 */
export async function readAging<R>(
    side: 'ap' | 'ar',
    asOf: string,
): Promise<AgingReport<R>> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc(
        side === 'ap' ? 'ap_aging_asof' : 'ar_aging_asof',
        asOf ? { p_as_of: asOf } : {},
    )
    if (error) throw new Error(error.message)
    if (!data) throw new Error(`${side}_aging_asof returned no report`)
    return data as unknown as AgingReport<R>
}

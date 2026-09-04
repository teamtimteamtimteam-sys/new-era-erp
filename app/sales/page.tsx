// app/sales/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-6 ⑤c + ⑨(2026-09-04)· 销售 Overview —— 【这个模块此前也没有根】
// ════════════════════════════════════════════════════════════════════════════
//
// 【它此前是什么:不存在】与物流同一处缺席(docs/module-overview-basis.md §6:
//   「**没有 app/sales/page.tsx**」)。本刀建了它。
//
// 【两条陈述】
//   ① **管道:报价 → 订单 → 发货 → 开票,每一段停着多少** ——
//      报价在 /sales/quotes,订单在 /sales/orders,发票在 /finance/invoices。
//      每一页都只看得见自己那一段;**"哪一段堵着"是没有任何一页答得了的问题**,
//      而它恰好是这个模块此刻最值得知道的一件事。
//   ② **信用:敞口,以及【有几家客户根本没有设限】** ——
//      客户在 /sales/customers,欠款在 /finance/receivables。
//      ★ 第二半是本刀刻意加的:一个只报"敞口合计"的数,会把
//        「限额是 0」与「压根没设限额」画成同一件事,而它们是两种完全不同的处境。★
//
// ★★【这一页的 D5:sales 这个角色自己就撞得上,实测】★★
//   进得来这一页的是 module.sales.view = admin·auditor·gm·sales(四个)。
//   而【开票那一段】读的是发票,门是 module.finance.view = admin·auditor·cfo·finance·gm。
//   ★ **sales 进得来这一页,而看不见开票那一格** ★ —— 画成具名的
//   「受限(module.finance.view)」,不是空白、更不是零。
//   (信用那一条的门 module.customers.view = admin·auditor·finance·gm·sales,
//    四个进得来的人都持有,所以那一条今天对谁都不受限 —— **但判断仍由权限做**。)
//
// 【本页【不】画佣金】/sales/commissions 这一刀刚搬进来,而 live 上
//   commission_agreements 是 **0 行**(实测)。一条永远写着「0」的陈述不是状态,
//   是装饰 —— docs/module-overview-basis.md §8:一页三条真陈述,比七条里
//   有四条是装饰要有用得多。**它没有被忘掉,它是被判出去的。**
//
// 【手机(390px)】单列 max-w-3xl,与 CONV-7 那两页逐字相同。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN, allows } from '@/lib/modules'
import { getMyPermissions } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
import { formatAmount, businessToday } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import Figure from '@/app/components/overview/Figure'

type QuoteRow = { quote_id: string; status: string; expired: boolean | null; convertible: boolean | null }
type OrderRow = { id: string; status: string }
type ShipmentRow = { id: string; sales_order_id: string | null }
type InvoiceRow = { id: string; status: string }
type CreditRow = {
    customer_id: string
    code: string
    credit_limit_base: number | null
    exposure_base: number | null
    headroom_base: number | null
    credit_hold: boolean | null
}

export default async function SalesOverviewPage() {
    const denied = await requireFunction(FN.salesHome)
    if (denied) return denied

    const t = await getTranslations()
    const perms = await getMyPermissions()
    const supabase = await createClient()
    const asOf = businessToday()
    const baseCurrency = await getBaseCurrency()

    // ★【先判权限,再决定查不查】★ 见抬头的两处门。
    const canSeeInvoices = allows('module.finance.view', perms)
    const canSeeCustomers = allows('module.customers.view', perms)

    const [qRes, oRes, sRes, iRes, cRes] = await Promise.all([
        supabase.from('quote_status').select('quote_id, status, expired, convertible'),
        supabase.from('sales_orders').select('id, status').is('deleted_at', null),
        supabase.from('shipments').select('id, sales_order_id'),
        canSeeInvoices
            // 【读的是 invoices_masked,不是 invoices】—— check-masked-reads 当场
            // 抓到了第一版的直连。遮蔽表要走它的 _masked 伴生视图,否则一个
            // 权限不足的读者拿到的是 42501,而不是一份少了几列的行。
            //
            // ★【没有 .is('deleted_at', null),而这【不是】漏了一个过滤】★
            //   发票【根本不软删】—— db/tables/invoices.sql 没有 deleted_at 这一列,
            //   它的作废是一次状态迁移:status CHECK IN ('issued','void'),
            //   连同 voided_at / voided_by / void_reason 由守卫触发器只放行 issued→void。
            //   所以下面按 status = 'issued' 数,【已经】把作废的排除在外了。
            //   ★ 第一版照着别的表的样子写了 .is('deleted_at', null),于是整条查询
            //     42703 —— 而 mustRows 把它【抛】了出来,页面 500,冒烟当场逮到。
            //     这正是那条规矩要的结果:**一次失败必须是失败**。若当初写的是
            //     `?? []`,这一页会平静地印着「已开且未结清的发票:0 张」,
            //     而 200 看不出这件事。★
            ? supabase.from('invoices_masked').select('id, status')
            : Promise.resolve({ data: null, error: null }),
        canSeeCustomers
            ? supabase
                  .from('customer_credit_status')
                  .select('customer_id, code, credit_limit_base, exposure_base, headroom_base, credit_hold')
            : Promise.resolve({ data: null, error: null }),
    ])

    const quotes = mustRows(qRes, 'quote_status') as unknown as QuoteRow[]
    const orders = mustRows(oRes, 'sales_orders') as unknown as OrderRow[]
    const shipments = mustRows(sRes, 'shipments') as unknown as ShipmentRow[]
    const invoices = canSeeInvoices ? (mustRows(iRes as never, 'invoices_masked') as unknown as InvoiceRow[]) : null
    const credit = canSeeCustomers
        ? (mustRows(cRes as never, 'customer_credit_status') as unknown as CreditRow[])
        : null

    // ── ① 管道 ──────────────────────────────────────────────────────────────
    // 【每一段的判据都写在这里,而且都取"还没往下走"的那一半】
    //   报价:还能转单的(没过期、没作废)—— 它停在报价这一段;
    //   订单:草稿 + 已确认但还没发货的;
    //   发货:已发货而还没开票的 —— 这一段要发票那一侧才判得了,所以它跟着 D5 走。
    const quotesOpen = quotes.filter((q) => q.convertible === true).length
    const ordersOpen = orders.filter((o) => o.status === 'draft' || o.status === 'confirmed').length
    const shippedOrderIds = new Set(shipments.map((s) => s.sales_order_id).filter(Boolean))
    const shippedOrders = orders.filter((o) => shippedOrderIds.has(o.id)).length
    const invoicesOpen = invoices ? invoices.filter((i) => i.status === 'issued').length : null

    // ── ② 信用 ──────────────────────────────────────────────────────────────
    const exposure = credit ? credit.reduce((s, r) => s + Number(r.exposure_base ?? 0), 0) : null
    // ★【"限额是 0" 与 "没设限额" 不是一件事】★ —— 见抬头。
    const noLimit = credit ? credit.filter((r) => r.credit_limit_base === null).length : null
    const onHold = credit ? credit.filter((r) => r.credit_hold === true).length : null

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <h1 className="text-2xl font-bold mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('nav.sales')}
            </h1>
            <p className="text-sm mb-6 max-w-2xl" style={{ color: 'var(--brand-muted-text)' }}>
                {t('overview.intro')}
            </p>

            {/* ── ① 管道 ─────────────────────────────────────────────────── */}
            <Figure
                title={t('salesOverview.pipelineTitle')}
                basis={{
                    asOf,
                    source: t('salesOverview.pipelineSource'),
                    spans: t('salesOverview.pipelineSpans'),
                }}
                state={
                    quotes.length === 0 && orders.length === 0
                        ? { kind: 'unanswerable', why: t('salesOverview.pipelineNone') }
                        : { kind: 'ok' }
                }
                action={
                    <Link href="/sales/orders" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('sales.subnav.orders')}
                    </Link>
                }
            >
                <ul className="space-y-1 text-sm" style={{ color: 'var(--brand-text)' }}>
                    <li data-pipeline="quotes">{t('salesOverview.stageQuotes', { n: quotesOpen, total: quotes.length })}</li>
                    <li data-pipeline="orders">{t('salesOverview.stageOrders', { n: ordersOpen, total: orders.length })}</li>
                    <li data-pipeline="shipped">{t('salesOverview.stageShipped', { n: shippedOrders })}</li>
                    <li data-pipeline="invoices">
                        {/* ★【开票那一格是具名的受限,给 sales 这个角色】★ 见抬头。 */}
                        {canSeeInvoices ? (
                            t('salesOverview.stageInvoices', { n: invoicesOpen ?? 0 })
                        ) : (
                            <span data-overview-restricted="1" style={{ color: 'var(--brand-muted-text)' }}>
                                {t('salesOverview.stageInvoicesRestricted')}
                                <span className="ml-1 font-mono opacity-80">(module.finance.view)</span>
                            </span>
                        )}
                    </li>
                </ul>
            </Figure>

            {/* ── ② 信用 ─────────────────────────────────────────────────── */}
            <Figure
                title={t('salesOverview.creditTitle')}
                basis={{
                    asOf,
                    source: t('salesOverview.creditSource'),
                    spans: t('salesOverview.creditSpans'),
                }}
                state={
                    !canSeeCustomers
                        ? { kind: 'restricted', permission: 'module.customers.view' }
                        : credit !== null && credit.length === 0
                          ? { kind: 'unanswerable', why: t('salesOverview.creditNone') }
                          : { kind: 'ok' }
                }
                action={
                    <Link href="/sales/customers" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('nav.customers')}
                    </Link>
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {t('salesOverview.creditLine', {
                        exposure: formatAmount(exposure, baseCurrency),
                        customers: credit?.length ?? 0,
                    })}
                </p>
                <p className="text-sm mt-1" style={{ color: 'var(--brand-muted-text)' }}>
                    {/* ★ 没设限额的那几家 —— 它与"限额 0"不是一件事,见抬头。★ */}
                    {t('salesOverview.creditNoLimit', { n: noLimit ?? 0 })}
                    {onHold ? ` · ${t('salesOverview.creditOnHold', { n: onHold })}` : ''}
                </p>
            </Figure>
        </div>
    )
}

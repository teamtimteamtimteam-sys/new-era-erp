// app/purchasing/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-6 ⑤c + ⑨(2026-09-04)· 采购 Overview —— 【它此前是一次跳转】
// ════════════════════════════════════════════════════════════════════════════
//
// 【它此前是什么】全文十四行,主体是 `redirect(<采购订单那一页>)`。
//   CHART-0 ② 据此判定它是【一个别名,不是一个去处】,并把它的菜单条目删掉;
//   scripts/smoke-routes.mjs 至今把它记成 307。**Tim 的裁定(2026-09-04):
//   不许再跳转,它要有自己的路由。** 那条"别名不配有菜单条目"的判断没有被推翻
//   —— 被换掉的是这一页:它现在说得出东西,所以它配。
//
// 【两条陈述,各自的 spans 见下面 <Figure>】
//   ① **在途采购的敞口** —— 已确认 / 收货中的订单欠着多少还没到。
//      订单在 /purchasing/orders,收货在 /inbound,要付的钱在 /finance/payables:
//      **三页各说一段,没有一页说"还欠多少没到"。**
//   ② **合同的覆盖率** —— 有多少采购单是在一份合同底下下的。
//      合同在 /contracts,采购单在 /purchasing/orders,销售订单在 /sales/orders。
//
// ★★【这一页上有【两处不同的 D5,给两个不同的人】—— 实测,不是构造】★★
//   进得来这一页的是 module.purchasing.view = admin·auditor·cfo·finance·gm·procurement。
//     · `contract_coverage` 的门是 module.suppliers.view(OR customers.view)
//       = admin·auditor·finance·gm·procurement —— ★ **cfo 进得来,而看不见 ②** ★
//     · `purchase_order_status` 的金额列由 module.finance.view 遮
//       = admin·auditor·cfo·finance·gm —— ★ **procurement 进得来,而看不见 ① 的金额** ★
//   **同一页、两个人、两格不同的「受限」** —— 这比 CONV-7 在人力上找到的那一处
//   更强,而它同样是查 live 授权查出来的。两格都画成【具名的】限制(D5),
//   不是空白、更不是零。
//
// 【手机(390px)】单列 max-w-3xl,与 CONV-7 那两页逐字相同。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN, allows } from '@/lib/modules'
import { getMyPermissions } from '@/lib/permissions'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { formatAmount, businessToday } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import Figure from '@/app/components/overview/Figure'

type PoRow = {
    po_id: string
    code: string
    status: string
    expected_delivery_date: string | null
    currency: string | null
    estimated_total_ccy: number | null
    ordered_qty: number | null
    received_qty: number | null
    receipt_pct: number | null
}
type Coverage = {
    purchase_orders_total: number | null
    purchase_orders_under_contract: number | null
    contracts_total: number | null
    contracts_active: number | null
    contracts_buy_side: number | null
}

/** 【在途 = 已确认或收货中】—— 草稿还没承诺,取消与关闭已经不欠东西。 */
const IN_FLIGHT = ['confirmed', 'receiving']

export default async function PurchasingOverviewPage() {
    const denied = await requireFunction(FN.purchasingHome)
    if (denied) return denied

    const t = await getTranslations()
    const perms = await getMyPermissions()
    const supabase = await createClient()
    const asOf = businessToday()
    const baseCurrency = await getBaseCurrency()

    // ★【先判权限,再决定查不查】★ 见文件抬头那两处 D5。
    // 从空结果倒推"你没权限"在属主权限视图上会把「受限」画成「一条都没有」。
    const canSeeMoney = allows('module.finance.view', perms)
    const canSeeContracts =
        allows('module.suppliers.view', perms) || allows('module.customers.view', perms)

    const [poRes, covRes] = await Promise.all([
        supabase
            .from('purchase_order_status')
            .select('po_id, code, status, expected_delivery_date, currency, estimated_total_ccy, ordered_qty, received_qty, receipt_pct')
            .in('status', IN_FLIGHT),
        canSeeContracts
            ? supabase
                  .from('contract_coverage')
                  .select('purchase_orders_total, purchase_orders_under_contract, contracts_total, contracts_active, contracts_buy_side')
                  .maybeSingle()
            : Promise.resolve({ data: null, error: null }),
    ])

    const pos = mustRows(poRes, 'purchase_order_status') as unknown as PoRow[]
    const cov = canSeeContracts
        ? (mustOne(covRes as never, 'contract_coverage') as unknown as Coverage | null)
        : null

    // 【金额只在看得见的时候才算】—— 遮蔽视图对无权读者把这一列给成 null,
    // 而 null 与 0 在这里【不是】同一件事(lib/permissions.ts 的老账)。
    // 所以合计由 canSeeMoney 决定要不要做,不由值里有没有 null 决定。
    const openValue = canSeeMoney
        ? pos.reduce((s, r) => s + Number(r.estimated_total_ccy ?? 0), 0)
        : null
    // 【逾期 = 预计到货日已经过去而还没收完】两侧都来自订单那一行,但"还没收完"
    // 这一半是收货那边喂过来的(received_qty / receipt_pct)。
    const overdue = pos.filter(
        (r) => r.expected_delivery_date !== null && r.expected_delivery_date < asOf && Number(r.receipt_pct ?? 0) < 100,
    )
    // 【多币种时不合计】—— CCY-1:一个把三种货币加在一起的数是一个假数。
    const currencies = new Set(pos.map((r) => r.currency).filter(Boolean))
    const mixedCurrency = currencies.size > 1

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <h1 className="text-2xl font-bold mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('nav.purchasing')}
            </h1>
            <p className="text-sm mb-6 max-w-2xl" style={{ color: 'var(--brand-muted-text)' }}>
                {t('overview.intro')}
            </p>

            {/* ── ① 在途采购的敞口 ───────────────────────────────────────── */}
            <Figure
                title={t('purchasingOverview.inFlightTitle')}
                basis={{
                    asOf,
                    source: t('purchasingOverview.inFlightSource'),
                    spans: t('purchasingOverview.inFlightSpans'),
                }}
                state={
                    pos.length === 0
                        ? { kind: 'unanswerable', why: t('purchasingOverview.inFlightNone') }
                        : { kind: 'ok' }
                }
                action={
                    <Link href="/purchasing/orders" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('purchasing.subnav.orders')}
                    </Link>
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {t('purchasingOverview.inFlightLine', { orders: pos.length, overdue: overdue.length })}
                </p>
                {/* ★【金额那一格是【具名的】受限,不是一个空位】★ 见抬头:procurement
                    进得来这一页,而 module.finance.view 不在他手上。 */}
                <p className="text-sm mt-1" style={{ color: 'var(--brand-muted-text)' }}>
                    {!canSeeMoney ? (
                        <span data-overview-restricted="1">
                            {t('purchasingOverview.valueRestricted')}
                            <span className="ml-1 font-mono opacity-80">(module.finance.view)</span>
                        </span>
                    ) : mixedCurrency ? (
                        /* 【多币种就不给一个合计】—— 说出来,而不是把三种货币加起来。 */
                        t('purchasingOverview.valueMixed', { n: currencies.size })
                    ) : (
                        t('purchasingOverview.valueLine', {
                            amount: formatAmount(openValue, [...currencies][0] ?? baseCurrency),
                        })
                    )}
                </p>
            </Figure>

            {/* ── ② 合同的覆盖率 ─────────────────────────────────────────── */}
            <Figure
                title={t('purchasingOverview.contractTitle')}
                basis={{
                    asOf,
                    source: t('purchasingOverview.contractSource'),
                    spans: t('purchasingOverview.contractSpans'),
                }}
                state={
                    !canSeeContracts
                        ? { kind: 'restricted', permission: 'module.suppliers.view' }
                        : cov === null
                          ? { kind: 'unanswerable', why: t('purchasingOverview.contractNoRow') }
                          : { kind: 'ok' }
                }
                action={
                    <Link href="/contracts" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('nav.contracts')}
                    </Link>
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {t('purchasingOverview.contractLine', {
                        under: cov?.purchase_orders_under_contract ?? 0,
                        total: cov?.purchase_orders_total ?? 0,
                    })}
                </p>
                <p className="text-sm mt-1" style={{ color: 'var(--brand-muted-text)' }}>
                    {t('purchasingOverview.contractStock', {
                        active: cov?.contracts_active ?? 0,
                        buy: cov?.contracts_buy_side ?? 0,
                    })}
                </p>
            </Figure>
        </div>
    )
}

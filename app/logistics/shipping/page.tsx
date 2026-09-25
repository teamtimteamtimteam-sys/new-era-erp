// ★ APR-5b(Tim 2026-09-25,APR-5 grilling Q7 · 5b grilling Q6 · Q8):仓库的发货队列。
//
// 【这一页是发货的唯一地方】CFO 放行过的订单行、还没发完的数量、能发的预留 —— 仓库在这里发。
// 订单页不再有发货控件,只有一句指向这里的话(5b Q8)。
//
// 【一个价格都没有】读的是 shipping_queue_rows()(属主权限读者,门 action.ship_goods):
// 订单编号与日期、客户的法定名称、★ 送货地址(Tim 5b Q6 的点名例外)、放行时刻、行号、物料、单位、
// 放行数量 / 已发 / 剩余、活预留。没有单价、币种、汇率、金额、毛利、发票编号、余额 ——
// 那张返回列清单由 fixture 224 逐字钉住。仓库不持 module.sales.view(Q7),也不需要。
//
// 【没有活预留的行照样画】"放行了但还没备货"是仓库要知道的事:备货(预留)是销售做的。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { formatDate, formatAuditStamp } from '@/lib/dates'
import ShipQueueControl from './ShipQueueControl'

type QueueRow = {
    sales_order_id: string
    order_code: string
    order_date: string
    customer_name: string
    delivery_address: string | null
    released_at: string | null
    sales_order_line_id: string
    line_no: number
    material_code: string
    material_name: string
    unit: string
    released_qty: number
    shipped_qty: number
    remaining_qty: number
    reservation_id: string | null
    output_batch_code: string | null
    location_code: string | null
    location_name: string | null
    reserved_qty: number | null
}

export default async function ShippingQueuePage() {
    const denied = await requireFunction(FN.logisticsShipping)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const rows = mustRows(await supabase.rpc('shipping_queue_rows'), 'shipping_queue_rows') as unknown as QueueRow[]

    // 按订单、再按行分组(读者已经排好序:放行时刻、订单、行号、批次)
    type Line = { head: QueueRow; reservations: QueueRow[] }
    type Order = { head: QueueRow; lines: Map<string, Line> }
    const orders = new Map<string, Order>()
    for (const r of rows) {
        const o = orders.get(r.sales_order_id) ?? { head: r, lines: new Map<string, Line>() }
        orders.set(r.sales_order_id, o)
        const l = o.lines.get(r.sales_order_line_id) ?? { head: r, reservations: [] }
        o.lines.set(r.sales_order_line_id, l)
        if (r.reservation_id) l.reservations.push(r)
    }

    return (
        <div className="p-8 max-w-5xl">
            <div className="mb-6">
                <Link href="/logistics" className="hover:underline text-sm app-link">{t('common.back')}</Link>
            </div>
            <h1 className="mb-1">{t('logistics.shipping.title')}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-6">{t('logistics.shipping.intro')}</p>

            {orders.size === 0 ? (
                <p className="text-[color:var(--brand-muted-text)]">{t('logistics.shipping.empty')}</p>
            ) : (
                <div className="space-y-6">
                    {[...orders.values()].map((o) => (
                        <section key={o.head.sales_order_id} className="border border-gray-300 rounded p-4"
                                 data-shipping-order={o.head.order_code}>
                            <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 mb-2">
                                <h2 className="font-mono">{o.head.order_code}</h2>
                                <span className="text-sm text-[color:var(--brand-muted-text)]">
                                    {formatDate(o.head.order_date, locale)}
                                    {o.head.released_at && (
                                        <> · {t('logistics.shipping.releasedAt', { at: formatAuditStamp(o.head.released_at) })}</>
                                    )}
                                </span>
                            </div>
                            <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 mb-3">
                                <dt className="text-[color:var(--brand-muted-text)]">{t('logistics.shipping.colCustomer')}</dt>
                                <dd>{o.head.customer_name}</dd>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('logistics.shipping.colAddress')}</dt>
                                <dd className="whitespace-pre-line">{o.head.delivery_address ?? t('logistics.shipping.noAddress')}</dd>
                            </dl>

                            <div className="space-y-3">
                                {[...o.lines.values()].map((l) => (
                                    <div key={l.head.sales_order_line_id} className="border-t border-gray-200 pt-3">
                                        <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1 mb-2 text-sm">
                                            <span className="font-medium">
                                                #{l.head.line_no} {l.head.material_code} — {l.head.material_name}
                                            </span>
                                            <span>
                                                {t('logistics.shipping.quantities', {
                                                    released: String(l.head.released_qty),
                                                    shipped: String(l.head.shipped_qty),
                                                    remaining: String(l.head.remaining_qty),
                                                    unit: l.head.unit,
                                                })}
                                            </span>
                                        </div>
                                        {l.reservations.length === 0 ? (
                                            <p className="text-sm text-[color:var(--brand-muted-text)]">{t('logistics.shipping.noReservation')}</p>
                                        ) : (
                                            <ul className="space-y-3">
                                                {l.reservations.map((r) => (
                                                    <li key={r.reservation_id} className="text-sm">
                                                        <p className="mb-1">
                                                            {t('logistics.shipping.reservation', {
                                                                batch: r.output_batch_code ?? '—',
                                                                location: r.location_code
                                                                    ? `${r.location_code}${r.location_name ? ` ${r.location_name}` : ''}`
                                                                    : t('stock.unspecifiedLocation'),
                                                                qty: String(r.reserved_qty ?? ''),
                                                                unit: l.head.unit,
                                                            })}
                                                        </p>
                                                        <ShipQueueControl
                                                            orderId={o.head.sales_order_id}
                                                            reservationId={r.reservation_id as string}
                                                            reservedQty={Number(r.reserved_qty)}
                                                            remainingQty={Number(l.head.remaining_qty)}
                                                            unit={l.head.unit}
                                                            subject={`${o.head.order_code} #${l.head.line_no} · ${r.output_batch_code ?? ''}`}
                                                        />
                                                    </li>
                                                ))}
                                            </ul>
                                        )}
                                    </div>
                                ))}
                            </div>
                        </section>
                    ))}
                </div>
            )}

            <p className="text-xs text-[color:var(--brand-muted-text)] mt-6">{t('logistics.shipping.afterNote')}</p>
        </div>
    )
}

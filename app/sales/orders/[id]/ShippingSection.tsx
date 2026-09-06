// SO-3b:订单的【发货】区 —— 逐行:开票了没有、有哪些活预留、发哪一条。服务端组件。
//
// 【选项 C 的顺序写在最上面】订单流【先开票后发货】:开票认下债(借 1100 /
// 贷 2500),发货把负债换成收入(借 2500 / 贷 4000)。所以这一区的每一个
// 禁用条件都指向它前面的那一步,而不是笼统地说"还不能发"。
//
// 【发货不可撤】—— 后果句必须在按下之前就在屏幕上:货离开台账、收入落账、
// 那张发票从此作废不了。更正走贷项凭证(还不存在的概念),所以这句话不是
// 吓唬人,是真的没有回头路。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import ShipControl, { type ShipOption } from './ShipControl'
import { Button } from '@/app/components/ui/button'

type ResRow = {
    id: string
    sales_order_line_id: string
    qty: number
    output_batch_id: string
    location_id: string | null
    output_batches: { code: string; unit: string } | null
    storage_locations: { code: string } | null
}
type BilledRow = { sales_order_line_id: string | null; invoice_id: string }
type ShipRow = {
    id: string
    code: string
    ship_date: string
    shipment_lines: { id: string; qty: number; sales_order_line_id: string }[] | null
}

export default async function ShippingSection({
    orderId,
    status,
    lines,
}: {
    orderId: string
    status: string
    lines: { id: string; line_no: number; material_code: string; quantity: number; unit: string }[]
}) {
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()

    const lineIds = lines.map((l) => l.id)
    const canSeeFinance = await can('module.finance.view')
    const canShip = await can('module.sales.edit')

    // 活预留(released 与 consumed 都为空 —— SO-3b 起是两个条件)
    const reservations =
        lineIds.length === 0
            ? []
            : (mustRows(
                  await supabase
                      .from('sales_order_reservations')
                      .select('id, sales_order_line_id, qty, output_batch_id, location_id, output_batches ( code, unit ), storage_locations ( code )')
                      .in('sales_order_line_id', lineIds)
                      .is('released_at', null)
                      .is('consumed_at', null)
                      .order('created_at'),
                  'sales_order_reservations'
              ) as unknown as ResRow[])

    // 【开票了没有】判据与 ship_order 逐字同一条:在册未作废的行。
    // 【无 finance.view 的读者看不到发票】—— 那时不说"没开票"(那是另一件事),
    // 而是说"看不到";控件也不给,免得他撞一次必然的拒绝。
    const billed = !canSeeFinance || lineIds.length === 0
        ? []
        : (mustRows(
              await supabase
                  .from('invoice_lines_masked')
                  .select('sales_order_line_id, invoice_id')
                  .in('sales_order_line_id', lineIds)
                  .eq('invoice_voided', false),
              'invoice_lines'
          ) as unknown as BilledRow[])
    const billedSet = new Set(billed.map((b) => b.sales_order_line_id))

    const shipments = mustRows(
        await supabase
            .from('shipments')
            .select('id, code, ship_date, shipment_lines ( id, qty, sales_order_line_id )')
            .eq('sales_order_id', orderId)
            .order('ship_date'),
        'shipments'
    ) as unknown as ShipRow[]

    const shippedByLine = new Map<string, number>()
    for (const s of shipments)
        for (const sl of s.shipment_lines ?? [])
            shippedByLine.set(sl.sales_order_line_id, (shippedByLine.get(sl.sales_order_line_id) ?? 0) + Number(sl.qty))

    const shippable = status === 'confirmed' || status === 'partially_shipped'

    return (
        <section className="mt-8">
            <h2 className="font-medium mb-1">{t('sales.ship.title')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('sales.ship.note')}</p>

            {shipments.length > 0 && (
                <ul className="text-sm space-y-1 mb-3">
                    {shipments.map((s) => (
                        <li key={s.id} className="flex flex-wrap items-baseline gap-x-3">
                            {/* EXT-1:【这是发货单详情页的入口】此前这一段只给了一条
                                直指 PDF 的链接,于是"这张发货单是什么"在系统里只有
                                一个答案 —— 一份渲染出来的纸。单号现在进详情页,
                                送货单那条链接留在原处不动。 */}
                            <a href={`/sales/shipments/${s.id}`}
                               className="font-mono text-blue-600 hover:underline">{s.code}</a>
                            <span className="text-gray-500">{new Date(s.ship_date).toLocaleDateString(dl)}</span>
                            <span className="text-gray-500">
                                {t('sales.ship.lineCount', { n: String((s.shipment_lines ?? []).length) })}
                            </span>
                            <Button asChild variant="link" size="inline">
                                <a
                                    href={`/sales/shipments/${s.id}/pdf`}
                                    target="_blank"
                                    rel="noopener noreferrer"
                                >
                                    {t('sales.ship.deliveryNote')}
                                </a>
                            </Button>
                        </li>
                    ))}
                </ul>
            )}

            {!shippable && (
                <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-3">
                    {t('sales.ship.notShippable')}
                </p>
            )}

            <div className="space-y-4">
                {lines.map((l) => {
                    const mine = reservations.filter((r) => r.sales_order_line_id === l.id)
                    const shipped = shippedByLine.get(l.id) ?? 0
                    const isBilled = billedSet.has(l.id)
                    const opts: ShipOption[] = mine.map((r) => ({
                        reservationId: r.id,
                        label: `${r.output_batches?.code ?? '—'} · ${
                            r.storage_locations?.code ?? t('stock.unspecifiedLocation')
                        } · ${r.qty} ${r.output_batches?.unit ?? l.unit}`,
                        qty: Number(r.qty),
                    }))

                    return (
                        <div key={l.id} className="border border-gray-300 rounded p-3">
                            <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1 mb-2">
                                <span className="font-medium">
                                    #{l.line_no} <span className="font-mono">{l.material_code}</span>
                                </span>
                                <span className="text-sm">
                                    <span className="text-gray-600">{t('sales.ship.shippedLabel')}:</span>{' '}
                                    <span className="font-mono">
                                        {shipped} / {l.quantity} {l.unit}
                                    </span>
                                </span>
                                <span className="text-sm">
                                    {!canSeeFinance ? (
                                        <span className="text-gray-500">{t('sales.ship.invoiceRestricted')}</span>
                                    ) : isBilled ? (
                                        <span className="text-green-800">{t('sales.ship.invoiced')}</span>
                                    ) : (
                                        <span className="text-amber-800">{t('sales.ship.notInvoiced')}</span>
                                    )}
                                </span>
                            </div>

                            {/* 禁用的理由长在控件旁边,而且【各说各的】—— 三种"发不了"
                                指向三个不同的下一步 */}
                            {!shippable ? null : !canShip ? (
                                <p className="text-sm text-gray-600">
                                    {t('common.restricted')} — {t('sales.ship.needsSalesEdit')}
                                </p>
                            ) : !canSeeFinance ? (
                                <p className="text-sm text-gray-600">{t('sales.ship.blockedNoFinanceView')}</p>
                            ) : !isBilled ? (
                                <p className="text-sm text-gray-600">{t('sales.ship.blockedNotInvoiced')}</p>
                            ) : opts.length === 0 ? (
                                <p className="text-sm text-gray-600">{t('sales.ship.blockedNoReservation')}</p>
                            ) : (
                                <ShipControl orderId={orderId} options={opts} unit={l.unit} />
                            )}
                        </div>
                    )
                })}
            </div>

            <p className="text-xs text-gray-500 mt-3">{t('sales.ship.arNote')}</p>
        </section>
    )
}

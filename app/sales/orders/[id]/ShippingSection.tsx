// SO-3b:订单的【发货】区 —— 逐行:开票了没有、有哪些活预留、发哪一条。服务端组件。
//
// 【选项 C 的顺序写在最上面】订单流【先开票后发货】:开票认下债(借 1100 /
// 贷 2500),发货把负债换成收入(借 2500 / 贷 4000)。所以这一区的每一个
// 禁用条件都指向它前面的那一步,而不是笼统地说"还不能发"。
//
// ★ APR-5b(Tim 2026-09-25,5b grilling Q8):【发货不在这一页】—— 发货归仓库(action.ship_goods),
// 在 CFO 放行之后,在 /logistics/shipping 发。这一区只说这张单发了什么、每一行开票了没有,
// 并用一句看得见的话指向发货队列(持码的人多一个链接)。此前这里的发货控件还要 module.finance.view
// (看得见"开票了没有"),那个界面条件随控件一起拿掉了 —— 判据在 ship_order 里,不在屏幕上。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { Button } from '@/app/components/ui/button'
import { formatDate } from '@/lib/dates'

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
    const supabase = await createClient()

    const lineIds = lines.map((l) => l.id)
    const canSeeFinance = await can('module.finance.view')
    const canShip = await can('action.ship_goods')

    // 【开票了没有】判据与 ship_order 逐字同一条:在册未作废的行。
    // 【无 finance.view 的读者看不到发票】—— 那时不说"没开票"(那是另一件事),而是说"看不到"。
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
            <h2 className="mb-1">{t('sales.ship.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('sales.ship.note')}</p>

            {shipments.length > 0 && (
                <ul className="text-sm space-y-1 mb-3">
                    {shipments.map((s) => (
                        <li key={s.id} className="flex flex-wrap items-baseline gap-x-3">
                            {/* EXT-1:【这是发货单详情页的入口】此前这一段只给了一条
                                直指 PDF 的链接,于是"这张发货单是什么"在系统里只有
                                一个答案 —— 一份渲染出来的纸。单号现在进详情页,
                                送货单那条链接留在原处不动。 */}
                            <a href={`/sales/shipments/${s.id}`}
                               className="hover:underline app-link app-link-inline">{s.code}</a>
                            <span className="text-[color:var(--brand-muted-text)]">{formatDate(s.ship_date, locale)}</span>
                            <span className="text-[color:var(--brand-muted-text)]">
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
                <p className="text-sm text-[color:var(--brand-muted-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-3">
                    {t('sales.ship.notShippable')}
                </p>
            )}

            <div className="space-y-4">
                {lines.map((l) => {
                    const shipped = shippedByLine.get(l.id) ?? 0
                    const isBilled = billedSet.has(l.id)

                    return (
                        <div key={l.id} className="border border-gray-300 rounded p-3">
                            <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1 mb-2">
                                <span className="font-medium">
                                    #{l.line_no} <span>{l.material_code}</span>
                                </span>
                                <span className="text-sm">
                                    <span className="text-[color:var(--brand-muted-text)]">{t('sales.ship.shippedLabel')}:</span>{' '}
                                    <span>
                                        {shipped} / {l.quantity} {l.unit}
                                    </span>
                                </span>
                                <span className="text-sm">
                                    {!canSeeFinance ? (
                                        <span className="text-[color:var(--brand-muted-text)]">{t('sales.ship.invoiceRestricted')}</span>
                                    ) : isBilled ? (
                                        <span className="text-green-800">{t('sales.ship.invoiced')}</span>
                                    ) : (
                                        <span className="text-amber-800">{t('sales.ship.notInvoiced')}</span>
                                    )}
                                </span>
                            </div>

                        </div>
                    )
                })}
            </div>

            {/* ★ APR-5b:发货在仓库的发货队列里 —— 看得见、在这里按不动、说出为什么与去哪里 */}
            {shippable && (
                <p className="text-sm text-[color:var(--brand-muted-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2 mt-3">
                    {t('sales.ship.inQueue')}
                    {canShip && (
                        <>
                            {' '}
                            <Link href="/logistics/shipping" className="hover:underline app-link app-link-inline">
                                {t('sales.ship.openQueue')}
                            </Link>
                        </>
                    )}
                </p>
            )}

            <p className="text-xs text-[color:var(--brand-muted-text)] mt-3">{t('sales.ship.arNote')}</p>
        </section>
    )
}

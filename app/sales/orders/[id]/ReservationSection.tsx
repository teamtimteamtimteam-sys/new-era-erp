// SO-2:订单的预留 —— 逐行:许出去多少 / 许给了哪几批货 / 还能许多少。服务端组件。
//
// 【问库,不算账】数量全部来自 sales_order_reservations 与 stock_by_status
// (两者都由数据库派生),这里只做"把行按订单行分组"这一件展示上的事。
//
// 【一个真实的权限缺口,写在屏幕上而不是藏起来】
// 预留本身只要 module.sales.edit(reserve_stock 的判断),但【候选批次的库存
// 分布】读的是 stock_by_status,那张视图要 module.inventory.view。今天线上
// 每一个持 module.sales.* 的角色(admin / gm / sales / auditor)都同时持
// inventory.view,所以实际上没有人撞得到;但角色是可配的,所以缺口是结构性的。
// 撞上时【必须显示「受限」,不能显示一个空的候选清单】—— 空清单读起来是
// "没有货可以预留",而真相是"你看不到货"。这正是 lib/permissions.ts 存在的
// 全部理由(0 与"你看不见"在屏幕上一模一样)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { soStatusKey } from '../salesOrderTypes'
import ReserveControl, { type BucketOption } from './ReserveControl'
import ReleaseControl from './ReleaseControl'
import { Button } from '@/app/components/ui/button'

export type ReservationLine = {
    id: string
    line_no: number
    quantity: number
    material_id: string
    material_code: string
    material_name: string
    unit: string
}

type ReservationRow = {
    id: string
    sales_order_line_id: string
    output_batch_id: string
    location_id: string | null
    qty: number
    created_at: string
    released_at: string | null
    // SO-3b:一条预留有【两种】终局 —— 释放(货回到 available)与消耗(发货,
    // 货离开台账)。只看 released_at 会把已经发出去的那一条画成"还许着",
    // 而且给它一个【释放】按钮 —— 那个按钮按下去必然被拒。
    consumed_at: string | null
    release_reason: string | null
    output_batches: { code: string; unit: string } | null
    storage_locations: { code: string; name: string } | null
}
type ConsumedRow = {
    reservation_id: string
    qty: number
    shipments: { id: string; code: string } | null
}

export default async function ReservationSection({
    orderId,
    status,
    lines,
}: {
    orderId: string
    status: string
    lines: ReservationLine[]
}) {
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()

    const lineIds = lines.map((l) => l.id)
    const materialIds = [...new Set(lines.map((l) => l.material_id))]

    const reservations = (lineIds.length === 0
        ? []
        : (mustRows(
              await supabase
                  .from('sales_order_reservations')
                  .select(
                      'id, sales_order_line_id, output_batch_id, location_id, qty, created_at, released_at, consumed_at, release_reason, output_batches ( code, unit ), storage_locations ( code, name )'
                  )
                  .in('sales_order_line_id', lineIds)
                  .order('created_at'),
              'sales_order_reservations'
          ) as unknown as ReservationRow[])) as ReservationRow[]

    // SO-3b fu5:已经【消耗掉】的那些预留,各自变成了哪一张发货单的一行。
    // 屏幕上要能说出"它去哪了",而不是只把它从活预留里减掉 —— 一条消失的
    // 预留与一条从来不存在的预留长得一模一样。
    const consumedRows = (lineIds.length === 0
        ? []
        : (mustRows(
              await supabase
                  .from('shipment_lines')
                  .select('reservation_id, qty, shipments ( id, code )')
                  .in('sales_order_line_id', lineIds),
              'shipment_lines'
          ) as unknown as ConsumedRow[])) as ConsumedRow[]
    const shipByReservation = new Map(consumedRows.map((r) => [r.reservation_id, r.shipments]))

    // 候选:这一行的物料【还活着】的产出批次,按桶(批次 × 库位)列出可用量。
    const canSeeStock = await can('module.inventory.view')
    const buckets = new Map<string, BucketOption[]>() // material_id → 候选桶
    if (canSeeStock && materialIds.length > 0) {
        const batches = mustRows(
            await supabase
                .from('output_batches')
                .select('id, code, unit, material_id')
                .in('material_id', materialIds)
                .is('deleted_at', null)
                .order('code'),
            'output_batches'
        ) as unknown as { id: string; code: string; unit: string; material_id: string }[]

        if (batches.length > 0) {
            const byBatch = new Map(batches.map((b) => [b.id, b]))
            const rows = mustRows(
                await supabase
                    .from('stock_by_status')
                    .select('output_batch_id, location_id, location_code, location_name, stock_status, qty')
                    .in('output_batch_id', batches.map((b) => b.id))
                    .eq('stock_status', 'available'),
                'stock_by_status'
            ) as unknown as {
                output_batch_id: string
                location_id: string | null
                location_code: string | null
                location_name: string | null
                qty: number
            }[]

            for (const r of rows) {
                const b = byBatch.get(r.output_batch_id)
                if (!b || Number(r.qty) <= 0) continue
                const list = buckets.get(b.material_id) ?? []
                list.push({
                    outputBatchId: b.id,
                    batchCode: b.code,
                    locationId: r.location_id,
                    // 未指定库位【不是缺失】,它是一个普通的桶(LOC-1/STK-1)
                    locationLabel: r.location_code
                        ? `${r.location_code}${r.location_name ? ' · ' + r.location_name : ''}`
                        : t('stock.unspecifiedLocation'),
                    available: Number(r.qty),
                    unit: b.unit,
                })
                buckets.set(b.material_id, list)
            }
        }
    }

    // SO-3b fu5:【partially_shipped 的单仍然是活的】—— 剩下的行还要预留、还要发。
    // reserve_stock 早就收 partially_shipped(fu1 有意放开的:只认 confirmed 会让
    // 任何多行订单在第一次发货之后就再也走不下去),而这张页面还只画 confirmed 的
    // 控件 —— 于是数据库允许的事,屏幕上没有入口。界面可以比数据库严,但那要是
    // 一个【决定】;这里不是,这里是漏了。
    const isReservable = status === 'confirmed' || status === 'partially_shipped'

    return (
        <section className="mt-8">
            <h2 className="font-medium mb-1">{t('sales.reserve.title')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('sales.reserve.note')}</p>

            {/* 【禁用的理由长在控件旁边】—— 不是等人点了才说 */}
            {!isReservable && (
                <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-3">
                    {/* 【静态映射,不拼动态键】soStatusKey 是那一份唯一的表 */}
                    {t('sales.reserve.onlyConfirmed', { status: t(soStatusKey(status)) })}
                </p>
            )}

            <div className="space-y-4">
                {lines.map((l) => {
                    const mine = reservations.filter((r) => r.sales_order_line_id === l.id)
                    // 【三堆,不是两堆】活着的 / 已发掉的 / 放回去的
                    const active = mine.filter((r) => r.released_at === null && r.consumed_at === null)
                    const consumed = mine.filter((r) => r.consumed_at !== null)
                    const released = mine.filter((r) => r.released_at !== null)
                    const reserved = active.reduce((s, r) => s + Number(r.qty), 0)
                    const shipped = consumed.reduce((s, r) => s + Number(r.qty), 0)
                    // 【已许出去 = 已发 + 活预留】—— 与 line_spoken_for 同一个口径,
                    // 而那正是 reserve_stock 的天花板读的那一个。屏幕上写着另一个数,
                    // 人就会以为还能再许一点,然后撞一次 SO_RESERVE_EXCEEDS_LINE。
                    const room = Number(l.quantity) - reserved - shipped

                    return (
                        <div key={l.id} className="border border-gray-300 rounded p-3">
                            <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1 mb-2">
                                <span className="font-medium">
                                    #{l.line_no} <span className="font-mono">{l.material_code}</span>{' '}
                                    <span className="text-gray-500">{l.material_name}</span>
                                </span>
                                <span className="text-sm">
                                    <span className="text-gray-600">{t('sales.reserve.spokenForLabel')}:</span>{' '}
                                    <span className="font-mono">
                                        {reserved + shipped} / {l.quantity} {l.unit}
                                    </span>
                                </span>
                                {shipped > 0 && (
                                    <span className="text-sm text-gray-600">
                                        {t('sales.reserve.ofWhichShipped', { qty: String(shipped) })}
                                    </span>
                                )}
                                {/* 【零要说出来】留白读起来像"没加载出来" */}
                                {reserved + shipped === 0 && (
                                    <span className="text-sm text-gray-500">{t('sales.reserve.nothingReserved')}</span>
                                )}
                            </div>

                            {active.length > 0 && (
                                <ul className="text-sm space-y-2 mb-2">
                                    {active.map((r) => (
                                        <li key={r.id} className="flex flex-wrap items-baseline gap-x-3">
                                            <span className="font-mono">{r.output_batches?.code ?? '—'}</span>
                                            <span className="text-gray-500">
                                                {r.storage_locations?.code ?? t('stock.unspecifiedLocation')}
                                            </span>
                                            <span className="font-mono">
                                                {r.qty} {r.output_batches?.unit ?? l.unit}
                                            </span>
                                            <ReleaseControl
                                                orderId={orderId}
                                                reservationId={r.id}
                                                outputBatchId={r.output_batch_id}
                                                qty={Number(r.qty)}
                                                unit={r.output_batches?.unit ?? l.unit}
                                            />
                                        </li>
                                    ))}
                                </ul>
                            )}

                            {/* 【已发掉的预留:陈述,不给按钮】它的货已经离开台账,
                                释放它必然被拒(SO_RESERVATION_ALREADY_SHIPPED)——
                                摆一个注定失败的按钮比不摆更坏。链到那张发货单,
                                因为"它去哪了"才是这里唯一还没被回答的问题。 */}
                            {consumed.length > 0 && (
                                <ul className="text-sm space-y-1 mb-2">
                                    {consumed.map((r) => {
                                        const shp = shipByReservation.get(r.id) ?? null
                                        return (
                                            <li key={r.id} className="flex flex-wrap items-baseline gap-x-3 text-gray-600">
                                                <span className="font-mono">{r.output_batches?.code ?? '—'}</span>
                                                <span className="font-mono">
                                                    {r.qty} {r.output_batches?.unit ?? l.unit}
                                                </span>
                                                <span>
                                                    {t('sales.reserve.consumedBy', { code: shp?.code ?? '—' })}
                                                </span>
                                                {shp && (
                                                    <Button asChild variant="link" size="inline">
                                                        <a href={`/sales/shipments/${shp.id}/pdf`} target="_blank"
                                                           rel="noopener noreferrer">
                                                            {t('sales.ship.deliveryNote')}
                                                        </a>
                                                    </Button>
                                                )}
                                            </li>
                                        )
                                    })}
                                </ul>
                            )}

                            {released.length > 0 && (
                                <details className="text-xs text-gray-500 mb-2">
                                    <summary className="cursor-pointer">
                                        {t('sales.reserve.releasedCount', { n: String(released.length) })}
                                    </summary>
                                    <ul className="mt-1 space-y-0.5">
                                        {released.map((r) => (
                                            <li key={r.id}>
                                                <span className="font-mono">{r.output_batches?.code ?? '—'}</span>{' '}
                                                {r.qty} {r.output_batches?.unit ?? l.unit} ·{' '}
                                                {new Date(r.released_at as string).toLocaleString(dl)} ·{' '}
                                                {r.release_reason}
                                            </li>
                                        ))}
                                    </ul>
                                </details>
                            )}

                            {isReservable &&
                                (canSeeStock ? (
                                    <ReserveControl
                                        orderId={orderId}
                                        lineId={l.id}
                                        room={room}
                                        unit={l.unit}
                                        buckets={buckets.get(l.material_id) ?? []}
                                    />
                                ) : (
                                    // 【「受限」,不是一个空清单】见文件抬头
                                    <p className="text-sm text-gray-600">
                                        {t('common.restricted')} — {t('sales.reserve.needsInventoryView')}
                                    </p>
                                ))}
                        </div>
                    )
                })}
            </div>

            <p className="text-xs text-gray-500 mt-3">
                <Link href="/inventory/reports/snapshot" className="text-blue-600 hover:underline">
                    {t('sales.reserve.snapshotLink')}
                </Link>
            </p>
        </section>
    )
}

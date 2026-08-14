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
    release_reason: string | null
    output_batches: { code: string; unit: string } | null
    storage_locations: { code: string; name: string } | null
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
                      'id, sales_order_line_id, output_batch_id, location_id, qty, created_at, released_at, release_reason, output_batches ( code, unit ), storage_locations ( code, name )'
                  )
                  .in('sales_order_line_id', lineIds)
                  .order('created_at'),
              'sales_order_reservations'
          ) as unknown as ReservationRow[])) as ReservationRow[]

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

    const isConfirmed = status === 'confirmed'

    return (
        <section className="mt-8">
            <h2 className="font-medium mb-1">{t('sales.reserve.title')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('sales.reserve.note')}</p>

            {/* 【禁用的理由长在控件旁边】—— 不是等人点了才说 */}
            {!isConfirmed && (
                <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-3">
                    {/* 【静态映射,不拼动态键】soStatusKey 是那一份唯一的表 */}
                    {t('sales.reserve.onlyConfirmed', { status: t(soStatusKey(status)) })}
                </p>
            )}

            <div className="space-y-4">
                {lines.map((l) => {
                    const mine = reservations.filter((r) => r.sales_order_line_id === l.id)
                    const active = mine.filter((r) => r.released_at === null)
                    const released = mine.filter((r) => r.released_at !== null)
                    const reserved = active.reduce((s, r) => s + Number(r.qty), 0)
                    const room = Number(l.quantity) - reserved

                    return (
                        <div key={l.id} className="border border-gray-300 rounded p-3">
                            <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1 mb-2">
                                <span className="font-medium">
                                    #{l.line_no} <span className="font-mono">{l.material_code}</span>{' '}
                                    <span className="text-gray-500">{l.material_name}</span>
                                </span>
                                <span className="text-sm">
                                    <span className="text-gray-600">{t('sales.reserve.reservedLabel')}:</span>{' '}
                                    <span className="font-mono">
                                        {reserved} / {l.quantity} {l.unit}
                                    </span>
                                </span>
                                {/* 【零要说出来】留白读起来像"没加载出来" */}
                                {reserved === 0 && (
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

                            {isConfirmed &&
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

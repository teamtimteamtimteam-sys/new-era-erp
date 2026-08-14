// app/components/inventory/StockStatusPanel.tsx
// STK-1:一个批次的库存分布(库位 × 状态)+ 暂扣/释放。服务端组件。
//
// 【问库,不算账】数字全部来自 stock_by_status(由流水聚合),这里一个加减都不做。
//
// 【未指定库位不是异常,今天它是全部】线上所有流水都没有库位(库位这个轴
// LOC-1 才落地),所以每一个批次都只有"未指定库位"这一组。屏幕必须在这个
// 状态下读起来【自然】—— 所以它就是一个正常的分组标题,不带警告色、不带感叹号;
// 它只是说"这批货在系统里还没有指定放在哪"。
//
// 【零暂扣要说出来】没有暂扣时显示"没有暂扣",不是留白 —— 留白读起来像
// "这里的数据没加载出来",而那与"确实一件都没扣"是两回事。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import HoldReleaseControls from './HoldReleaseControls'
import TransferControl, { type LocationOption } from './TransferControl'

type Row = {
    location_id: string | null
    location_code: string | null
    location_name: string | null
    stock_status: string
    qty: number
}

// SO-2:committed 那一格背后【是谁】。数量看得见而主人看不见,是这个面板最容易
// 变成的那种屏幕:一句"已承诺 40",没人说得出是谁承诺的。
type Provenance = {
    id: string
    qty: number
    location_id: string | null
    // 【库位从这一行自己带出来,不去 locations 里查】那个列表只含【在用】库位
    // (它是转移目的地的清单),用它反查会让一条落在停用库位上的预留在屏幕上
    // 显示成一串 uuid —— 机器文本递到人脸上,正是本仓库反复修的那件事。
    storage_locations: { code: string; name: string } | null
    sales_order_lines: {
        line_no: number
        sales_orders: { id: string; code: string } | null
    } | null
}

export default async function StockStatusPanel({
    inboundBatchId = null,
    outputBatchId = null,
    unit,
}: {
    inboundBatchId?: string | null
    outputBatchId?: string | null
    unit: string
}) {
    const supabase = await createClient()
    const t = await getTranslations()

    let q = supabase
        .from('stock_by_status')
        .select('location_id, location_code, location_name, stock_status, qty')
    q = inboundBatchId ? q.eq('inbound_batch_id', inboundBatchId) : q.eq('output_batch_id', outputBatchId!)
    const rows = mustRows(await q, 'stock_by_status') as unknown as Row[]

    // IOD-1:转移目的地只列【在用】库位 —— 停用的库位不该再收货(LOC-1 的停用语义,
    // 服务端也点名拒 IOD_TRANSFER_TO_INACTIVE;这里不提供,是不让人先撞一次)
    const locations = mustRows(
        await supabase.from('storage_locations').select('id, code, name').eq('is_active', true).order('code'),
        'storage_locations'
    ) as unknown as LocationOption[]

    // SO-2:预留的出处。【只对产出批次有意义】—— 预留只指向产出批次。
    // 【没有 module.sales.view 的人拿不到行,而那不是零】—— 与遮蔽列同一条:
    // 空清单读起来是"没有人预留过",那与"你看不见谁预留的"是两回事。
    const canSeeOrders = await can('module.sales.view')
    const provenance: Provenance[] =
        outputBatchId && canSeeOrders
            ? (mustRows(
                  await supabase
                      .from('sales_order_reservations')
                      .select(
                          'id, qty, location_id, storage_locations ( code, name ), sales_order_lines ( line_no, sales_orders ( id, code ) )'
                      )
                      .eq('output_batch_id', outputBatchId)
                      .is('released_at', null)
                      .order('created_at'),
                  'sales_order_reservations'
              ) as unknown as Provenance[])
            : []

    // 按库位归组(NULL 自成一组 —— 不折叠进任何真库位)
    //
    // 【SO-2:逐个状态写出来,不用 else 兜底】此前这里是
    //     if (status === 'on_hold') held += ; else available +=
    // —— 一个 else 分支把【任何不认识的状态】都算进可用。第三个桶落地的那一天,
    // 它会把 committed 悄悄加进"可用",而屏幕上没有任何东西看起来不对。
    // 这与 `?? 0` 是同一种病:把不知道的东西伪装成一个具体的答案。
    // 现在不认识的状态【单列一栏】并说出它的名字(unknownStatus),因为
    // "这里有个我不认识的桶"必须看得见 —— 看得见才修得掉。
    type Group = {
        code: string | null
        name: string | null
        available: number
        held: number
        committed: number
        unknown: Map<string, number>
    }
    const empty = (r?: Row): Group => ({
        code: r?.location_code ?? null,
        name: r?.location_name ?? null,
        available: 0,
        held: 0,
        committed: 0,
        unknown: new Map(),
    })
    const byLocation = new Map<string, Group>()
    for (const r of rows) {
        const key = r.location_id ?? '__unspecified__'
        const g = byLocation.get(key) ?? empty(r)
        if (r.stock_status === 'available') g.available += Number(r.qty)
        else if (r.stock_status === 'on_hold') g.held += Number(r.qty)
        else if (r.stock_status === 'committed') g.committed += Number(r.qty)
        else g.unknown.set(r.stock_status, (g.unknown.get(r.stock_status) ?? 0) + Number(r.qty))
        byLocation.set(key, g)
    }
    // 一个批次可能一条流水都没有(理论上不会,但不要因此渲染成空白)
    if (byLocation.size === 0) {
        byLocation.set('__unspecified__', empty())
    }

    const totalHeld = [...byLocation.values()].reduce((s, g) => s + g.held, 0)
    const totalCommitted = [...byLocation.values()].reduce((s, g) => s + g.committed, 0)

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-1">{t('stock.panelTitle')}</h2>
            <p className="text-sm text-gray-500 mb-4">{t('stock.panelNote')}</p>

            {totalHeld === 0 && (
                <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-4">
                    {t('stock.nothingHeld')}
                </p>
            )}

            <div className="space-y-4">
                {[...byLocation.entries()].map(([key, g]) => (
                    <div key={key} className="border border-gray-300 rounded p-3">
                        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                            <span className="font-medium">
                                {key === '__unspecified__' ? (
                                    t('stock.unspecifiedLocation')
                                ) : (
                                    <>
                                        <span className="font-mono">{g.code}</span>
                                        {g.name && <span className="text-gray-500 ml-2">{g.name}</span>}
                                    </>
                                )}
                            </span>
                            <span className="text-sm">
                                <span className="text-gray-600">{t('stock.available')}:</span>{' '}
                                <span className="font-mono">{g.available} {unit}</span>
                            </span>
                            <span className="text-sm">
                                <span className="text-gray-600">{t('stock.onHold')}:</span>{' '}
                                <span className={'font-mono ' + (g.held > 0 ? 'text-amber-800 font-medium' : '')}>
                                    {g.held} {unit}
                                </span>
                            </span>
                            {/* SO-2:第三格。与暂扣并列,因为它回答的是同一个问题 ——
                                "这些货为什么不能动" —— 只是原因不同。 */}
                            <span className="text-sm">
                                <span className="text-gray-600">{t('stock.committed')}:</span>{' '}
                                <span className={'font-mono ' + (g.committed > 0 ? 'text-blue-800 font-medium' : '')}>
                                    {g.committed} {unit}
                                </span>
                            </span>
                            {[...g.unknown.entries()].map(([s, q]) => (
                                <span key={s} className="text-sm">
                                    <span className="text-gray-600">{t('stock.unknownStatus', { status: s })}:</span>{' '}
                                    <span className="font-mono text-red-700">{q} {unit}</span>
                                </span>
                            ))}
                        </div>
                        {key === '__unspecified__' && (
                            // 说明性的一句,不是警告 —— 今天全部库存都在这一组里
                            <p className="text-xs text-gray-500 mt-1">{t('stock.unspecifiedLocationHint')}</p>
                        )}
                        <HoldReleaseControls
                            inboundBatchId={inboundBatchId}
                            outputBatchId={outputBatchId}
                            locationId={key === '__unspecified__' ? null : key}
                            available={g.available}
                            held={g.held}
                            unit={unit}
                        />
                        {/* IOD-1:转移。可用与暂扣【各自一组】—— 一次转移只搬一个桶,
                            而状态原样带过去,所以两者不能合成一个控件。 */}
                        <TransferControl
                            inboundBatchId={inboundBatchId}
                            outputBatchId={outputBatchId}
                            fromLocationId={key === '__unspecified__' ? null : key}
                            stockStatus="available"
                            have={g.available}
                            unit={unit}
                            locations={locations}
                        />
                        {g.held > 0 && (
                            <TransferControl
                                inboundBatchId={inboundBatchId}
                                outputBatchId={outputBatchId}
                                fromLocationId={key === '__unspecified__' ? null : key}
                                stockStatus="on_hold"
                                have={g.held}
                                unit={unit}
                                locations={locations}
                            />
                        )}
                        {/* SO-2:一个桶一个转移控件的规矩继续 —— committed 也搬得动,
                            但服务端【只允许整桶搬】(部分搬会让预留行与流水对不上,
                            按名拒 IOD_TRANSFER_COMMITTED_PARTIAL)。所以这里的
                            数量框预填整桶,而提示语说清楚了这一条。 */}
                        {g.committed > 0 && (
                            <TransferControl
                                inboundBatchId={inboundBatchId}
                                outputBatchId={outputBatchId}
                                fromLocationId={key === '__unspecified__' ? null : key}
                                stockStatus="committed"
                                have={g.committed}
                                unit={unit}
                                locations={locations}
                            />
                        )}
                    </div>
                ))}
            </div>

            {/* ── SO-2:committed 那一格【背后是谁】────────────────────────────
                数量看得见而主人看不见,是这个面板最容易变成的那种屏幕。
                无 module.sales.view 时显示「受限」而不是空白 —— 空白读起来是
                "没有人预留过"。 */}
            {outputBatchId && (
                <div className="mt-4 pt-4 border-t border-gray-200">
                    <h3 className="text-sm font-medium mb-1">{t('stock.reservedBy')}</h3>
                    {!canSeeOrders ? (
                        <p className="text-sm text-gray-600">{t('common.restricted')}</p>
                    ) : totalCommitted === 0 ? (
                        <p className="text-sm text-gray-600">{t('stock.nothingCommitted')}</p>
                    ) : (
                        <ul className="text-sm space-y-1">
                            {provenance.map((p) => (
                                <li key={p.id} className="flex flex-wrap items-baseline gap-x-3">
                                    {p.sales_order_lines?.sales_orders ? (
                                        <Link
                                            href={`/sales/orders/${p.sales_order_lines.sales_orders.id}`}
                                            className="text-blue-600 hover:underline font-mono"
                                        >
                                            {p.sales_order_lines.sales_orders.code}
                                        </Link>
                                    ) : (
                                        <span className="font-mono">—</span>
                                    )}
                                    <span className="text-gray-500">
                                        #{p.sales_order_lines?.line_no ?? '—'}
                                    </span>
                                    <span className="font-mono">
                                        {p.qty} {unit}
                                    </span>
                                    <span className="text-gray-500">
                                        {p.storage_locations?.code ?? t('stock.unspecifiedLocation')}
                                    </span>
                                </li>
                            ))}
                        </ul>
                    )}
                </div>
            )}
        </section>
    )
}

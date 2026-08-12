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
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import HoldReleaseControls from './HoldReleaseControls'
import TransferControl, { type LocationOption } from './TransferControl'

type Row = {
    location_id: string | null
    location_code: string | null
    location_name: string | null
    stock_status: string
    qty: number
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

    // 按库位归组(NULL 自成一组 —— 不折叠进任何真库位)
    const byLocation = new Map<string, { code: string | null; name: string | null; available: number; held: number }>()
    for (const r of rows) {
        const key = r.location_id ?? '__unspecified__'
        const g = byLocation.get(key) ?? { code: r.location_code, name: r.location_name, available: 0, held: 0 }
        if (r.stock_status === 'on_hold') g.held += Number(r.qty)
        else g.available += Number(r.qty)
        byLocation.set(key, g)
    }
    // 一个批次可能一条流水都没有(理论上不会,但不要因此渲染成空白)
    if (byLocation.size === 0) {
        byLocation.set('__unspecified__', { code: null, name: null, available: 0, held: 0 })
    }

    const totalHeld = [...byLocation.values()].reduce((s, g) => s + g.held, 0)

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
                    </div>
                ))}
            </div>
        </section>
    )
}

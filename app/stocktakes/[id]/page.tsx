// app/stocktakes/[id]/page.tsx
// 盘点详情/点数页(移动端优先,端口自 GRN 现场收货的触控风格)。
// open = 点数界面(汇总条 + 已盘/未盘列表 + 底部粘性操作条);posted/cancelled = 只读行表。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { formatTimestamp } from '@/lib/format'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { stocktakeStatusLabelKey } from '../status'
import { qtyDelta, formatSigned } from '../delta'
import CountList, { type CountItem } from '../CountList'
import CancelStocktakeButton from './CancelStocktakeButton'
import { mustRows } from '@/lib/db-helpers'
import ActorName, { loadActorNames } from '@/app/components/ActorName'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type BatchFetchRow = {
    id: string
    code: string
    remaining_qty: number
    unit: string
    materials: { name: string } | null
}

export default async function StocktakeDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.stocktakes)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [stRes, linesRes, inboundRes, outputRes] = await Promise.all([
        supabase
            .from('stocktakes')
            .select('*')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('stocktake_lines')
            .select('*')
            .eq('stocktake_id', id)
            .order('counted_at', { ascending: false }),
        supabase
            .from('inbound_batches')
            .select('id, code, remaining_qty, unit, materials ( name )')
            .is('deleted_at', null)
            .order('code'),
        supabase
            .from('output_batches')
            .select('id, code, remaining_qty, unit, materials ( name )')
            .is('deleted_at', null)
            .order('code'),
    ])

    if (stRes.error || !stRes.data) {
        notFound()
    }

    if (linesRes.error || inboundRes.error || outputRes.error) {
        const err = linesRes.error ?? inboundRes.error ?? outputRes.error
        return (
            <div className="p-4 sm:p-8 max-w-3xl">
                <h1 className="text-2xl font-bold mb-4">{t('stocktakes.detailTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('stocktakes.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const st = stRes.data
    const lines = mustRows(linesRes)
    const inbound = (inboundRes.data as unknown as BatchFetchRow[] | null) ?? []
    const output = (outputRes.data as unknown as BatchFetchRow[] | null) ?? []

    // AUDEL-2:取消要看得见【谁】和【为什么】—— 一个只说"已取消"的状态标签,
    // 事后没有人答得出为什么这次盘点不算数。
    // AUDEL-3:取名与兜底【只有一处】—— app/components/ActorName.tsx。
    // 【这里原本写着"反查不到就印 uuid",那句话现在是错的,所以删掉而不是留着】:
    // Tim 的验收正是在这一族看到了一个裸 uuid,而 uuid 对读的人不是一个答案 ——
    // 它看起来像一个答案。现在印的是具名状态「该账号未关联员工档案」加一行小字 id。
    const cancelNames = await loadActorNames(supabase, [st.cancelled_by])

    const statusKey = stocktakeStatusLabelKey(st.status)
    const statusLabel = statusKey ? t(statusKey) : st.status

    // 行 → 批次信息;未盘 = 活批次里没有对应行的
    const inboundById = new Map(inbound.map((b) => [b.id, b]))
    const outputById = new Map(output.map((b) => [b.id, b]))
    const countedInboundIds = new Set(lines.map((l) => l.inbound_batch_id).filter(Boolean))
    const countedOutputIds = new Set(lines.map((l) => l.output_batch_id).filter(Boolean))

    const countedItems: CountItem[] = lines.map((l) => {
        const side = l.inbound_batch_id ? ('inbound' as const) : ('output' as const)
        const batch = l.inbound_batch_id
            ? inboundById.get(l.inbound_batch_id)
            : outputById.get(l.output_batch_id as string)
        return {
            side,
            batchId: (l.inbound_batch_id ?? l.output_batch_id) as string,
            code: batch?.code ?? '—', // 行还在但批次已被软删:占位展示,过账时 DB 会拦
            material: batch?.materials?.name ?? '—',
            remaining: batch?.remaining_qty ?? null,
            unit: batch?.unit ?? '',
            counted: l.counted_qty,
            book: l.book_qty,
            delta: batch ? qtyDelta(l.counted_qty, batch.remaining_qty) : null,
            notes: l.notes,
        }
    })

    const toUncounted = (side: 'inbound' | 'output') => (b: BatchFetchRow): CountItem => ({
        side,
        batchId: b.id,
        code: b.code,
        material: b.materials?.name ?? '—',
        remaining: b.remaining_qty,
        unit: b.unit,
        counted: null,
        book: null,
        delta: null,
        notes: null,
    })
    const uncountedItems: CountItem[] = [
        ...inbound.filter((b) => !countedInboundIds.has(b.id)).map(toUncounted('inbound')),
        ...output.filter((b) => !countedOutputIds.has(b.id)).map(toUncounted('output')),
    ]

    const totalBatches = inbound.length + output.length
    const diffCount = countedItems.filter((i) => i.delta !== null && i.delta !== 0).length
    const isOpen = st.status === 'open'

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <div className="mb-6">
                <Link href="/stocktakes" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-xl sm:text-2xl font-bold mb-2">{t('stocktakes.detailTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{st.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">{statusLabel}</span>
                {st.cancelled_at && (
                    <>
                        <span className="mx-2">·</span>
                        <span>
                            {t('stocktakes.cancelledAt')}: {formatTimestamp(st.cancelled_at, dateLocale)}
                            {' · '}
                            <ActorName userId={st.cancelled_by} names={cancelNames} />
                        </span>
                    </>
                )}
                {st.posted_at && (
                    <>
                        <span className="mx-2">·</span>
                        <span>
                            {t('stocktakes.colPosted')}: {formatTimestamp(st.posted_at, dateLocale)}
                        </span>
                    </>
                )}
            </p>
            {st.cancel_reason && (
                <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 mb-4">
                    {t('stocktakes.cancelReasonLabel')}: {st.cancel_reason}
                </p>
            )}

            {isOpen ? (
                <>
                    {/* 汇总条:已盘 X / 总 Y 批 · Z 批有差异 */}
                    <div className="bg-gray-50 rounded p-4 mb-6 text-sm">
                        {t('stocktakes.summary', {
                            counted: countedItems.length,
                            total: totalBatches,
                            diffs: diffCount,
                        })}
                    </div>

                    {countedItems.length > 0 && (
                        <>
                            <h2 className="text-lg font-semibold mb-2">{t('stocktakes.countedTitle')}</h2>
                            <CountList stocktakeId={id} items={countedItems} mode="counted" />
                        </>
                    )}

                    {uncountedItems.length > 0 && (
                        <>
                            <h2 className="text-lg font-semibold mb-2">{t('stocktakes.uncountedTitle')}</h2>
                            <CountList stocktakeId={id} items={uncountedItems} mode="uncounted" />
                        </>
                    )}

                    {/* 底部粘性操作条:复核过账(主)+ 取消(danger) */}
                    <div className="sticky bottom-0 mt-6 border-t border-gray-200 bg-white py-3">
                        <div className="flex gap-3">
                            <Button asChild variant="default" size="lg" className="flex-1 min-h-[48px] text-base">
                                <Link href={`/stocktakes/${id}/review`}>{t('stocktakes.review')}</Link>
                            </Button>
                            <CancelStocktakeButton stocktakeId={id} code={st.code} />
                        </div>
                    </div>
                </>
            ) : (
                /* posted / cancelled:只读行表(差异按账面快照算 —— 过账后剩余已被改成实点) */
                <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('stocktakes.colBatch')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('stocktakes.colMaterial')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('stocktakes.bookLabel')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('stocktakes.countedLabel')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('stocktakes.deltaLabel')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {countedItems.map((item) => {
                                const bookDelta =
                                    item.book !== null ? qtyDelta(item.counted ?? 0, item.book) : null
                                return (
                                    <tr key={`${item.side}:${item.batchId}`}>
                                        <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                            {item.code}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2">{item.material}</td>
                                        <td className="border border-gray-300 px-4 py-2">
                                            {item.book} {item.unit}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2">
                                            {item.counted} {item.unit}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2">
                                            {bookDelta !== null && bookDelta !== 0 ? (
                                                <span
                                                    className={
                                                        'font-medium ' +
                                                        (bookDelta > 0 ? 'text-green-600' : 'text-red-600')
                                                    }
                                                >
                                                    {formatSigned(bookDelta)}
                                                </span>
                                            ) : (
                                                '—'
                                            )}
                                        </td>
                                    </tr>
                                )
                            })}
                            {countedItems.length === 0 && (
                                <tr>
                                    <td
                                        colSpan={5}
                                        className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                    >
                                        {t('stocktakes.noLines')}
                                    </td>
                                </tr>
                            )}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    )
}

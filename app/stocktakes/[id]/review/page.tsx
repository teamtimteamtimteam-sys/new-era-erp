// app/stocktakes/[id]/review/page.tsx
// 差异复核 + 过账页(桌面向)。只对 open 盘点单有意义,否则跳回详情页。
// 差异按【当前剩余】实时重算(与 post_stocktake 的口径一致):只列 delta ≠ 0 的行。
import Link from 'next/link'
import { notFound, redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { qtyDelta, roundQty, formatSigned } from '../../delta'
import PostButton from './PostButton'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ReviewDiffTable, { type ReviewDiffRow } from './ReviewDiffTable'

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type BatchFetchRow = {
    id: string
    code: string
    remaining_qty: number
    unit: string
    materials: { name: string } | null
}

export default async function StocktakeReviewPage({
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

    const [stRes, linesRes, inboundRes, outputRes] = await Promise.all([
        supabase
            .from('stocktakes')
            .select('id, code, status, deleted_at')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('stocktake_lines')
            .select('*')
            .eq('stocktake_id', id),
        supabase
            .from('inbound_batches')
            .select('id, code, remaining_qty, unit, materials ( name )')
            .is('deleted_at', null),
        supabase
            .from('output_batches')
            .select('id, code, remaining_qty, unit, materials ( name )')
            .is('deleted_at', null),
    ])

    if (stRes.error || !stRes.data) {
        notFound()
    }

    const st = stRes.data
    if (st.status !== 'open') {
        redirect(`/stocktakes/${id}`)
    }

    if (linesRes.error || inboundRes.error || outputRes.error) {
        const err = linesRes.error ?? inboundRes.error ?? outputRes.error
        return (
            <div className="p-8 max-w-3xl">
                <h1 className="text-2xl font-bold mb-4">{t('stocktakes.reviewTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('stocktakes.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const lines = mustRows(linesRes)
    const inbound = (inboundRes.data as unknown as BatchFetchRow[] | null) ?? []
    const output = (outputRes.data as unknown as BatchFetchRow[] | null) ?? []
    const inboundById = new Map(inbound.map((b) => [b.id, b]))
    const outputById = new Map(output.map((b) => [b.id, b]))

    // 实时差异:实点 − 当前剩余(批次已删的行 delta 为 null —— 过账时 DB 会以 BATCH_DELETED 拦下)
    const rows = lines.map((l) => {
        const side = l.inbound_batch_id ? ('inbound' as const) : ('output' as const)
        const batch = l.inbound_batch_id
            ? inboundById.get(l.inbound_batch_id)
            : outputById.get(l.output_batch_id as string)
        return {
            side,
            batchId: (l.inbound_batch_id ?? l.output_batch_id) as string,
            code: batch?.code ?? '—',
            material: batch?.materials?.name ?? '—',
            current: batch?.remaining_qty ?? null,
            unit: batch?.unit ?? '',
            counted: l.counted_qty,
            delta: batch ? qtyDelta(l.counted_qty, batch.remaining_qty) : null,
        }
    })

    const diffRows = rows.filter((r) => r.delta !== null && r.delta !== 0)
    const totalDelta = roundQty(diffRows.reduce((sum, r) => sum + (r.delta ?? 0), 0))

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ state 恒为 'ok' —— 返回链接、汇总条、reviewNote 与 PostButton(过账)
    //   都必须在【没有任何差异】时照样出现:没有差异正是最常见的、也是最该
    //   放心过账的情形。差异表自己那句"没有差异"由页面在表位置上说。
    const diffTableRows: ReviewDiffRow[] = diffRows.map((r) => ({
        key: `${r.side}:${r.batchId}`,
        side: r.side,
        batchId: r.batchId,
        code: r.code,
        material: r.material,
        current: `${r.current} ${r.unit}`,
        counted: `${r.counted} ${r.unit}`,
        deltaLabel: formatSigned(r.delta ?? 0),
        deltaPositive: (r.delta ?? 0) > 0,
    }))

    return (
        <ListPage
            title={t('stocktakes.reviewTitle')}
            maxWidth="max-w-3xl"
            notices={
                <>
                    <div className="mb-6">
                        <Link href={`/stocktakes/${id}`} className="text-blue-600 hover:underline text-sm">
                            ← {t('stocktakes.backToCount')}
                        </Link>
                    </div>
                    <p className="text-sm text-gray-600 mb-6">
                        <span className="font-mono">{st.code}</span>
                    </p>
                    {/* 汇总:已录行数 · 差异行数 · 差异合计 */}
                    <div className="bg-gray-50 rounded p-4 mb-4 text-sm">
                        {t('stocktakes.reviewSummary', {
                            counted: rows.length,
                            diffs: diffRows.length,
                            delta: formatSigned(totalDelta),
                        })}
                    </div>
                </>
            }
            state={{ kind: 'ok' }}
        >
            {diffRows.length > 0 ? (
                <div className="mb-4">
                    <ReviewDiffTable rows={diffTableRows} />
                </div>
            ) : (
                <div className="bg-gray-50 rounded p-4 mb-4 text-sm text-gray-600">
                    {t('stocktakes.noDiffs')}
                </div>
            )}

            <p className="text-sm text-gray-600 mb-4">{t('stocktakes.reviewNote')}</p>

            <PostButton stocktakeId={id} subject={st.code} />
        </ListPage>
    )
}

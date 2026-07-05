import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditInboundForm from './EditInboundForm'
import MetalContentPanel from '@/app/components/metals/MetalContentPanel'
import type { MetalContentRow } from '@/app/components/metals/metalContentTypes'
import { saveInboundMetal, deleteInboundMetal } from '@/app/components/metals/metalContentActions'
import MovementTimeline from '@/app/components/inventory/MovementTimeline'
import type { MovementRow } from '@/app/components/inventory/movementTypes'
import StocktakeQuickCount from '@/app/stocktakes/StocktakeQuickCount'
import { getTranslations, getLocale } from '@/lib/i18n/server'

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type MovementFetchRow = {
    id: string
    movement_type: string
    qty_delta: number
    business_date: string | null
    notes: string | null
    occurred_at: string
    processing_runs: { id: string; code: string } | null
}

export default async function EditInboundPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const [batchRes, materialsRes, suppliersRes, metalsRes, movementsRes, stocktakeRes] = await Promise.all([
        supabase
            .from('inbound_batches')
            .select('*')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('suppliers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('inbound_batch_metals')
            .select('metal, content_pct, updated_at')
            .eq('inbound_batch_id', id)
            .order('metal'),
        supabase
            .from('inventory_movements')
            .select('id, movement_type, qty_delta, business_date, notes, occurred_at, run_id, processing_runs ( id, code )')
            .eq('inbound_batch_id', id)
            .order('occurred_at', { ascending: false }),
        // 进行中的盘点(最新一张):有则在顶部渲染"扫码即点"横幅
        supabase
            .from('stocktakes')
            .select('id, code')
            .eq('status', 'open')
            .is('deleted_at', null)
            .order('created_at', { ascending: false })
            .limit(1),
    ])

    if (batchRes.error || !batchRes.data) {
        notFound()
    }

    if (materialsRes.error || suppliersRes.error) {
        const err = materialsRes.error ?? suppliersRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('inbound.editTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inbound.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const batch = batchRes.data

    // 本批在进行中盘点里的已录实点数(有则预填横幅)
    const openStocktake = stocktakeRes.data?.[0] ?? null
    let stocktakeCounted: number | null = null
    if (openStocktake) {
        const { data: countLine } = await supabase
            .from('stocktake_lines')
            .select('counted_qty')
            .eq('stocktake_id', openStocktake.id)
            .eq('inbound_batch_id', id)
            .maybeSingle()
        stocktakeCounted = countLine?.counted_qty ?? null
    }

    // 金属含量行:服务端预格式化 updated_at,避免客户端水合不一致
    const metalRows: MetalContentRow[] = (metalsRes.data ?? []).map((m) => ({
        metal: m.metal,
        content_pct: m.content_pct,
        updated_at_display: new Date(m.updated_at).toLocaleString(dateLocale),
    }))

    // 库存流水行:服务端预格式化 occurred_at
    const movementRows: MovementRow[] = ((movementsRes.data as unknown as MovementFetchRow[] | null) ?? []).map((m) => ({
        id: m.id,
        movement_type: m.movement_type,
        qty_delta: m.qty_delta,
        business_date: m.business_date,
        notes: m.notes,
        occurred_at_display: new Date(m.occurred_at).toLocaleString(dateLocale),
        run: m.processing_runs,
    }))

    return (
        <div className="p-4 sm:p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/inbound"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-xl sm:text-2xl font-bold mb-2">{t('inbound.editTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{batch.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {batch.status}
                </span>
                <a
                    href={`/inbound/${batch.id}/label`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="ml-3 text-blue-600 hover:underline"
                >
                    {t('batchLabel.print')}
                </a>
            </p>

            {openStocktake && (
                <StocktakeQuickCount
                    stocktakeId={openStocktake.id}
                    stocktakeCode={openStocktake.code}
                    side="inbound"
                    batchId={batch.id}
                    counted={stocktakeCounted}
                />
            )}

            <EditInboundForm
                batch={batch}
                materials={materialsRes.data ?? []}
                suppliers={suppliersRes.data ?? []}
            />

            <MetalContentPanel
                rows={metalRows}
                saveAction={saveInboundMetal.bind(null, id)}
                deleteAction={deleteInboundMetal.bind(null, id)}
            />

            <MovementTimeline rows={movementRows} unit={batch.unit} />
        </div>
    )
}

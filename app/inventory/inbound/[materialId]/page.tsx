// app/inventory/inbound/[materialId]/page.tsx
// 库存钻取:某物料的在库进料批次(未软删 + remaining_qty > 0),按 remaining_qty 降序。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { STAGE_OPTIONS, labelKeyForValue } from '@/app/inbound/options'
import { getTranslations } from '@/lib/i18n/server'

type Row = {
    id: string
    code: string
    quantity: number
    remaining_qty: number
    unit: string
    stage: string
    arrival_date: string | null
    suppliers: { legal_name: string } | null
}

export default async function InboundDrillPage({
    params,
}: {
    params: Promise<{ materialId: string }>
}) {
    const { materialId } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const [matRes, batchesRes] = await Promise.all([
        supabase.from('materials').select('name').eq('id', materialId).single(),
        supabase
            .from('inbound_batches')
            .select('id, code, quantity, remaining_qty, unit, stage, arrival_date, suppliers ( legal_name )')
            .eq('material_id', materialId)
            .is('deleted_at', null)
            .gt('remaining_qty', 0)
            .order('remaining_qty', { ascending: false }),
    ])

    if (matRes.error || !matRes.data) {
        notFound()
    }

    const rows = (batchesRes.data as unknown as Row[] | null) ?? []
    const total = rows.reduce((s, r) => s + r.remaining_qty, 0)
    const stageLabel = (v: string) => {
        const k = labelKeyForValue(STAGE_OPTIONS, v)
        return k ? t(k) : v
    }

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/inventory" className="text-blue-600 hover:underline text-sm">
                    {t('inventory.drill.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-4">
                {matRes.data.name} · {t('inventory.drill.title')}
            </h1>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colSupplier')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colQuantity')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colRemaining')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colStage')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.colArrivalDate')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link href={`/inbound/${r.id}/edit`} className="text-blue-600 hover:underline">
                                    {r.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.suppliers?.legal_name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{r.quantity} {r.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{r.remaining_qty} {r.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">{stageLabel(r.stage)}</span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.arrival_date ?? '—'}</td>
                        </tr>
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={6} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('inventory.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            <p className="text-sm mt-3">
                <span className="text-gray-600 mr-1">{t('inventory.drill.sumLabel')}:</span>
                <span className="font-mono">{total}</span>
            </p>
        </div>
    )
}

// app/processing/wip/page.tsx
// PROC-WIRE-1B-ii(R3):在制品 —— 什么在等、多少、等哪一道工序。
//
// ★【没有 WIP 表,这一页读的是一个【投影】】★ 在制品那一行就是 output_batches
// 里那一行(PROC-WIRE-1A 立的:purpose_code = 'process_feed' 的产出批就是在制品)。
// 再建一张表会把同一批料数两遍,而两处迟早各说各话 —— R3 明写"不需要新对象"。
//
// 【为什么这一页在【加工】模块下,而不是在产出批次列表里】它回答的是产线的问题
// ("下一炉该跑什么"),不是库存的问题。视图的谓词也挂在 module.processing.view 上。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../Subnav'

export default async function WipPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const rows = mustRows(
        await supabase.from('processing_wip')
            .select('output_batch_id, batch_code, material_code, material_name, remaining_qty, unit, awaiting_operation_type_code, awaiting_operation_zh, awaiting_operation_en, safety_states_recorded')
            .order('batch_code'),
        'processing_wip') as {
            output_batch_id: string; batch_code: string
            material_code: string | null; material_name: string | null
            remaining_qty: number; unit: string
            awaiting_operation_type_code: string | null
            awaiting_operation_zh: string | null; awaiting_operation_en: string | null
            safety_states_recorded: number }[]

    return (
        <>
            <Subnav />
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-2">{t('processing.wip.title')}</h1>
                <p className="text-sm text-gray-600 mb-4">{t('processing.wip.note')}</p>

                <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.wip.colBatch')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.wip.colMaterial')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('processing.wip.colQty')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.wip.colAwaiting')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.wip.colSafety')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => (
                                <tr key={r.output_batch_id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        <Link href={`/output/${r.output_batch_id}/edit`}
                                              className="text-blue-600 hover:underline">{r.batch_code}</Link>
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {r.material_code ?? '—'}{r.material_name ? ` · ${r.material_name}` : ''}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {r.remaining_qty} {r.unit}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {/* 【没排到具体工序就说"还没决定",不画成一道工序】
                                            空是一个答案 —— 而且它【不是】"不适用":这一批仍然是在制品。 */}
                                        {r.awaiting_operation_type_code
                                            ? (locale === 'zh' ? r.awaiting_operation_zh : r.awaiting_operation_en)
                                              ?? r.awaiting_operation_type_code
                                            : <span className="text-gray-500 italic">{t('processing.wip.notScheduled')}</span>}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {/* ★ 0 = 没有人记过,不是"安全" —— 而且这一批因此【投不进去】。
                                            把它画成一个安静的 0,就是把那道拒绝藏起来等操作员去撞。 */}
                                        {r.safety_states_recorded === 0
                                            ? <span className="text-amber-700">{t('processing.wip.noSafetyState')}</span>
                                            : <span className="text-gray-600">{t('processing.wip.safetyRecorded', { n: String(r.safety_states_recorded) })}</span>}
                                    </td>
                                </tr>
                            ))}
                            {rows.length === 0 && (
                                <tr>
                                    <td colSpan={5} className="border border-gray-300 px-4 py-6 text-center text-gray-500">
                                        {t('processing.wip.empty')}
                                    </td>
                                </tr>
                            )}
                        </tbody>
                    </table>
                </div>
            </div>
        </>
    )
}

import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import DeleteButton from './DeleteButton'

// FK 嵌入运行时是对象(包括两层嵌套);显式类型 + cast 锁住。
type ProcessingInputRow = {
    id: string
    quantity_consumed: number
    inbound_batches: {
        id: string
        code: string
        unit: string
        deleted_at: string | null
        materials: { name: string } | null
    } | null
}

type ProcessingOutputRow = {
    id: string
    quantity_produced: number
    output_batches: {
        id: string
        code: string
        unit: string
        purity: string | null
        deleted_at: string | null
        materials: { name: string } | null
    } | null
}

export default async function ProcessingDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()

    const [runRes, inputsRes, outputsRes] = await Promise.all([
        supabase
            .from('processing_runs')
            .select('*')
            .eq('id', id)
            .is('deleted_at', null)
            .single(),
        supabase
            .from('processing_inputs')
            .select('id, quantity_consumed, inbound_batches ( id, code, unit, deleted_at, materials ( name ) )')
            .eq('run_id', id)
            .order('created_at'),
        supabase
            .from('processing_outputs')
            .select('id, quantity_produced, output_batches ( id, code, unit, purity, deleted_at, materials ( name ) )')
            .eq('run_id', id)
            .order('created_at'),
    ])

    if (runRes.error || !runRes.data) {
        notFound()
    }

    if (inputsRes.error || outputsRes.error) {
        const err = inputsRes.error ?? outputsRes.error
        return (
            <div className="p-8 max-w-3xl">
                <h1 className="text-2xl font-bold mb-4">加工单详情</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">读取投入/产出明细失败</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const run = runRes.data
    const inputs = inputsRes.data as unknown as ProcessingInputRow[] | null
    const outputs = outputsRes.data as unknown as ProcessingOutputRow[] | null

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link
                    href="/processing"
                    className="text-blue-600 hover:underline text-sm"
                >
                    ← 返回列表
                </Link>
            </div>

            <div className="flex items-start justify-between mb-6">
                <div>
                    <h1 className="text-2xl font-bold mb-2">加工单详情</h1>
                    <p className="text-sm text-gray-600">
                        <span className="font-mono">{run.code}</span>
                        <span className="mx-2">·</span>
                        <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                            {run.status}
                        </span>
                    </p>
                </div>
                <DeleteButton runId={run.id} />
            </div>

            <div className="space-y-6">
                {/* 概况 */}
                <div className="bg-gray-50 rounded p-4">
                    <div className="grid grid-cols-2 gap-x-6 gap-y-2 text-sm">
                        <div>
                            <span className="text-gray-600">加工日期:</span>{' '}
                            {run.process_date ?? '—'}
                        </div>
                        <div>
                            <span className="text-gray-600">投入合计:</span>{' '}
                            {run.total_input ?? '—'}
                        </div>
                        <div>
                            <span className="text-gray-600">产出合计:</span>{' '}
                            {run.total_output ?? '—'}
                        </div>
                        <div>
                            <span className="text-gray-600">损耗:</span>{' '}
                            {run.loss_qty ?? '—'}
                            {run.loss_qty != null && run.total_input
                                ? ` (${((run.loss_qty / run.total_input) * 100).toFixed(1)}%)`
                                : ''}
                        </div>
                    </div>
                    {run.notes && (
                        <div className="mt-3 pt-3 border-t border-gray-200 text-sm">
                            <span className="text-gray-600">备注:</span> {run.notes}
                        </div>
                    )}
                </div>

                {/* 投入 */}
                <section>
                    <h2 className="text-lg font-semibold mb-2">投入(消耗进料)</h2>
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">进料批次</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">物料</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">消耗数量</th>
                            </tr>
                        </thead>
                        <tbody>
                            {inputs?.map((leg) => (
                                <tr key={leg.id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {!leg.inbound_batches ? (
                                            '—'
                                        ) : leg.inbound_batches.deleted_at ? (
                                            <span className="text-gray-500">
                                                {leg.inbound_batches.code}（已删除）
                                            </span>
                                        ) : (
                                            <Link
                                                href={`/inbound/${leg.inbound_batches.id}/edit`}
                                                className="text-blue-600 hover:underline"
                                            >
                                                {leg.inbound_batches.code}
                                            </Link>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.inbound_batches?.materials?.name ?? '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.quantity_consumed} {leg.inbound_batches?.unit ?? ''}
                                    </td>
                                </tr>
                            ))}
                            {(!inputs || inputs.length === 0) && (
                                <tr>
                                    <td
                                        colSpan={3}
                                        className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                    >
                                        没有投入记录
                                    </td>
                                </tr>
                            )}
                        </tbody>
                    </table>
                </section>

                {/* 产出 */}
                <section>
                    <h2 className="text-lg font-semibold mb-2">产出(生成成品)</h2>
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">产出批次</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">物料</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">产出数量</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">品位</th>
                            </tr>
                        </thead>
                        <tbody>
                            {outputs?.map((leg) => (
                                <tr key={leg.id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {!leg.output_batches ? (
                                            '—'
                                        ) : leg.output_batches.deleted_at ? (
                                            <span className="text-gray-500">
                                                {leg.output_batches.code}（已删除）
                                            </span>
                                        ) : (
                                            <Link
                                                href={`/output/${leg.output_batches.id}/edit`}
                                                className="text-blue-600 hover:underline"
                                            >
                                                {leg.output_batches.code}
                                            </Link>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.output_batches?.materials?.name ?? '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.quantity_produced} {leg.output_batches?.unit ?? ''}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {leg.output_batches?.purity ?? '—'}
                                    </td>
                                </tr>
                            ))}
                            {(!outputs || outputs.length === 0) && (
                                <tr>
                                    <td
                                        colSpan={4}
                                        className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                    >
                                        没有产出记录
                                    </td>
                                </tr>
                            )}
                        </tbody>
                    </table>
                </section>
            </div>
        </div>
    )
}

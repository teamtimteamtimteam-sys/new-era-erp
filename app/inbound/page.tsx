// app/inbound/page.tsx
// 进料批次列表页(只读)
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'

export default async function InboundPage() {
    const supabase = await createClient()

    // 嵌入外键:materials 和 suppliers 通过 material_id / supplier_id 关联
    const { data: batches, error } = await supabase
        .from('inbound_batches')
        .select(`
            id, code, quantity, unit, remaining_qty, arrival_date, stage, status, created_at,
            materials ( name ),
            suppliers ( legal_name )
        `)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    // 注意:Supabase 把 M:1 嵌入资源有时推断为对象,有时为数组。
    // 如果 TS 报错说 b.materials / b.suppliers 是数组,把下面的
    //   b.materials?.name      改成   b.materials?.[0]?.name
    //   b.suppliers?.legal_name 改成  b.suppliers?.[0]?.legal_name

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">Inbound</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">读取失败</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">进料批次 (Inbound)</h1>
                <Link
                    href="/inbound/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    + 新增进料
                </Link>
            </div>
            <p className="text-sm text-gray-600 mb-4">
                共 {batches?.length ?? 0} 条记录
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">Code</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">物料</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">供应商</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">数量</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">剩余</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">到货日期</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">阶段</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Status</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">操作</th>
                    </tr>
                </thead>
                <tbody>
                    {batches?.map((b) => (
                        <tr key={b.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/inbound/${b.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {b.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{b.materials?.name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.suppliers?.legal_name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.quantity} {b.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.remaining_qty} {b.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">{b.arrival_date ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {b.stage}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {b.status}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={b.id} code={b.code} />
                            </td>
                        </tr>
                    ))}
                    {(!batches || batches.length === 0) && (
                        <tr>
                            <td
                                colSpan={9}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                还没有进料批次
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}

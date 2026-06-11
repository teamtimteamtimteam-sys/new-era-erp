// app/materials/page.tsx
// 物料字典列表页(只读)
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'

export default async function MaterialsPage() {
    const supabase = await createClient()

    const { data: materials, error } = await supabase
        .from('materials')
        .select('id, code, name, category, chemistry, unit, status, created_at')
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">Materials</h1>
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
                <h1 className="text-2xl font-bold">Materials (物料字典)</h1>
                <Link
                    href="/materials/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    + 新增物料
                </Link>
            </div>
            <p className="text-sm text-gray-600 mb-4">
                共 {materials?.length ?? 0} 条记录
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">Code</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">名称</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">类别</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">化学体系</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">单位</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Status</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">Created</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">操作</th>
                    </tr>
                </thead>
                <tbody>
                    {materials?.map((m) => (
                        <tr key={m.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/materials/${m.id}/edit`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {m.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{m.name}</td>
                            <td className="border border-gray-300 px-4 py-2">{m.category}</td>
                            <td className="border border-gray-300 px-4 py-2">{m.chemistry ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{m.unit}</td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                    {m.status}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {new Date(m.created_at).toLocaleString('zh-CN')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <DeleteButton id={m.id} name={m.name} />
                            </td>
                        </tr>
                    ))}
                    {(!materials || materials.length === 0) && (
                        <tr>
                            <td
                                colSpan={8}
                                className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                            >
                                还没有物料数据
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}

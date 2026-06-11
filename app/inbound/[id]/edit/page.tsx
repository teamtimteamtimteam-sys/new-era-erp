import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditInboundForm from './EditInboundForm'

export default async function EditInboundPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()

    const [batchRes, materialsRes, suppliersRes] = await Promise.all([
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
    ])

    if (batchRes.error || !batchRes.data) {
        notFound()
    }

    if (materialsRes.error || suppliersRes.error) {
        const err = materialsRes.error ?? suppliersRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">编辑进料</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">读取下拉框数据失败</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const batch = batchRes.data

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/inbound"
                    className="text-blue-600 hover:underline text-sm"
                >
                    ← 返回列表
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">编辑进料</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{batch.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {batch.status}
                </span>
            </p>

            <EditInboundForm
                batch={batch}
                materials={materialsRes.data ?? []}
                suppliers={suppliersRes.data ?? []}
            />
        </div>
    )
}

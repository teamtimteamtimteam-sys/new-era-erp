// app/output/new/page.tsx
// 服务端组件:抓取下拉框所需的物料/客户列表,再渲染客户端表单
import { createClient } from '@/lib/supabase/server'
import NewOutputForm from './NewOutputForm'

export default async function NewOutputPage() {
    const supabase = await createClient()

    const [materialsRes, customersRes] = await Promise.all([
        supabase
            .from('materials')
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('customers')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
    ])

    if (materialsRes.error || customersRes.error) {
        const err = materialsRes.error ?? customersRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">新增产出</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">读取下拉框数据失败</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <NewOutputForm
            materials={materialsRes.data ?? []}
            customers={customersRes.data ?? []}
        />
    )
}

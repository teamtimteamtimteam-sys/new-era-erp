// app/output/new/page.tsx
// 服务端组件:抓取下拉框所需的物料/客户列表,再渲染客户端表单
import { createClient } from '@/lib/supabase/server'
import NewOutputForm from './NewOutputForm'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewOutputPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.output)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [materialsRes, customersRes] = await Promise.all([
        supabase
            .from('material_lookup')   // FIX-1 item 3:查名视图,见迁移 2026-09-05-fix1
            .select('id, code, name')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('customer_lookup')   // FIX-1 item 3:查名视图,见迁移 2026-09-05-fix1
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
    ])

    if (materialsRes.error || customersRes.error) {
        const err = materialsRes.error ?? customersRes.error
        return (
            <div className="p-8 max-w-2xl">
                <h1 className="text-2xl font-bold mb-4">{t('output.newTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('output.dropdownLoadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // IOD-1b:收货库位的可选清单 —— 只列在用库位(便利);停用/不存在由
    // resolve_receipt_location 在函数里点名拒,下拉挡不住直接调 RPC 的人。
    const locationChoices = mustRows(
        await supabase.from('storage_locations').select('id, code, name').eq('is_active', true).order('code'),
        'storage_locations'
    ) as unknown as { id: string; code: string; name: string }[]

    return (
        <NewOutputForm
            locations={locationChoices}
            materials={mustRows(materialsRes) as unknown as { id: string; code: string; name: string }[]}
            customers={mustRows(customersRes) as unknown as { id: string; code: string; legal_name: string }[]}
        />
    )
}

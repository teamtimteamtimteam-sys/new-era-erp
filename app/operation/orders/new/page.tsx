// app/operation/orders/new/page.tsx
// WO-1c:新建工单。服务端取物料清单,渲染客户端表单。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import NewWorkOrderForm from './NewWorkOrderForm'

export default async function NewWorkOrderPage() {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const supabase = await createClient()
    // ROLE-1 Batch 3b:仓库持 processing.view 但不持 materials.view —— 读 materials 基表会被 RLS 静默
    // 读成零行(下拉全空)。改读查名视图 material_lookup(processing.view 读得到),列与过滤不变。
    const materials = mustRows(
        await supabase.from('material_lookup').select('id, code, name')
            .is('deleted_at', null).order('code'),
        'material_lookup') as unknown as { id: string; code: string; name: string }[]
    const canCreate = await can('action.wo_create')

    return (
        <>
            <NewWorkOrderForm materials={materials} canCreate={canCreate} />
        </>
    )
}

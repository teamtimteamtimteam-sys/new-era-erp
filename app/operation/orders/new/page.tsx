// app/operation/orders/new/page.tsx
// WO-1c:新建工单。服务端取物料清单,渲染客户端表单。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import NewWorkOrderForm from './NewWorkOrderForm'

export default async function NewWorkOrderPage() {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const supabase = await createClient()
    const materials = mustRows(
        await supabase.from('materials').select('id, code, name')
            .is('deleted_at', null).order('code'),
        'materials') as unknown as { id: string; code: string; name: string }[]

    return (
        <>
            <NewWorkOrderForm materials={materials} />
        </>
    )
}

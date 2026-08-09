// app/hr/leave/types/page.tsx
// 假别配置。天数、证明门槛、启用与否都是【数据】—— 改它们不该需要发版。
// code 一列只读:策略与历史记录都靠它认这个假别。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import LeaveSubnav from '../LeaveSubnav'
import LeaveTypesEditor, { type LeaveTypeRow } from './LeaveTypesEditor'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function LeaveTypesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const res = await supabase.from('leave_types').select('*').order('sort_order')
    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <LeaveSubnav />
            <p className="text-sm text-gray-600 mb-4">{t('leave.typesIntro')}</p>
            <LeaveTypesEditor rows={mustRows(res) as LeaveTypeRow[]} />
        </div>
    )
}

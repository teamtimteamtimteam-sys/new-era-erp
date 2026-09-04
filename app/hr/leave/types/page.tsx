// app/hr/leave/types/page.tsx
// 假别配置。天数、证明门槛、启用与否都是【数据】—— 改它们不该需要发版。
// code 一列只读:策略与历史记录都靠它认这个假别。
//
// CONV-2:外壳换成 CONV-1 的 <ListPage>。
// ★【为什么 LeaveSubnav 走 notices 槽】外壳只在 state.kind === 'ok' 时画 children,
//   而这张假别表是【可能空的】。子导航一旦进了 children,空态那一支会把它一起吃掉,
//   人就被留在一张没有出口的空页上 —— 与 CONV-1 在 /sales/commissions 撞见的
//   「无条件提示被静默吃掉」是**同一个缺陷的第二种出口**。
//   notices 是外壳里唯一画在状态分支【之前】的槽,所以子导航暂时走它。
//   ☞ 这是一处**记在文档里的将就**:一条子导航不是一句 notice。见
//     docs/editable-grid-template.md §⑥。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import LeaveSubnav from '../LeaveSubnav'
import LeaveTypesEditor, { type LeaveTypeRow } from './LeaveTypesEditor'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

export default async function LeaveTypesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const res = await supabase.from('leave_types').select('*').order('sort_order')
    const rows = mustRows(res) as LeaveTypeRow[]

    return (
        <ListPage
            title={t('hr.title')}
            intro={t('leave.typesIntro')}
            maxWidth="max-w-6xl"
            notices={<LeaveSubnav />}
            state={
                rows.length === 0
                    // 【空态是一句说得出口的话】假别表空,意思是这套系统还不知道
                    // 任何一种假 —— 那不是"查出来是空的",是配置还没有做。
                    ? { kind: 'empty', noRows: t('leave.noTypes') }
                    : { kind: 'ok' }
            }
        >
            <LeaveTypesEditor rows={rows} />
        </ListPage>
    )
}

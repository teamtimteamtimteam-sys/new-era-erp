// app/operation/page.tsx
// 【运营的落地页】—— NAV-CLEANUP-1 ③。
//
// ★【为什么这个模块需要一页新的】★ 运营此前【根本没有模块根】:它的地址全是
// /operation/processing/*,而 /operation/processing 自己是二级条目「加工单」。于是一级叫「运营」、
// 地址却叫 processing,而那个地址还【已经是】另一样东西。
// 本刀把四个区搬到 /operation/{processing,orders,wip,handovers},
// 这一页成为那个空出来的模块根。
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import ModuleLanding from '@/app/components/nav/ModuleLanding'

export default async function OperationLandingPage() {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied
    return <ModuleLanding moduleId="operation" titleKey="nav.operation" selfHref="/operation" />
}

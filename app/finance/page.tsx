// app/finance/page.tsx
// 【财务的落地页】—— NAV-CLEANUP-1 ③。
//
// ★【这一页从前【是】试算平衡,现在不是了】★
// Tim:/finance 打开就是试算平衡,而试算平衡是财务 31 条里的【一条】,
// 不是这个模块本身。它已经搬到 /finance/trial-balance,在菜单的「报表」组里
// 与损益、资产负债表并列 —— 它现在和它的同类站在一起。
// 【没有重定向垫片】这一刀不留 shim:一次重定向会把任何一处没改到的内链
// 【悄悄吸收掉】,而那正是本刀要消灭的那一类缺陷。改不干净就让它红,
// 由 scripts/check-retired-paths.mjs 在构建期点名文件与行。
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import ModuleLanding from '@/app/components/nav/ModuleLanding'

export default async function FinanceLandingPage() {
    const denied = await requireFunction(FN.financeHome)
    if (denied) return denied
    return <ModuleLanding moduleId="finance" titleKey="nav.finance" selfHref="/finance" />
}

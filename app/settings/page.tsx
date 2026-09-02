// app/settings/page.tsx
// 【设置的落地页】—— NAV-CLEANUP-1 ④。
//
// ★【它补上的是 Tim 点名的那条不连贯】★ 设置此前没有模块根,而它名下有一条
// 【也叫「设置」】的二级条目(指向账号页),于是面包屑读作「设置 › 设置 › 角色」。
// 拍平之后每一条都是 /settings/<一个词>,而这一页是那个模块根。
//
// 【判据取 action.manage_permissions,不是一个并集】理由写在 lib/modules.ts
// 那一条上:写并集就是把"模块可进性"定义第二遍。代价照直说 —— 一个只持字典
// 编辑权的人进得去设置,但这一条对他写着「· 受限」。那是 D5 要的样子。
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import ModuleLanding from '@/app/components/nav/ModuleLanding'

export default async function SettingsLandingPage() {
    const denied = await requireFunction(FN.settingsHome)
    if (denied) return denied
    return <ModuleLanding moduleId="settings" titleKey="nav.settings" selfHref="/settings" />
}

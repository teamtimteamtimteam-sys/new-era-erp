// app/settings/approvals/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// 【审批链】—— IA-BUILD-1 / D7:从 /finance/settings 搬到设置,把关码跟着一起搬:
//     module.finance.view  →  action.manage_permissions
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【必须照直说的一件事,而且它更正了 Tim 自己写下的一句话】★★
// D7 的裁定里写着"配置审批链从此是系统管理员的事,而不是财务的事",并接受了
// 「Choo-er TEH 不再配置她自己是一级审批人的那条链」这个后果。
// **实测:那句话的后半在这一刀之后仍然不成立 —— 因为它本来就不成立。**
//
//   * 这块面板是【只读】的,它自己的抬头写着为什么(打开审批要同时配齐三个值,
//     其中两个是业务决定,所以不给一个按下去就会被拒的按钮);
//   * `app/` 底下【没有任何东西】写 approvals_enabled / approval_level1_role_code /
//     approval_level2_role_code / approval_threshold_base 这四列 ——
//     app/finance/settings/actions.ts 只导出一个 setPeriodLock;
//   * 线上那一行(enabled=false · level1=finance · level2=cfo · threshold=1000)
//     是【直接改库】改出来的。
//
// 所以本刀搬走的是【那扇窗】,不是一个控制器:在这之后,配置审批链仍然【不是
// 任何人在界面上做的事】。Tim 已确认按这个措辞记录(A1),并把
// 「审批链没有配置界面」记成一条排队事项 —— 触发点是同事测试轮要试审批,
// 而今天开启审批 = 一次数据库操作 + Choo-er TEH 的邮箱确认。
//
// 【谁因此少看见了东西 —— 这一条是真的有人受影响】
//   之前:任何持 module.finance.view 的人(admin · gm · finance · auditor · cfo)
//   之后:持 action.manage_permissions 的人(**live 只有 admin**)
//   → gm · finance · auditor · cfo 看不到这块只读状态面板了。
//   live 的真人:finance 一名、cfo 一名 —— 两位都受影响,逐角色表见
//   docs/information-architecture.md。**这正是 Tim 要的那条分离。**
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import ApprovalsPanel from './ApprovalsPanel'

export default async function ApprovalsSettingsPage() {
    // 【判据来自注册表,不写在这一页里】—— 与入口用的是同一条 FN.approvals,
    // 所以"谁看得见这个入口"与"谁进得去这一页"不可能各错一次(NAV-REG-1 的 3d)。
    const denied = await requireFunction(FN.approvals)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // SOD-1:审批开关的状态,以及"能不能开"。屏幕与闸读【同一份判据】。
    const readinessRes = await supabase.rpc('approvals_readiness')

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('finance.approvals.title')}</h1>
            {/* 【读失败不许读成"没有面板"】一块悄悄消失的面板,与一块说"审批未生效"
                的面板在屏幕上长得一模一样 —— 而后者是一句关于内控的断言。 */}
            {readinessRes.error ? (
                <p className="text-sm text-red-700 bg-red-50 border border-red-300 rounded px-3 py-2 mb-6">
                    {t('finance.approvals.readError')}
                </p>
            ) : (
                <ApprovalsPanel r={readinessRes.data as never} />
            )}
            {/* ★ 把"这里没有配置控件"写在屏幕上,而不是只写在注释里 ★
                一块只读的状态面板,与一块"控件坏了/我没权限"的面板长得一样。
                来这里想改审批链的人必须读到:今天这件事不在界面上做。 */}
            <p className="mt-6 max-w-2xl text-sm text-gray-700 bg-amber-50 border border-amber-200 rounded px-3 py-2">
                {t('finance.approvals.noConfigUi')}
            </p>
        </div>
    )
}

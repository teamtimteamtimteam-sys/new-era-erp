// app/settings/approvals/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// 【审批链】—— IA-BUILD-1 / D7:从 /finance/settings 搬到设置,把关码跟着一起搬:
//     module.finance.view  →  action.manage_permissions
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【APR-1(2026-09-22):这一页从此【有写路径】—— 上面那段历史因此要改口】★★
// D7 的时候这块面板是只读的,而这个文件抬头曾经逐字记着:
//   「app/ 底下没有任何东西写那四列」「配置审批链仍然不是任何人在界面上做的事」。
// **那两句今天不成立了,而它们正是本刀做掉的那件事。** 留着它们比删掉更坏 ——
// 一句留在代码里的过期断言,下一个读的人会当成前提去推理(docs/approvals.md §3
// 刚刚为完全相同的形状付过一次账:一条写下来的到期条件成真了三个星期没人发现)。
//
// 【这一页现在做三件事】
//   ① 读:就绪状态(ApprovalsPanel,原样不动)—— 屏幕与闸读同一份判据;
//   ② 写:四个值一起保存(ApprovalsForm → set_approvals_policy);
//   ③ 留痕:经这块屏幕做过的每一次改动(ApprovalsHistory)。
//      ★ ③ 不是装饰:本刀同时在修"留痕写得进读不出"那条已知问题,
//        新建一张史表却没有任何地方读它,等于当场把同一个形状再造一遍。
//
// 【判据只有一个码 —— 看得见这一页 = 改得动它】(Tim 裁定,Q4)
//   页面的闸是 action.manage_permissions,RPC 的闸【逐字同一个】,
//   approvals_readiness 的内检在本刀也换成了它(N6)。
//   ☞ 于是"只读的观众"这个人今天【不存在】,而这一页把这件事印在屏幕上,
//     不留给人去猜(finance.approvals.seeingIsChanging)。
//
// 【谁看得见 —— 这一条是真的有人受影响,原样留着】
//   持 action.manage_permissions 的人:live 是 admin 与 cco。
//   gm · finance · auditor · cfo 看不到这块面板。**这正是 Tim 要的那条分离** ——
//   而 finance 就是一级审批角色,她不该改得动那条约束她自己的策略。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import ApprovalsPanel from './ApprovalsPanel'
import ApprovalsForm, { type RoleOption } from './ApprovalsForm'
import ApprovalsHistory, { type PolicyChange } from './ApprovalsHistory'
// ★【查询失败必须【失败】,不许读成空】mustRows 抛,`?? []` 不抛 ——
//   而这一页上两处空集各自都有一句【错误的】读法在等着:
//   角色清单读成空 = "系统里没有角色";留痕读成空 = "这条策略从来没有被人动过"。
//   后者正是本刀同时在修的那条已知问题的形状(写得进、读不出、安静的零)。
import { mustRows } from '@/lib/db-helpers'

type Readiness = {
    enabled: boolean
    level1_role_code: string | null
    level2_role_code: string | null
    threshold_base: string | number | null
    pending_purchase_orders: number
    // ★ APR-3:这一页只把它透传给 <ApprovalsPanel>(那里有完整的形状),
    //   自己不读逐链那一块 —— 它要的只有表单那几个值。
    blocking: string[]
    can_enable: boolean
    can_disable: boolean
}

export default async function ApprovalsSettingsPage() {
    // 【判据来自注册表,不写在这一页里】—— 与入口用的是同一条 FN.approvals,
    // 所以"谁看得见这个入口"与"谁进得去这一页"不可能各错一次(NAV-REG-1 的 3d)。
    const denied = await requireFunction(FN.approvals)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // SOD-1:审批开关的状态,以及"能不能开"。屏幕与闸读【同一份判据】。
    const readinessRes = await supabase.rpc('approvals_readiness')

    // 角色清单:下拉框的选项。★ admin / cco 【不】在这里过滤掉 —— §0b 的裁定
    //   有意不做成机器规则,而一个悄悄少了两项的下拉框是同一条规则的隐身版本。
    const roles = mustRows<RoleOption>(await supabase
        .from('roles')
        .select('code, name_en, name_zh, sort_order')
        .eq('is_active', true)
        .is('deleted_at', null), 'roles for the approval policy pickers')

    // 经这块屏幕做过的改动。十条 —— 这是一条一年翻不了几次的策略。
    const historyRows = mustRows<PolicyChange>(await supabase
        .from('finance_settings_history')
        .select('id, changed_at, changed_by, old_approvals_enabled, new_approvals_enabled, old_approval_level1_role_code, new_approval_level1_role_code, old_approval_level2_role_code, new_approval_level2_role_code, old_approval_threshold_base, new_approval_threshold_base')
        .order('changed_at', { ascending: false })
        .limit(10), 'approval policy changes')

    // 谁改的 —— user_directory 的闸【就是】action.manage_permissions,
    // 也就是能看到这一页的那批人,所以这次查询不会为了权限而空手而归。
    const actorIds = Array.from(new Set(
        historyRows.map((r) => r.changed_by).filter((v): v is string => !!v)))
    // user_directory 是一个视图,生成的类型把每一列都标成可空。这里【不】假装
    // user_id 不会是 null —— 拿不到 id 的那一行直接跳过,它认不出是谁。
    type Actor = { user_id: string | null; email: string | null; employee_name: string | null }
    const actors: Actor[] = actorIds.length === 0 ? [] : mustRows<Actor>(
        await supabase.from('user_directory')
            .select('user_id, email, employee_name')
            .in('user_id', actorIds), 'who changed the approval policy')
    const whoByUserId: Record<string, string> = {}
    for (const u of actors) {
        if (!u.user_id) continue
        whoByUserId[u.user_id] = u.employee_name || u.email || u.user_id
    }

    const r = readinessRes.data as Readiness | null

    return (
        <div className="p-8">
            <h1 className="mb-4">{t('finance.approvals.title')}</h1>
            {/* 【读失败不许读成"没有面板"】一块悄悄消失的面板,与一块说"审批未生效"
                的面板在屏幕上长得一模一样 —— 而后者是一句关于内控的断言。
                ★ 写那一半也一并不渲染:不知道现在是什么状态的时候,
                  一个预填好的表单会把【上一次的状态】当成【现在的状态】交上去。 */}
            {readinessRes.error || !r ? (
                <p className="text-sm text-red-700 bg-red-50 border border-red-300 rounded px-3 py-2 mb-6">
                    {t('finance.approvals.readError')}
                </p>
            ) : (
                <>
                    <ApprovalsPanel r={readinessRes.data as never} />
                    <ApprovalsForm
                        enabled={r.enabled}
                        level1RoleCode={r.level1_role_code}
                        level2RoleCode={r.level2_role_code}
                        thresholdBase={r.threshold_base === null ? null : String(r.threshold_base)}
                        roles={[...roles].sort(
                            (a, b) => (a.sort_order - b.sort_order) || a.code.localeCompare(b.code))}
                        canEnable={r.can_enable}
                        canDisable={r.can_disable}
                        blocking={r.blocking ?? []}
                        pendingPurchaseOrders={r.pending_purchase_orders}
                    />
                    <ApprovalsHistory rows={historyRows} whoByUserId={whoByUserId} />
                </>
            )}
            {/* ★ 这一段【不再】说"这里没有配置控件" —— 它现在说的是
                「这就是那块屏幕,而且是唯一的一块」。见 finance.approvals.noConfigUi。 */}
            <p className="mt-6 max-w-2xl text-sm text-[color:var(--brand-text)] bg-amber-50 border border-amber-200 rounded px-3 py-2">
                {t('finance.approvals.noConfigUi')}
            </p>
        </div>
    )
}

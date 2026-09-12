'use client'

// ════════════════════════════════════════════════════════════════════════════
// DBLOCK-1(2026-09-08)· 一个【注定被拒】的控件,在被按之前就要说出为什么
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【它与 action-message.tsx 是两件事,所以它在旁边而不是在里面】★★
//   action-message 报的是【已经发生了的事】—— 你按了,结果是这样。
//   本文件说的是【还没发生的事】—— 你按不了,原因是这个。
//   一个在动作之后,一个在动作之前。合成一个组件会让"结果"和"前提"共用一套措辞,
//   而它们对读的人是完全不同的两句话。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么是"显示 + 解释",而不是"藏起来" —— 这是一次【更正】,要写下来】★★
// ════════════════════════════════════════════════════════════════════════════
//   本刀的委托书原本裁定"不许藏",理由写的是「系统既有的行为就是显示 + 解释」。
//   **那句话管的是导航,不管编辑控件。** 实测(DBLOCK-1,2026-09-08):
//     · 21 个编辑控件、13 个文件**今天就在藏**(`{canEdit && <button>}`);
//     · 而仓库里唯一【写下来】的那条规矩站在藏的那一边 —— AGENTS.md
//       「never render a submit control for an action the server is guaranteed
//        to refuse」,`requireEditPermission` 的 8 张整页拒绝正是它的实现。
//   **也就是说房里有两条规矩,而它们互相矛盾。**
//
//   Tim 在本刀闸上裁定:**显示 + 解释赢**,那条写下来的规矩在同一次提交里改掉,
//   那 21 处一并转过来。理由是他自己的一句话:
//     **「一个藏起来的钮教给人的是【这个功能不存在】;
//        一个看得见、有解释的钮教给人的是【该去要什么】。」**
//
//   ☞ 所以本组件**永远不返回 null,永远不少画一个元素**。
//     谁要在这里加一条"要不要画"的分支,先读 AGENTS.md 那一段的改写理由。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【为什么用 <fieldset disabled>,而不是 cloneElement / inert / pointer-events】★
// ════════════════════════════════════════════════════════════════════════════
//   要挡的 82 个控件有【四种形状】(实测):40 个文件用 <Button>、19 个用
//   <ConfirmButton>、19 个里有 <form>、2 个是裸 <button>。
//   · `cloneElement` 注入 disabled —— 只对单个元素儿子成立,而这里有一半是
//     一整段 JSX(表单 + 若干输入框 + 提交钮)。
//   · `pointer-events-none` —— **只挡鼠标**。键盘 Tab 过去照样回车,
//     那不是"按不动",那是"用鼠标按不动"。
//   · `inert` —— 挡得住,但它把整棵子树**移出无障碍树**:
//     读屏的人于是根本不知道这个控件存在。**那正是"藏起来"的另一种写法。**
//   · **`<fieldset disabled>` 是这件事的原生机制**:它把子树里每一个表单控件
//     (button / input / select / textarea)置为 disabled,**留在无障碍树里、
//     并且被正确播报成"已禁用"**,不需要知道儿子是什么形状。
//   `className="contents"`(display: contents)让这个 fieldset **不产生盒子** ——
//   否则它会带着自己的默认边距挤进 flex / grid 里,把 56 个文件的版式各弄坏一点。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【为什么理由是【看得见的文字】,不只是一个 title 提示】★
// ════════════════════════════════════════════════════════════════════════════
//   CMP-2 立过一条房规(`docs/silent-disable-inventory.md` 抬头):
//     **「禁用提交钮的每一个非瞬态条件,都必须有紧邻按钮的一行可见文字,
//        说出【是什么在拦、去哪解决】。」**
//   一个只有 hover 才出得来的解释,在触屏上等于不存在,而"没有权限"是一个
//   **非瞬态**条件 —— 它不会像 `disabled={isPending}` 那样一秒后自己消失。
//   所以:**可见的一行(点名权限码)+ title 里那句完整的话(说去找谁)**。
//
// ★【措辞【不新写】,与按下去之后那一句是同一句】★
//   `common.actionMessage.permissionDenied` 是 SILENT-1 给"按下去被拒"用的那句,
//   它已经说了三件事:缺哪个码、记录一个字没动、以及管理员在
//   Settings → Roles 里勾它。**按之前与按之后说同一句话**,人才能把两次遭遇
//   认成同一件事;各写一句,就是同一个问题的第二份实现。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★★【ALERT-2d(2026-09-09)· `alsoAllowedIf` —— 一条【管理员开不了】的路】★★★
// ════════════════════════════════════════════════════════════════════════════
//   上面那句话("管理员在 Settings → Roles 里勾 <码>")**只有在这个控件的
//   权限半边【只有一条路】时才是真的。**
//
//   实测的反例是绩效考核:`canWrite = canHrEdit || isReviewer` ——
//     · `canHrEdit` = `can('module.hr.edit')`,一个**管理员勾得出来**的码;
//     · `isReviewer` = 你是不是这份考核【点名的那个评估人】,一次**关系授权**。
//   两者都能打开同一个控件,而**它们不是同一种东西**。
//   一个被挡住的读者,最可能的真相是第二条:**"这件事不归你"** ——
//   而那**没有任何管理员给得了、没有任何角色开关打得开**。
//
//   ☞ 只说 `module.hr.edit`,就是把人支去要一样【要来了也可能不管用】的东西,
//     而更坏的情形是他【已经有】那个码:那句话于是指着一项他早就持有的权限。
//     `docs/known-issues.md` 的 DBLOCK-CONFLATED-BOOLEANS 整条立案讲的就是这个,
//     它自己的原话是:**说错原因比不说原因更坏。**
//
//   ★【为什么是一条【能力】,不是给考核写一个组件】★(Tim 在 ALERT-2d 闸上裁定)
//     第二份拒绝实现正是措辞开始漂的地方(BASE-1 抬头那 18 种画法的由来)。
//     所以这条能力住在共享库里,**下一块关系授权的屏(任务参与人、我的考核、
//     谁被指派到这一行)照样用得上** —— 它只要求调用方给出两句话,
//     不要求它知道"关系授权"这四个字。
//
//   ★【两句话为什么是两句,而不是一句】★ 与 RefusalBlock 的
//     statement / hint 同一条理由:可见的那半句要短到能挂在控件旁边,
//     而"这条路管理员开不了、你该去找谁"那句话装不进一枚药丸。
//     交给调用方拼成一句,它就会在下一页上漂成另一个样子。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { cn } from '@/lib/utils'
import { useTranslations } from '@/lib/i18n/client'
import { Refusal } from '@/app/components/ui/refusal'

export function PermissionGate({
    code,
    allowed,
    children,
    className,
    inline = false,
    alsoAllowedIf,
}: {
    /** 缺的那个权限码,例如 `module.finance.edit`。**必填** —— 一句说不出码的拒绝,
     *  读的人拿不到任何可以去要的东西(refusal-names-the-numbers)。 */
    code: string
    /** 这个人有没有这项权限。**由页面算好传进来**,本组件不自己查:
     *  判据只有一份实现,而它在服务端(`lib/permissions.ts` 的 `can()`)。 */
    allowed: boolean
    children: React.ReactNode
    className?: string
    /** 行内场景(表格行里的一个小钮):理由挨在右边而不是另起一行。 */
    inline?: boolean
    /**
     * ★ 另一条【同样能打开这个控件】的路,而它通常**不是管理员给得了的**。
     *
     * 传了它,拒绝就从「你需要 <码>」变成「你需要 <码>,或者 <label>」,
     * 并且 title 里那句完整的话后面接上 `why` —— 说清楚这第二条路怎么走、
     * 以及(要紧的那句)**它不是在 Settings → Roles 里勾得出来的**。
     *
     * 【两句都必须走 i18n,而且都由调用方给】判据只有页面知道:
     * 「你不是这份考核指定的评估人」与「你不是这条任务的参与人」是两句不同的话,
     * 而把它们塞进这个组件就等于让共享库去猜每一块屏的关系模型。
     */
    alsoAllowedIf?: {
        /** 可见的那半句,要短:「或者你是这份考核指定的评估人」 */
        label: string
        /** 进 title 的整句:这条路怎么走,以及管理员开不了它。 */
        why: string
    }
}) {
    const t = useTranslations()
    if (allowed) return <>{children}</>

    // 按之前与按之后同一句(见抬头);另一条路的说明【接在后面】,不覆盖它 ——
    // 那个码仍然是真的,只是它不再是唯一的一条路。
    const why = alsoAllowedIf
        ? `${t('common.actionMessage.permissionDenied', { 0: code })}\n\n${alsoAllowedIf.why}`
        : t('common.actionMessage.permissionDenied', { 0: code })

    return (
        <span
            // ★【机器标记跟着组件走,不交给调用点】★ 与 RefusalPage 的
            //   data-access-denied 同一条规矩:REACH-1 首跑靠认文案字符串,
            //   一次漏认就是一次误报。按角色跑走查的探针认的是这个属性。
            data-slot="permission-gate"
            data-permission-required={code}
            className={cn(
                'inline-flex gap-1.5',
                inline ? 'flex-row items-center' : 'flex-col items-start',
                className
            )}
        >
            {/* display:contents —— 不产生盒子,所以不动任何一处既有版式。 */}
            <fieldset disabled className="contents">
                {children}
            </fieldset>
            {/* ★ `Refusal` 自己是 `whitespace-nowrap`(一枚药丸本该是一行)。
                   带上「或者……」之后它装的是两句话,一行放不下 —— 在手机上
                   会横着溢出去。所以这一支【明确】把它放开。
                   ☞ 与本刀 confirm-dialog 那五条重置是同一条道理的反面:
                     那里是"对话框不许继承排版",这里是"一段两句话的拒绝
                     不该被一条为单句写的规则钉成一行"。 */}
            <Refusal why={why} className={cn('font-normal', alsoAllowedIf && 'whitespace-normal text-left')}>
                {t('common.permissionGate.needs')}
                <code className="text-[0.95em]">{code}</code>
                {/* ★ 「或者……」跟在码后面,而【不是】另起一枚药丸:
                       两枚药丸读起来像两条各自独立的拒绝,而它们是【一个】
                       条件的两条路 —— 满足任一条就开。 */}
                {alsoAllowedIf && (
                    <span data-permission-alt="1">
                        {t('common.permissionGate.or')}
                        {alsoAllowedIf.label}
                    </span>
                )}
            </Refusal>
        </span>
    )
}

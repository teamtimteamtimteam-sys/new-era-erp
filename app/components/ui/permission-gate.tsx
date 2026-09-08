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
}) {
    const t = useTranslations()
    if (allowed) return <>{children}</>

    const why = t('common.actionMessage.permissionDenied', { 0: code })

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
            <Refusal why={why} className="font-normal">
                {t('common.permissionGate.needs')}
                <code className="font-mono text-[0.95em]">{code}</code>
            </Refusal>
        </span>
    )
}

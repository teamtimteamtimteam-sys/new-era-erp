'use client'

// app/components/ui/action-message.tsx
// ════════════════════════════════════════════════════════════════════════════
// ALERT-1(2026-09-08)· 【告知】的那一半 —— 取代 18 处 alert(result.error)
// ════════════════════════════════════════════════════════════════════════════
//
// ★★【它【不是】确认对话框,而这不是风格问题】★★
//   确认是一个【问句】。它必须等一个答案,所以它有理由挡住人。
//   告知是【已经发生了的事】的回报,挡住人没有正当理由 ——
//   一个什么都不确认的「确定」钮,存在的唯一目的就是被点掉。
//   ☞ 所以本文件【不复用】confirm-dialog.tsx,也【不许】有人把它改成会挡人的:
//     真要问一句话,那属于 <ConfirmButton>,不属于这里。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【subject 在这里同样是必填的 —— 而理由是 Tim 在 ALERT-1 闸上裁定的那一句】★
// ════════════════════════════════════════════════════════════════════════════
//   本机制画的是【页级】横幅。而一张五十行的物料表,每行一个删除钮 ——
//   页顶一条「删除失败」会让人【挨行去猜是哪一条】。
//   **那正是 CONFIRM-1 存在的理由所要终结的那次寻找**,只是换到了动作之后。
//   ☞ 页级横幅之所以还能用在表格行上,靠的就是它【自己说得出主语】。
//     所以 `subject: string` 是必填(编译期),与 ConfirmContent.subject 同一条规矩、
//     同一个理由。谁想把它改成可选,先读 CONFIRM-1 抬头第 ② 条量到的那 28 处。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【量出来的颜色 —— 而库里现成的那一档【不够】】★(ALERT-1 实测 2026-09-08)
// ════════════════════════════════════════════════════════════════════════════
//   画法沿用 BTN-1 给破坏档定的那套几何:淡填充 + 3px 实心左竖条。
//   但两处【不能照抄】<Button variant="destructive">:
//
//   ① `border-destructive/40` 在这里【看不见】。
//      #C0635A 压到 40% 合成后对页底 #F1F9FE 只有 **1.63:1**(白面上 1.65:1)。
//      按钮身上无所谓 —— 它还有填充、有左竖条、有 hover;一条横幅只有这一圈边。
//      **这与 BASE-1 给 Refusal 小片补边是同一件事**:一个"填充色块"必须
//      看得出自己是一个块。→ 改用【全强度】border-destructive:
//        对页底 **3.81:1** ✓ · 对白面 **4.06:1** ✓(两处都过 1.4.11 的 3:1)
//
//   ② 次级那一行【不许用 muted-text】。#62738C 画在这个淡红填充上只有
//      **4.10:1**(白面上 4.37:1)—— **低于 AA**。这个数从来没有描述过这个底。
//      → 次级行用 text-foreground(#182B4B):**11.99:1** ✓ · 白面 12.79:1 ✓
//
//   过了的两个照抄:
//      · 标题与主语 text-destructive-text #AA4F48 on 填充 = 4.55:1 ✓(白面 4.85:1)
//      · 左竖条 #AA4F48 对填充 4.55:1 ✓(≥3:1)
//   复算方法与 brand-tokens.css 的注释同源:填充 = destructive-fill @8% 合成到底色。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【它必须被念出来 —— 而"念得出"与"画出来了"是两件事】★
// ════════════════════════════════════════════════════════════════════════════
//   容器【常驻】DOM(空的时候也在),role="alert" 挂在容器上,不是挂在消息上。
//   这不是讲究:一个【连同 role 一起才出现】的节点,辅助技术很可能整条错过 ——
//   活动区域要先存在,内容再插进去,才会被播报。
//   ☞ 焦点【不搬】。人刚按完那个钮,焦点在钮上,而他多半要【再按一次】或改点别的;
//     把焦点抢到一条横幅上,等于让他自己走回去。role="alert" 负责"说出来",
//     焦点顺序负责"够得着"(横幅在正文之前,Tab 一下就到)。
//   ☞ 验证方式见 scripts/probe-action-message.mjs:它读的是【无障碍树】里
//     那个节点的 role 与 name,不是 DOM 里的属性 —— 写了 role 不等于播报得出。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【为什么是一个模块级的小仓库,而不是 Context】★
//   调用点有一半在【表格单元格里】(materials / suppliers / customers 的删除钮)。
//   一条横幅长在 <td> 里会把表格撑坏,所以它必须画在页级的一个位置上。
//   Context 要求把 provider 套在 children 外面;而这里只需要「任何地方都能推一条
//   进来」——useSyncExternalStore + 一个模块级 Set 就够,根布局里只多一个自闭合标签
//   (与 IdleWatcher 同一个形状:平时什么都不画,该说话的时候才出现)。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { cn } from '@/lib/utils'

export type ActionMessage = {
    /** ★ 必填:这一条说的是【哪一个东西】。批号、物料名、期间日、任务标题。 */
    subject: string
    /** 一句话:【什么没有做成】。用完成体,不要用「失败」两个字了事。 */
    headline: string
    /** 服务端给回来的那句拒绝 —— 已经是人话,这里原样显示,不再加工。 */
    body?: string
    /**
     * 【降级到这里的那串机器字】。驱动/数据库原文永远【不做标题】——
     * 它进一个默认收起的 <details>,给的是"报修时能抄给人看"这一个用途。
     */
    detail?: string
}

type Entry = ActionMessage & { id: number }

// ── 模块级小仓库 ────────────────────────────────────────────────────────────
let entries: Entry[] = []
let seq = 0
const listeners = new Set<() => void>()
const emit = () => listeners.forEach((l) => l())

/**
 * 从任何客户端组件推一条【告知】上去。不挡人,不返回 Promise ——
 * 它报告的是已经发生的事,调用点没有什么可以等。
 */
export function showActionMessage(msg: ActionMessage) {
    entries = [...entries, { ...msg, id: ++seq }]
    emit()
}

export function dismissActionMessage(id: number) {
    entries = entries.filter((e) => e.id !== id)
    emit()
}

export function clearActionMessages() {
    if (entries.length === 0) return
    entries = []
    emit()
}

const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l) } }
const getSnapshot = () => entries
const getServerSnapshot = () => EMPTY
const EMPTY: Entry[] = []

// ── 页级区域(根布局挂一次)────────────────────────────────────────────────

export function ActionMessageRegion() {
    const t = useTranslations()
    const pathname = usePathname()
    const list = React.useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot)

    // 【换页就清】一条横幅说的是【这一页上刚才那一下】。带着它跨页,
    // 下一页的人会以为那是这一页的事。
    React.useEffect(() => { clearActionMessages() }, [pathname])

    return (
        <div
            // ★ 容器常驻 —— 空的时候也在,见抬头。内容插进来才播报得出。
            role="alert"
            aria-live="assertive"
            data-action-message-region="1"
            className={cn('mx-auto w-full max-w-6xl px-4', list.length > 0 && 'pt-3')}
        >
            {list.map((e) => (
                <div
                    key={e.id}
                    data-action-message="1"
                    data-action-message-subject={e.subject}
                    data-action-message-headline={e.headline}
                    data-action-message-has-detail={e.detail ? '1' : '0'}
                    className={cn(
                        'relative mb-2 overflow-hidden rounded-[var(--brand-radius)]',
                        // ★ 全强度描边 —— /40 只有 1.63:1,见抬头 ①
                        'border border-[color:var(--brand-destructive)]',
                        'bg-[color:color-mix(in_srgb,var(--brand-destructive-fill)_8%,transparent)]',
                        'py-2.5 pr-3 pl-3.5',
                        // BTN-1 破坏档的几何:3px 实心左竖条
                        'before:absolute before:inset-y-1 before:left-0 before:w-[3px]',
                        'before:rounded-full before:bg-[color:var(--brand-destructive-text)]'
                    )}
                >
                    <div className="flex items-start justify-between gap-3">
                        <div className="min-w-0">
                            <p className="text-sm font-medium text-[color:var(--brand-destructive-text)]">
                                {e.headline}
                            </p>

                            {/* ★ 主语 —— 这一格【就是页级横幅还能用在表格行上的原因】。
                                单独一个节点,好让探针把它读出来。 */}
                            <p
                                data-action-message-subject-cell="1"
                                className="mt-1 text-sm font-medium break-words text-[color:var(--brand-destructive-text)]"
                            >
                                {e.subject}
                            </p>

                            {/* 次级行用 foreground,不用 muted —— 见抬头 ② */}
                            {e.body && (
                                <p className="mt-1.5 text-sm break-words text-[color:var(--brand-text)]">{e.body}</p>
                            )}

                            {e.detail && (
                                <details className="mt-1.5">
                                    <summary className="cursor-pointer text-xs text-[color:var(--brand-text)]">
                                        {t('common.actionMessage.technicalDetail')}
                                    </summary>
                                    <p
                                        data-action-message-detail="1"
                                        className="mt-1 text-xs break-all text-[color:var(--brand-text)]"
                                    >
                                        {e.detail}
                                    </p>
                                </details>
                            )}
                        </div>

                        <button
                            type="button"
                            data-action-message-dismiss="1"
                            onClick={() => dismissActionMessage(e.id)}
                            aria-label={t('common.actionMessage.dismiss')}
                            className="shrink-0 rounded px-2 py-0.5 text-sm text-[color:var(--brand-destructive-text)] hover:underline"
                        >
                            {t('common.actionMessage.dismiss')}
                        </button>
                    </div>
                </div>
            ))}
        </div>
    )
}

// ── 甲类:贴着那个输入框的一行 ──────────────────────────────────────────────

/**
 * 【甲类】一条贴着字段的错误。
 *
 * 用在【人必须改一个格子】的地方(GST 登记号、锁定日、重开原因)——
 * 那三处的话必须长在那个框旁边,页顶一条横幅会让人回头找是哪个框。
 *
 * 【它为什么不进那个模块级仓库】它不是页级的,它属于这一个字段;
 * 而且它随表单状态生灭,不需要跨组件推送。
 */
export function FieldMessage({
    children,
    field,
    className,
    ...props
}: React.ComponentProps<'p'> & { field: string }) {
    if (!children) return null
    return (
        <p
            role="alert"
            data-field-message="1"
            data-field-message-for={field}
            className={cn('mt-1 text-sm text-[color:var(--brand-destructive-text)]', className)}
            {...props}
        >
            {children}
        </p>
    )
}

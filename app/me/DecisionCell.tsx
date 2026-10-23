'use client'

// app/me/DecisionCell.tsx
// EMP-SELF-1(G2,Tim 的 Q3 · Q4):员工在 /me 上看见自己那张单据【是谁决定的、什么时候、为什么】。
//
// 【数据从哪来】my_document_decisions() —— 读单据本身的 decided_by / decided_at / decision_notes,
//   不读 approval_log(它仍按权限开放)。决定人已经在库里换成了【人】(附加账号显示它主人的名字)。
// 【按状态标注,不改表】(Q3)cancel_leave_request 把取消人与理由写进同样三列,所以一张 cancelled 的假
//   说「由 … 取消」,不说「由 … 决定」。
// 【self_decided】决定人就是本人:R2 那张被标记的自批说「由你自己决定(已标记)」;自己取消的假说「由你自己取消」。
// 【没有决定的单据】这里什么都不画 —— 还在等的单据没有决定人,一个「—」会读成"缺了一条数据"。
import { useTranslations } from '@/lib/i18n/client'

export type Decision = {
    decider: string | null
    decidedAtLabel: string
    notes: string | null
    selfDecided: boolean
}

type T = (key: string, params?: Record<string, string | number>) => string

/** 「由谁决定 / 取消」那一句 —— 格子与导出共用一份措辞。 */
function whoLine(t: T, decision: Decision, cancelled: boolean): string {
    const name = decision.decider ?? t('me.deciderUnknown')
    return cancelled
        ? (decision.selfDecided ? t('me.cancelledByYou') : t('me.cancelledBy', { name }))
        : (decision.selfDecided ? t('me.decidedByYouFlagged') : t('me.decidedBy', { name }))
}

/**
 * TABLE-EXPORT-2b-1:「决定」这一格导出成屏幕上那几行字(谁 · 何时 · 备注),一格文字。
 * 这一格本来就是组合的(docs/table-export.md「What a cell cannot hold」),所以时刻照屏幕上那串字写;没有决定 → 空格,与屏幕一样。
 */
export function decisionText(t: T, decision: Decision | undefined, cancelled: boolean): string | null {
    if (!decision) return null
    return [whoLine(t, decision, cancelled), t('me.decidedOn', { date: decision.decidedAtLabel }), decision.notes]
        .filter(Boolean).join(' · ')
}

export default function DecisionCell({ decision, cancelled }: { decision: Decision | undefined; cancelled: boolean }) {
    const t = useTranslations()
    if (!decision) return null
    const who = whoLine(t, decision, cancelled)
    return (
        <>
            <span className="block">{who}</span>
            <span className="block text-xs text-[color:var(--brand-muted-text)]">
                {t('me.decidedOn', { date: decision.decidedAtLabel })}
            </span>
            {decision.notes && (
                <span className="block text-xs text-gray-600">{decision.notes}</span>
            )}
        </>
    )
}

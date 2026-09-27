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

export default function DecisionCell({ decision, cancelled }: { decision: Decision | undefined; cancelled: boolean }) {
    const t = useTranslations()
    if (!decision) return null
    const name = decision.decider ?? t('me.deciderUnknown')
    const who = cancelled
        ? (decision.selfDecided ? t('me.cancelledByYou') : t('me.cancelledBy', { name }))
        : (decision.selfDecided ? t('me.decidedByYouFlagged') : t('me.decidedBy', { name }))
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

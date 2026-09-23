// app/finance/self-approved/page.tsx
// APR-ROUTE-1(Tim 的 R2 · Q4):【自批记录】—— 每一张由单据主角本人决定的报销单或医疗申报。
//
// 【它为什么存在】Tim 裁定二级审批角色(今天是 cfo)的持有人可以决定他自己的报销单与
// 医疗申报,并且是有意识地选了【可追溯】而不是【可防止】。可追溯要成立,就必须有一块
// 屏幕让【别人】看得见每一次这样的决定 —— 一个只写进 approval_log、却没有任何地方读它的
// 标记,与没有标记是同一件事。
//
// 【谁看得见】持 data.view_self_approvals 的人:admin · gm · auditor。
// 注册表把它挂在【财务与人力两个模块】下(一张报销单属于财务,一张医疗申报属于人力),
// 判据只有那一个码 —— 见 lib/modules.ts 那一行。
//
// 【读失败必须【失败】】零行在这里的意思是"没有人自批过"—— 一句关于内控的真话。
// 把一次读失败画成零行,就是把"读不到"说成"没有发生"。所以 error 照原样抛给错误边界。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { mustRows } from '@/lib/db-helpers'
import { formatAuditStamp } from '@/lib/dates'
import { formatAmount } from '@/lib/format'
import SelfApprovedTable, { type SelfApprovedRow } from './SelfApprovedTable'

type Row = {
    seq: number
    decided_at: string
    subject_type: string
    subject_id: string
    subject_code: string | null
    decision: string
    level: number | null
    actor_name: string | null
    subject_name: string | null
    amount_ccy: number | null
    currency: string | null
    note: string | null
}

// 种类 → 它的详情页。认不出的种类【不给链接】而不是猜一个。
function hrefFor(r: Row): string | null {
    if (r.subject_type === 'medical_claim') return `/hr/claims/${r.subject_id}`
    if (r.subject_type === 'expense_claim') return '/finance/claims'
    // ROLE-1:R2 扩到 CFO 自己的请假
    if (r.subject_type === 'leave_request') return `/hr/leave/${r.subject_id}`
    return null
}

export default async function SelfApprovedPage() {
    const denied = await requireFunction(FN.selfApproved)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const rows = mustRows<Row>(await supabase.rpc('self_approved_decisions'), 'self-approved decisions')

    const view: SelfApprovedRow[] = rows.map((r) => ({
        seq: String(r.seq),
        decidedAt: formatAuditStamp(r.decided_at),
        kind: t('finance.approvals.subject_' + r.subject_type),
        code: r.subject_code ?? r.subject_id,
        href: hrefFor(r),
        decision: (r.decision === 'approved'
            ? t('finance.selfApproved.decisionApproved')
            : t('finance.selfApproved.decisionRejected'))
            + (r.level !== null ? ` · ${t('finance.selfApproved.level', { level: String(r.level) })}` : ''),
        decider: r.actor_name ?? '—',
        subject: r.subject_name ?? '—',
        amount: formatAmount(r.amount_ccy, r.currency),
        note: r.note ?? '',
    }))

    return (
        <div className="p-8">
            <h1 className="mb-2">{t('finance.selfApproved.title')}</h1>
            <p className="max-w-3xl text-sm text-[color:var(--brand-muted-text)] mb-6">
                {t('finance.selfApproved.why')}
            </p>
            <SelfApprovedTable
                rows={view}
                empty={<p className="text-sm text-[color:var(--brand-text)]">{t('finance.selfApproved.empty')}</p>}
            />
        </div>
    )
}

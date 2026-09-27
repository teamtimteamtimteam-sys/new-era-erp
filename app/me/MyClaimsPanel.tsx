'use client'

// app/me/MyClaimsPanel.tsx
// 自助的医疗报销:剩余额度 + 自己的报销历史 + 提交表单。
//
// ★ TABLE-CONVERT-1(2026-09-10):手搓表格 → 组件。
//   【这张表【没有】列选判断要搬】—— 它转换之前一个 hidden sm:table-cell 都没有,
//   四列在 390px 上【全部看得见】。于是四列【全部】priority:那不是"我给它加了
//   优先级",那是把「今天手机上四列都在」原样说了一遍。折进展开区才是改判断。
//
// ★ EMP-SELF-1(G2 · G3b,Tim 2026-09-27):多两列 ——「决定」(谁、何时、备注;医疗申报的视图里没有备注,
//   从 my_document_decisions() 来)不带 priority,手机上折进展开区;动作列带 priority(够不着的动作等于不存在):
//   submitted 的申报有「撤回」;已批准 / 已付的那颗钮【看得见、按不动、说出理由】(库里按名拒
//   MEDICAL_CLAIM_NOT_SUBMITTED)。已驳回 / 已撤回的没有钮 —— 那里没有一个会被拒的动作。
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import ClaimForm from '@/app/hr/claims/ClaimForm'
import { withdrawMedicalClaim } from '@/app/hr/claims/actions'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import DecisionCell, { type Decision } from './DecisionCell'

type Claim = {
    claim_id: string; code: string; claim_date: string
    amount_sgd: number; settlement_state: string; expense_code: string | null
    status: string
}
type Bal = { pro_rated_limit_sgd: number; claimed_sgd: number; remaining_sgd: number }

export default function MyClaimsPanel({
    employeeId, claims, balance, decisions,
}: { employeeId: string; claims: Claim[]; balance: Bal | null; decisions: Record<string, Decision> }) {
    const t = useTranslations()
    const [open, setOpen] = useState(false)
    const [error, setError] = useState<string | null>(null)
    const [busy, startTransition] = useTransition()

    // ★ 原有四列全部 priority —— 见抬头:转换之前手机上就是四列都在。
    const columns: Column<Claim>[] = [
        { key: 'code', header: t('claims.code'), priority: true, render: (c) => c.code },
        { key: 'date', header: t('claims.date'), priority: true, render: (c) => c.claim_date },
        {
            key: 'amount', header: t('claims.amount'), align: 'right', priority: true,
            render: (c) => `${Number(c.amount_sgd).toFixed(2)} SGD`,
        },
        {
            key: 'state', header: t('claims.state'), priority: true,
            render: (c) => t(`claims.state_${c.settlement_state}`),
        },
        {
            key: 'decision', header: t('me.decisionCol'),
            render: (c) => <DecisionCell decision={decisions[c.claim_id]} cancelled={false} />,
        },
        {
            key: 'actions', header: '', align: 'right', priority: true,
            render: (c) => c.status === 'submitted' ? (
                <ConfirmButton
                    subject={c.code}
                    title={t('me.withdrawClaimTitle')}
                    body={t('me.withdrawClaimBody')}
                    confirmLabel={t('me.withdrawClaim')}
                    tier="reversal"
                    triggerVariant="reversal"
                    triggerSize="xs"
                    disabled={busy}
                    onConfirm={() => {
                        setError(null)
                        startTransition(async () => {
                            const x = await withdrawMedicalClaim(c.claim_id)
                            if (x.error) setError(x.error)
                        })
                    }}>
                    {t('me.withdrawClaim')}
                </ConfirmButton>
            ) : c.status === 'approved' || c.status === 'paid' ? (
                <>
                    <Button variant="reversal" size="xs" type="button" disabled>{t('me.withdrawClaim')}</Button>
                    <span className="block text-xs text-[color:var(--brand-muted-text)] max-w-[14rem] ml-auto">
                        {t('me.withdrawClaimDecidedReason')}
                    </span>
                </>
            ) : null,
        },
    ]

    return (
        <section className="mb-6">
            <div className="flex items-center justify-between mb-2">
                <h2 className="">{t('me.claims')}</h2>
                <Button type="button" onClick={() => setOpen((o) => !o)}
                        variant="default">
                    {open ? t('common.cancel') : t('me.submitClaim')}
                </Button>
            </div>

            {balance && (
                <div className="rounded border border-gray-200 p-4 mb-3 grid gap-4 sm:grid-cols-3">
                    <div><div className="text-xs text-[color:var(--brand-muted-text)]">{t('claims.limit')}</div>
                        <div className="text-sm">{balance.pro_rated_limit_sgd} SGD</div></div>
                    <div><div className="text-xs text-[color:var(--brand-muted-text)]">{t('claims.claimed')}</div>
                        <div className="text-sm">{balance.claimed_sgd} SGD</div></div>
                    <div><div className="text-xs text-[color:var(--brand-muted-text)]">{t('claims.remaining')}</div>
                        <div className="text-lg font-medium leading-6">{balance.remaining_sgd} SGD</div></div>
                </div>
            )}

            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            {open && (
                <div className="mb-3">
                    <ClaimForm fixedEmployeeId={employeeId} redirectTo="/me" />
                </div>
            )}

            <DataTable
                rows={claims}
                columns={columns}
                rowKey={(c) => c.claim_id}
                phone={{ mode: 'columns' }}
                empty={t('me.noClaims')}
            />
        </section>
    )
}

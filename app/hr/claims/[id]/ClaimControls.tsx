'use client'

import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { decideClaim, payClaim } from '../actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function ClaimControls({
    claimId, status, alreadyLinked, canFinance,
}: {
    claimId: string
    status: string
    alreadyLinked: boolean
    canFinance: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [notes, setNotes] = useState('')
    const [date, setDate] = useState(new Date().toISOString().slice(0, 10))
    const [error, setError] = useState<string | null>(null)
    const [ok, setOk] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    function run(fn: () => Promise<{ error?: string; expenseCode?: string }>) {
        setError(null); setOk(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else { if (r.expenseCode) setOk(r.expenseCode); router.refresh() }
        })
    }

    return (
        <div className="rounded border border-gray-200 p-4">
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            {ok && <p className="mb-3 text-sm text-green-700">{t('claims.expenseCreated', { 0: ok })}</p>}

            {status === 'submitted' && (
                <>
                    <label className="block mb-3">{t('leave.decisionNotes')}
                        <input value={notes} onChange={(e) => setNotes(e.target.value)}
                               className={`${CONTROL_INPUT} mt-1 w-full`} /></label>
                    <div className="flex gap-3">
                        <Button type="button" disabled={pending}
                                onClick={() => run(() => decideClaim(claimId, true, notes || null))}>
                            {t('leave.approve')}
                        </Button>
                        <Button type="button" disabled={pending}
                                onClick={() => run(() => decideClaim(claimId, false, notes || null))}
                                variant="secondary">
                            {t('leave.reject')}
                        </Button>
                    </div>
                </>
            )}

            {status === 'approved' && !alreadyLinked && (
                <div>
                    <h3 className="mb-1">{t('claims.createExpense')}</h3>
                    <p className="text-xs text-gray-600 mb-3">{t('claims.createExpenseHint')}</p>
                    <div className="flex gap-2 flex-wrap items-end mb-3">
                        <label className="">{t('claims.expenseDate')}
                            <input type="date" value={date} onChange={(e) => setDate(e.target.value)}
                                   className={`${CONTROL_INPUT} block`} /></label>
                    </div>
                    {/* ★★ ALERT-2d ④(b):`pending || !canFinance || !date` —— 三样东西:
                           · `pending`     瞬态,一秒后自己消失 → 留在 disabled 里,
                                           按钮的字已经说了「保存中…」(CMP-2 只要求
                                           **非瞬态**条件配一行常驻的解释);
                           · `!canFinance` 权限 → <PermissionGate>:点名 module.finance.edit,
                                           并说管理员在 Settings → Roles 里给。
                                           下面那句 needsFinance 【留着】—— 它说的是另一件事
                                           (HR 审、财务转应付,两步两人),是【流程】不是【补救】;
                           · `!date`       【还没填日期】—— 既不是权限也不是记录状态,
                                           它是"还没有东西可操作"那一族。给它写一句拒绝
                                           是假话:该说的是【下一步做什么】。 */}
                    <PermissionGate code="module.finance.edit" allowed={canFinance} inline>
                        <Button
                            type="button"
                            disabled={pending || !date}
                            onClick={() => run(() => payClaim(claimId, date))}>
                            {pending ? t('common.saving') : t('claims.createExpense')}
                        </Button>
                    </PermissionGate>
                    {!date && (
                        <p className="mt-2 text-xs text-gray-600" data-state-note="claim-date">
                            {t('claims.needExpenseDate')}
                        </p>
                    )}
                    {!canFinance && <p className="mt-2 text-xs text-amber-800">{t('claims.needsFinance')}</p>}
                </div>
            )}
        </div>
    )
}

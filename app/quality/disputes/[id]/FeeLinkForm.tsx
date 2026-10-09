'use client'

// app/quality/disputes/[id]/FeeLinkForm.tsx
// MES-6a-1(MES-0 Q63 · Q64;MES-6a Step 0 Q22 · Q23):把仲裁费那一张费用单挂到争议上。
//   仲裁费是一张【普通】费用单:财务照常在费用页记(未付),供应商就是出仲裁结果那家实验室在字典里指着的那一户。
//   这里只挂、不付钱、不收对手方那一份。选单只列那一户供应商名下、在册的费用单;读不到费用单的人(没有财务查看码)看到一句"请财务挂"。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { linkDisputeFee } from '../../actions'

export default function FeeLinkForm({ id, expenses, canEdit }: { id: string; expenses: { id: string; label: string }[]; canEdit: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [expenseId, setExpenseId] = useState('')

    function save() {
        setError('')
        startTransition(async () => {
            const res = await linkDisputeFee(id, expenseId)
            if (res?.error) { setError(res.error); return }
            router.refresh()
        })
    }

    return (
        <PermissionGate code="module.quality.edit" allowed={canEdit}>
            <div className="space-y-2" data-form="dispute-fee">
                {error && <p className="text-sm text-red-600">{error}</p>}
                <div className="flex flex-wrap items-end gap-3">
                    <label className="block text-sm min-w-0 basis-full sm:basis-96">
                        <span className="block mb-1">{t('quality.dispute.feeExpense')}</span>
                        <select value={expenseId} onChange={(e) => setExpenseId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="fee_expense_id">
                            <option value="" disabled>{t('quality.dispute.pickExpense')}</option>
                            {expenses.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}
                        </select>
                    </label>
                    <Button type="button" variant="secondary" disabled={isPending || !expenseId} onClick={save}>
                        {t('quality.dispute.linkFee')}
                    </Button>
                </div>
            </div>
        </PermissionGate>
    )
}

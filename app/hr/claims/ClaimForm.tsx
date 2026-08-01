'use client'

// app/hr/claims/ClaimForm.tsx
// 报销提交。HR 代提交时可选员工;自助时固定成本人。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { submitClaim } from './actions'

export type EmpOpt = { id: string; code: string; legal_name: string }

export default function ClaimForm({
    employees, fixedEmployeeId, redirectTo,
}: { employees?: EmpOpt[]; fixedEmployeeId?: string; redirectTo: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [employeeId, setEmployeeId] = useState(fixedEmployeeId ?? '')
    const [date, setDate] = useState('')
    const [amount, setAmount] = useState('')
    const [desc, setDesc] = useState('')
    const [receipt, setReceipt] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    function submit() {
        setError(null)
        startTransition(async () => {
            const r = await submitClaim({
                employeeId: fixedEmployeeId ?? employeeId,
                claimDate: date,
                amountSgd: Number(amount),
                description: desc || null,
                receiptRef: receipt || null,
            })
            if (r.error) setError(r.error)
            else { router.push(redirectTo); router.refresh() }
        })
    }

    const field = 'mt-1 w-full border border-gray-300 rounded px-2 py-1 text-sm'
    return (
        <div className="rounded border border-gray-200 p-4 max-w-xl">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="grid gap-4 sm:grid-cols-2">
                {!fixedEmployeeId && employees && (
                    <label className="text-sm sm:col-span-2">{t('leave.employee')}
                        <select value={employeeId} onChange={(e) => setEmployeeId(e.target.value)} className={field}>
                            <option value="">—</option>
                            {employees.map((e) => <option key={e.id} value={e.id}>{e.code} — {e.legal_name}</option>)}
                        </select>
                    </label>
                )}
                <label className="text-sm">{t('claims.date')}
                    <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={field} /></label>
                <label className="text-sm">{t('claims.amountSgd')}
                    <input type="number" step="0.01" min="0.01" value={amount}
                           onChange={(e) => setAmount(e.target.value)} className={field} /></label>
                <label className="text-sm sm:col-span-2">{t('claims.description')}
                    <input value={desc} onChange={(e) => setDesc(e.target.value)} className={field} /></label>
                <label className="text-sm sm:col-span-2">{t('claims.receipt')}
                    <input value={receipt} onChange={(e) => setReceipt(e.target.value)} className={field} /></label>
            </div>
            <button type="button" onClick={submit}
                    disabled={pending || !date || !amount || (!fixedEmployeeId && !employeeId)}
                    className="mt-4 bg-gray-900 text-white px-4 py-1.5 rounded text-sm disabled:opacity-50">
                {pending ? t('common.saving') : t('claims.submit')}
            </button>
        </div>
    )
}

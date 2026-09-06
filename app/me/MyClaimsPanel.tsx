'use client'

// app/me/MyClaimsPanel.tsx
// 自助的医疗报销:剩余额度 + 自己的报销历史 + 提交表单。
import { useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import ClaimForm from '@/app/hr/claims/ClaimForm'
import { Button } from '@/app/components/ui/button'

type Claim = {
    claim_id: string; code: string; claim_date: string
    amount_sgd: number; settlement_state: string; expense_code: string | null
}
type Bal = { pro_rated_limit_sgd: number; claimed_sgd: number; remaining_sgd: number }

export default function MyClaimsPanel({
    employeeId, claims, balance,
}: { employeeId: string; claims: Claim[]; balance: Bal | null }) {
    const t = useTranslations()
    const [open, setOpen] = useState(false)

    return (
        <section className="mb-6">
            <div className="flex items-center justify-between mb-2">
                <h2 className="text-lg font-bold">{t('me.claims')}</h2>
                <Button type="button" onClick={() => setOpen((o) => !o)}
                        variant="default" size="sm">
                    {open ? t('common.cancel') : t('me.submitClaim')}
                </Button>
            </div>

            {balance && (
                <div className="rounded border border-gray-200 p-4 mb-3 grid gap-4 sm:grid-cols-3">
                    <div><div className="text-xs text-gray-500">{t('claims.limit')}</div>
                        <div className="text-sm font-mono">{balance.pro_rated_limit_sgd} SGD</div></div>
                    <div><div className="text-xs text-gray-500">{t('claims.claimed')}</div>
                        <div className="text-sm font-mono">{balance.claimed_sgd} SGD</div></div>
                    <div><div className="text-xs text-gray-500">{t('claims.remaining')}</div>
                        <div className="text-lg font-mono font-medium">{balance.remaining_sgd} SGD</div></div>
                </div>
            )}

            {open && (
                <div className="mb-3">
                    <ClaimForm fixedEmployeeId={employeeId} redirectTo="/me" />
                </div>
            )}

            {claims.length === 0 ? (
                <p className="text-sm text-gray-500">{t('me.noClaims')}</p>
            ) : (
                <table className="w-full border-collapse text-sm">
                    <thead>
                        <tr className="bg-gray-50 text-left">
                            <th className="border border-gray-300 px-3 py-2">{t('claims.code')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('claims.date')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('claims.amount')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('claims.state')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {claims.map((c) => (
                            <tr key={c.claim_id}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{c.code}</td>
                                <td className="border border-gray-300 px-3 py-2">{c.claim_date}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {Number(c.amount_sgd).toFixed(2)} SGD
                                </td>
                                <td className="border border-gray-300 px-3 py-2">{t(`claims.state_${c.settlement_state}`)}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </section>
    )
}

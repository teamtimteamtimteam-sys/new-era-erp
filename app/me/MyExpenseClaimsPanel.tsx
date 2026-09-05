'use client'

// app/me/MyExpenseClaimsPanel.tsx
// CLAIM-1:自助那一半 —— 员工自己张口的地方。
//
// 【它紧挨着 MyClaimsPanel(医疗)放,而两者【不是】同一张表】
// 医疗那一套唯一属于医疗的东西是【年度限额】,而一般报销要科目、币种、税码,
// 医疗一个都没有。合成一张表就得让每个读者先问"这一行是哪一种",
// 而答案在另一个模块里。所以是一对,不是一个。
// ★ 也正因为两块面板会并排出现,本刀的错误码全部带 EXPENSE_ 前缀 ——
//   否则一个共用的 localizer 会把一种报销的错误译成另一种的措辞。
import { useState, useTransition } from 'react'
import { submitClaim, withdrawClaim } from '@/app/finance/claims/actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

type Row = {
    claim_id: string; code: string; spend_date: string; amount_ccy: number
    currency: string; description: string; status: string
    is_owing: boolean; is_paid: boolean; has_receipt: boolean
    no_receipt_reason: string | null; decision_notes: string | null
    expense_reversed: boolean | null
}

const money = (n: number) =>
    Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default function MyExpenseClaimsPanel({
    employeeId, rows, baseCurrency,
}: { employeeId: string | null; rows: Row[]; baseCurrency: string }) {
    const t = useTranslations()
    const [open, setOpen] = useState(false)
    // 【花钱那天不预填】—— 一个决定成本落在哪个期间的日期,预填就是奖励留空;
    // 服务端也独立地拒空(合取,不是二选一)。
    const [spendDate, setSpendDate] = useState('')
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState(baseCurrency)
    const [description, setDescription] = useState('')
    const [noReceipt, setNoReceipt] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const today = () => {
        const d = new Date()
        return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
    }
    const canSubmit = spendDate !== '' && amount !== '' && description.trim() !== ''

    return (
        <section className="mb-8">
            <h2 className="text-lg font-semibold mb-1">{t('expenseClaims.myTitle')}</h2>
            <p className="text-xs text-gray-500 mb-1">{t('expenseClaims.myHint')}</p>
            {/* 【备用金是被否决的,不是没做】—— 让读的人遇到一个决定,而不是一个缺口 */}
            <p className="text-xs text-gray-400 mb-3">{t('expenseClaims.pettyCashRuledOut')}</p>

            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            {employeeId && !open && (
                <button type="button" onClick={() => setOpen(true)}
                    className="mb-3 bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 text-sm">
                    {t('expenseClaims.submit')}
                </button>
            )}
            {employeeId && open && (
                <div className="mb-4 rounded border border-gray-300 p-3 flex flex-wrap gap-3 items-end max-w-3xl">
                    <label className="text-sm text-gray-600">{t('expenseClaims.spendDate')}
                        <input type="date" value={spendDate} max={today()}
                            onChange={(e) => setSpendDate(e.target.value)}
                            className="block rounded border border-gray-300 px-3 py-2" />
                        <span className="block text-[11px] text-gray-500">{t('expenseClaims.spendDateHint')}</span></label>
                    <label className="text-sm text-gray-600">{t('expenseClaims.amount')}
                        <input type="number" step="0.01" min="0" value={amount}
                            onChange={(e) => setAmount(e.target.value)}
                            className="block rounded border border-gray-300 px-3 py-2 w-32" /></label>
                    <label className="text-sm text-gray-600">{t('expenseClaims.currency')}
                        <input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())}
                            className="block rounded border border-gray-300 px-3 py-2 w-20 font-mono" /></label>
                    <label className="text-sm text-gray-600 flex-1 min-w-[16rem]">{t('expenseClaims.description')}
                        <input value={description} onChange={(e) => setDescription(e.target.value)}
                            className="block w-full rounded border border-gray-300 px-3 py-2" />
                        <span className="block text-[11px] text-gray-500">{t('expenseClaims.descriptionHint')}</span></label>
                    <label className="text-sm text-gray-600 flex-1 min-w-[16rem]">{t('expenseClaims.noReceiptReason')}
                        <input value={noReceipt} onChange={(e) => setNoReceipt(e.target.value)}
                            className="block w-full rounded border border-gray-300 px-3 py-2" />
                        <span className="block text-[11px] text-gray-500">{t('expenseClaims.noReceiptReasonHint')}</span></label>
                    <Button type="button" disabled={pending || !canSubmit}
                        onClick={() => {
                            setError(null)
                            startTransition(async () => {
                                const r = await submitClaim({
                                    employeeId: employeeId!, spendDate, amount, currency,
                                    description, noReceiptReason: noReceipt,
                                })
                                if (r.error) setError(r.error)
                                else { setOpen(false); setSpendDate(''); setAmount(''); setDescription(''); setNoReceipt('') }
                            })
                        }}>
                        {t('expenseClaims.submit')}
                    </Button>
                </div>
            )}

            {rows.length === 0 ? (
                // 【命名的缺席,不是空白】"还没提过"与"读不到"要说得不一样
                <p className="text-sm text-gray-500">{t('expenseClaims.none')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('expenseClaims.colRef')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('expenseClaims.colSpent')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('expenseClaims.colDescription')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('expenseClaims.colAmount')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('expenseClaims.colStatus')}</th>
                            <th className="border border-gray-300 px-3 py-2"></th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.claim_id}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{r.code}</td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{r.spend_date}</td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {r.description}
                                    <span className="block text-[11px] text-gray-500">
                                        {r.has_receipt ? t('expenseClaims.hasReceipt')
                                            : r.no_receipt_reason
                                                ? `${t('expenseClaims.noReceipt')} — ${r.no_receipt_reason}`
                                                : t('expenseClaims.noReceipt')}
                                    </span>
                                    {r.decision_notes && (
                                        <span className="block text-[11px] text-gray-600">{r.decision_notes}</span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {money(r.amount_ccy)} {r.currency}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {t('expenseClaims.status_' + r.status)}
                                    {r.expense_reversed && (
                                        <span className="block text-[11px] text-red-700">{t('expenseClaims.reversed')}</span>
                                    )}
                                    {!r.expense_reversed && r.is_owing && (
                                        <span className="block text-[11px] text-amber-800">{t('expenseClaims.owing')}</span>
                                    )}
                                    {!r.expense_reversed && r.is_paid && (
                                        <span className="block text-[11px] text-green-700">{t('expenseClaims.paid')}</span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right">
                                    {r.status === 'submitted' && (
                                        <button type="button" disabled={pending}
                                            onClick={() => {
                                                setError(null)
                                                startTransition(async () => {
                                                    const x = await withdrawClaim(r.claim_id)
                                                    if (x.error) setError(x.error)
                                                })
                                            }}
                                            title={t('expenseClaims.withdrawHint')}
                                            className="border border-gray-300 rounded px-2 py-1 text-xs hover:bg-gray-50 disabled:opacity-50">
                                            {t('expenseClaims.withdraw')}
                                        </button>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </section>
    )
}

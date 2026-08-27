'use client'

// app/finance/claims/ClaimDecisionPanel.tsx
// CLAIM-1:审批队列。
//
// ★【会计口径在这一屏上给,而不是在提报那一屏】★
// 提报的人陈述【事实】(买了什么、哪天、多少钱、凭据);
// 审批的人陈述【会计】(记哪个科目、哪个税码)。一个员工不可能知道科目表,
// 而进项税可抵(TX)还是不可抵(BL)是一个财务判断 —— 不是一个能默认的东西。
//
// 【入账日那一格默认留空】留空 = 按花钱那天入账(成本属于它发生的期间)。
// 只有那个期间已经关账、服务端按名拒(PERIOD_LOCKED)之后,才另给一个日子 ——
// 界面【不】替人回落到今天,那正是 FIN-10 拆掉的那种默认。
import { useState, useTransition } from 'react'
import { decideClaim } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export type ClaimRow = {
    claim_id: string; code: string; employee_code: string; employee_name: string
    spend_date: string; amount_ccy: number; currency: string; description: string
    status: string; no_receipt_reason: string | null; has_receipt: boolean
    decision_notes: string | null; account_code: string | null; tax_code: string | null
    posting_date: string | null; is_owing: boolean; is_paid: boolean
    expense_reversed: boolean | null
}

const money = (n: number) =>
    Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default function ClaimDecisionPanel({
    pending, decided, accounts, taxCodes, canDecide,
}: {
    pending: ClaimRow[]; decided: ClaimRow[]
    accounts: { code: string; name_en: string }[]
    taxCodes: { code: string; name_en: string }[]
    canDecide: boolean; baseCurrency: string
}) {
    const t = useTranslations()
    const [sel, setSel] = useState<Record<string, { acct: string; tax: string; post: string; notes: string }>>({})
    const [error, setError] = useState<string | null>(null)
    const [pendingTx, startTransition] = useTransition()
    const get = (id: string) => sel[id] ?? { acct: '', tax: '', post: '', notes: '' }
    const set = (id: string, patch: Partial<{ acct: string; tax: string; post: string; notes: string }>) =>
        setSel((s) => ({ ...s, [id]: { ...get(id), ...patch } }))

    const run = (fn: () => Promise<{ error?: string }>) => {
        setError(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
        })
    }

    return (
        <div>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            <h2 className="text-lg font-semibold mb-2">{t('expenseClaims.pendingTitle')}</h2>
            {pending.length === 0 ? (
                // 【命名的缺席,不是空白】
                <p className="text-sm text-gray-500 mb-8">{t('expenseClaims.noPending')}</p>
            ) : (
                <div className="mb-8 space-y-3">
                    {pending.map((c) => (
                        <div key={c.claim_id} className="rounded border border-gray-300 p-3">
                            <div className="flex flex-wrap items-baseline gap-2 mb-1">
                                <span className="font-mono text-xs">{c.code}</span>
                                <span className="font-medium">{c.employee_name}</span>
                                <span className="text-xs text-gray-500 font-mono">{c.employee_code}</span>
                                <span className="font-mono">{money(c.amount_ccy)} {c.currency}</span>
                                <span className="text-xs text-gray-600">{t('expenseClaims.colSpent')} {c.spend_date}</span>
                            </div>
                            <p className="text-sm mb-1">{c.description}</p>
                            {/* 【凭据是哪一种,审批人必须看得见】 */}
                            <p className="text-xs mb-2">
                                {c.has_receipt
                                    ? <span className="text-green-700">{t('expenseClaims.hasReceipt')}</span>
                                    : c.no_receipt_reason
                                        ? <span className="text-amber-800">{t('expenseClaims.noReceipt')} — {c.no_receipt_reason}</span>
                                        : <span className="text-red-700">{t('expenseClaims.noReceipt')}</span>}
                            </p>
                            {canDecide && (
                                <div className="flex flex-wrap gap-2 items-end">
                                    <label className="text-xs text-gray-600">{t('expenseClaims.accountCode')}
                                        <select value={get(c.claim_id).acct}
                                            onChange={(e) => set(c.claim_id, { acct: e.target.value })}
                                            className="block rounded border border-gray-300 px-2 py-1 text-sm">
                                            <option value=""></option>
                                            {accounts.map((a) => (
                                                <option key={a.code} value={a.code}>{a.code} {a.name_en}</option>
                                            ))}
                                        </select></label>
                                    <label className="text-xs text-gray-600">{t('expenseClaims.taxCode')}
                                        <select value={get(c.claim_id).tax}
                                            onChange={(e) => set(c.claim_id, { tax: e.target.value })}
                                            className="block rounded border border-gray-300 px-2 py-1 text-sm">
                                            <option value=""></option>
                                            {taxCodes.map((x) => (
                                                <option key={x.code} value={x.code}>{x.code} {x.name_en}</option>
                                            ))}
                                        </select></label>
                                    <label className="text-xs text-gray-600">{t('expenseClaims.postingDate')}
                                        <input type="date" value={get(c.claim_id).post}
                                            onChange={(e) => set(c.claim_id, { post: e.target.value })}
                                            className="block rounded border border-gray-300 px-2 py-1 text-sm" /></label>
                                    <label className="text-xs text-gray-600 flex-1 min-w-[12rem]">{t('expenseClaims.decisionNotes')}
                                        <input value={get(c.claim_id).notes}
                                            onChange={(e) => set(c.claim_id, { notes: e.target.value })}
                                            className="block w-full rounded border border-gray-300 px-2 py-1 text-sm" /></label>
                                    <button type="button" disabled={pendingTx}
                                        onClick={() => run(() => decideClaim({
                                            claimId: c.claim_id, approve: true,
                                            accountCode: get(c.claim_id).acct, taxCode: get(c.claim_id).tax,
                                            postingDate: get(c.claim_id).post, notes: get(c.claim_id).notes,
                                        }))}
                                        className="bg-blue-600 text-white px-3 py-1.5 rounded text-sm hover:bg-blue-700 disabled:opacity-50">
                                        {t('expenseClaims.approve')}
                                    </button>
                                    <button type="button" disabled={pendingTx}
                                        onClick={() => run(() => decideClaim({
                                            claimId: c.claim_id, approve: false, notes: get(c.claim_id).notes,
                                        }))}
                                        title={t('expenseClaims.rejectNotesRequired')}
                                        className="border border-gray-300 px-3 py-1.5 rounded text-sm hover:bg-gray-50 disabled:opacity-50">
                                        {t('expenseClaims.reject')}
                                    </button>
                                </div>
                            )}
                            <p className="text-[11px] text-gray-500 mt-1">{t('expenseClaims.postingDateHint')}</p>
                            <p className="text-[11px] text-gray-500">{t('expenseClaims.taxCodeHint')}</p>
                        </div>
                    ))}
                </div>
            )}

            <h2 className="text-lg font-semibold mb-2">{t('expenseClaims.decidedTitle')}</h2>
            {decided.length === 0 ? (
                <p className="text-sm text-gray-500">{t('expenseClaims.noneForEmployee')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('expenseClaims.colRef')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('expenseClaims.colWho')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('expenseClaims.colSpent')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('expenseClaims.colAmount')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('expenseClaims.colStatus')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {decided.map((c) => (
                            <tr key={c.claim_id}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{c.code}</td>
                                <td className="border border-gray-300 px-3 py-2">{c.employee_name}</td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{c.spend_date}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {money(c.amount_ccy)} {c.currency}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {t('expenseClaims.status_' + c.status)}
                                    {c.expense_reversed && (
                                        <span className="block text-[11px] text-red-700">{t('expenseClaims.reversed')}</span>
                                    )}
                                    {!c.expense_reversed && c.is_owing && (
                                        <span className="block text-[11px] text-amber-800">{t('expenseClaims.owingOther')}</span>
                                    )}
                                    {!c.expense_reversed && c.is_paid && (
                                        <span className="block text-[11px] text-green-700">{t('expenseClaims.paid')}</span>
                                    )}
                                    {c.decision_notes && (
                                        <span className="block text-[11px] text-gray-600">{c.decision_notes}</span>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}

'use client'

// COMM-1:佣金协议的表单 —— 新建与编辑共用。
//
// ★★【recognition_trigger 那一格【没有预选项】,而这是本表单最要紧的一件事】★★
//   下拉的第一项是"请选择…",value 为空。**不预选任何一个触发点** ——
//   预选等于替一个没有人签过的商业立场做主,而这个立场决定确认期间。
//   提交按钮在它为空时【禁用】,服务端也【独立地】拒(空 → NOT NULL 撞墙 →
//   按名说话)。两道,与 AGENTS.md「决定期间的值:必填、永不默认」那一族同形。

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveCommissionAgreement, type CommissionInput } from './actions'

export type Agent = { id: string; code: string; legal_name: string }
export type Currency = { code: string }

const SIDES = ['purchase', 'sale', 'free_standing'] as const
const BASES = ['percentage_of_value', 'per_tonne', 'fixed_amount'] as const
const TRIGGERS = ['on_shipment', 'on_invoice', 'on_counterparty_payment'] as const

export default function CommissionForm({
    agents,
    currencies,
    initial,
}: {
    agents: Agent[]
    currencies: Currency[]
    initial?: Partial<CommissionInput> & { id?: string }
}) {
    const t = useTranslations()
    const router = useRouter()
    const [error, setError] = useState<string | null>(null)
    const [saving, setSaving] = useState(false)

    const [form, setForm] = useState<CommissionInput>({
        id: initial?.id,
        agent_supplier_id: initial?.agent_supplier_id ?? '',
        side: initial?.side ?? '',
        basis: initial?.basis ?? '',
        // ★ 永不预选 —— 见抬头
        recognition_trigger: initial?.recognition_trigger ?? '',
        rate_pct: initial?.rate_pct ?? '',
        amount_ccy: initial?.amount_ccy ?? '',
        currency: initial?.currency ?? '',
        valid_from: initial?.valid_from ?? '',
        valid_to: initial?.valid_to ?? '',
        remarks: initial?.remarks ?? '',
    })

    const set = (k: keyof CommissionInput, v: string) => setForm((f) => ({ ...f, [k]: v }))
    const isPct = form.basis === 'percentage_of_value'

    // 提交闸:每一个不许为空的格子都在这里,而服务端【独立地】再拒一次。
    const incomplete =
        form.agent_supplier_id === '' ||
        form.side === '' ||
        form.basis === '' ||
        form.recognition_trigger === '' ||
        form.valid_from === '' ||
        form.valid_to === '' ||
        (isPct ? form.rate_pct === '' : form.amount_ccy === '' || form.currency === '')

    // 【没有一家服务供应商时,说出来】—— 一个空下拉不解释自己,读的人会以为坏了。
    if (agents.length === 0) {
        return (
            <div className="border-l-4 border-amber-500 bg-amber-50 p-3 max-w-2xl">
                <p className="text-sm text-gray-800">{t('commissions.noAgents')}</p>
            </div>
        )
    }

    async function onSubmit(e: React.FormEvent) {
        e.preventDefault()
        setSaving(true)
        setError(null)
        const res = await saveCommissionAgreement(form)
        setSaving(false)
        if (res.error) {
            setError(res.error)
            return
        }
        router.push('/commissions')
        router.refresh()
    }

    const label = 'block text-sm font-medium mb-1'
    const field = 'border border-gray-300 rounded px-2 py-1 text-sm w-full'

    return (
        <form onSubmit={onSubmit} className="max-w-2xl space-y-4">
            <div>
                <label className={label} htmlFor="agent">{t('commissions.fieldAgent')}</label>
                <select id="agent" name="agent_supplier_id" className={field} value={form.agent_supplier_id}
                        onChange={(e) => set('agent_supplier_id', e.target.value)}>
                    <option value="">{t('commissions.selectPrompt')}</option>
                    {agents.map((a) => (
                        <option key={a.id} value={a.id}>{a.code} · {a.legal_name}</option>
                    ))}
                </select>
            </div>

            <div className="grid grid-cols-2 gap-4">
                <div>
                    <label className={label} htmlFor="side">{t('commissions.fieldSide')}</label>
                    <select id="side" name="side" className={field} value={form.side}
                            onChange={(e) => set('side', e.target.value)}>
                        <option value="">{t('commissions.selectPrompt')}</option>
                        {SIDES.map((s) => (
                            <option key={s} value={s}>{t('commissions.side.' + s)}</option>
                        ))}
                    </select>
                </div>
                <div>
                    <label className={label} htmlFor="basis">{t('commissions.fieldBasis')}</label>
                    <select id="basis" name="basis" className={field} value={form.basis}
                            onChange={(e) => set('basis', e.target.value)}>
                        <option value="">{t('commissions.selectPrompt')}</option>
                        {BASES.map((b) => (
                            <option key={b} value={b}>{t('commissions.basis.' + b)}</option>
                        ))}
                    </select>
                </div>
            </div>

            {/* 口径决定填哪一格 —— 与表上的 CHECK 同一条规矩,在屏幕上先说 */}
            {isPct ? (
                <div>
                    <label className={label} htmlFor="rate">{t('commissions.fieldRatePct')}</label>
                    <input id="rate" name="rate_pct" type="number" step="0.0001" min="0" max="100"
                           className={field} value={form.rate_pct}
                           onChange={(e) => set('rate_pct', e.target.value)} />
                </div>
            ) : form.basis === '' ? null : (
                <div className="grid grid-cols-2 gap-4">
                    <div>
                        <label className={label} htmlFor="amount">{t('commissions.fieldAmount')}</label>
                        <input id="amount" name="amount_ccy" type="number" step="0.01" min="0"
                               className={field} value={form.amount_ccy}
                               onChange={(e) => set('amount_ccy', e.target.value)} />
                    </div>
                    <div>
                        <label className={label} htmlFor="ccy">{t('commissions.fieldCurrency')}</label>
                        <select id="ccy" name="currency" className={field} value={form.currency}
                                onChange={(e) => set('currency', e.target.value)}>
                            <option value="">{t('commissions.selectPrompt')}</option>
                            {currencies.map((c) => (
                                <option key={c.code} value={c.code}>{c.code}</option>
                            ))}
                        </select>
                    </div>
                </div>
            )}

            {/* ★★ 本表单最要紧的一格 ★★ */}
            <div className="border-l-4 border-amber-500 bg-amber-50 p-3">
                <label className={label} htmlFor="trigger">{t('commissions.fieldTrigger')}</label>
                <select id="trigger" name="recognition_trigger" className={field} value={form.recognition_trigger}
                        onChange={(e) => set('recognition_trigger', e.target.value)}>
                    <option value="">{t('commissions.selectPrompt')}</option>
                    {TRIGGERS.map((r) => (
                        <option key={r} value={r}>{t('commissions.trigger.' + r)}</option>
                    ))}
                </select>
                <p className="text-xs text-gray-700 mt-2">{t('commissions.triggerWhy')}</p>
            </div>

            <div className="grid grid-cols-2 gap-4">
                <div>
                    <label className={label} htmlFor="from">{t('commissions.fieldValidFrom')}</label>
                    <input id="from" name="valid_from" type="date" className={field} value={form.valid_from}
                           onChange={(e) => set('valid_from', e.target.value)} />
                </div>
                <div>
                    <label className={label} htmlFor="to">{t('commissions.fieldValidTo')}</label>
                    <input id="to" name="valid_to" type="date" className={field} value={form.valid_to}
                           onChange={(e) => set('valid_to', e.target.value)} />
                </div>
            </div>

            <div>
                <label className={label} htmlFor="remarks">{t('commissions.fieldRemarks')}</label>
                <textarea id="remarks" name="remarks" rows={3} className={field} value={form.remarks}
                          onChange={(e) => set('remarks', e.target.value)} />
            </div>

            {error ? <p className="text-sm text-red-700">{error}</p> : null}

            <button type="submit" disabled={incomplete || saving}
                    className="rounded bg-gray-900 px-4 py-2 text-sm text-white disabled:bg-gray-400">
                {t('commissions.save')}
            </button>
        </form>
    )
}

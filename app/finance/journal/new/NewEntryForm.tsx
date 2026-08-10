'use client'

// 手工分录表单:动态行(最少 2 行),科目按类型分组下拉,非 USD 行出汇率输入,
// 底部实时 Σ借/Σ贷(客户端按 fx 折算预览)+ 平衡指示。提交走 createManualEntry。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { createManualEntry, type CreateEntryState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'

const initialState: CreateEntryState = {}

export type AccountOption = {
    code: string
    name: string // 服务端已按语言解析
    account_type: string
}

const TYPE_ORDER = ['asset', 'liability', 'equity', 'revenue', 'cogs', 'expense'] as const

type Row = {
    key: number
    account_code: string
    side: 'debit' | 'credit'
    currency: string
    amount: string
    fx: string
    memo: string
}

// 本地日期(YYYY-MM-DD),用作分录日期默认值(避免 UTC 偏移)。
function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

export default function NewEntryForm(
    { accounts, baseCurrency }: { accounts: AccountOption[]; baseCurrency: string }
) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createManualEntry, initialState)

    const [nextKey, setNextKey] = useState(2)
    const [rows, setRows] = useState<Row[]>([
        { key: 0, account_code: '', side: 'debit', currency: 'USD', amount: '', fx: '', memo: '' },
        { key: 1, account_code: '', side: 'credit', currency: 'USD', amount: '', fx: '', memo: '' },
    ])

    function updateRow(key: number, patch: Partial<Row>) {
        setRows((rs) => rs.map((r) => (r.key === key ? { ...r, ...patch } : r)))
    }
    function addRow() {
        setRows((rs) => [
            ...rs,
            { key: nextKey, account_code: '', side: 'debit', currency: 'USD', amount: '', fx: '', memo: '' },
        ])
        setNextKey((k) => k + 1)
    }
    function removeRow(key: number) {
        setRows((rs) => (rs.length > 2 ? rs.filter((r) => r.key !== key) : rs))
    }

    // 实时 Σ:round(amount × fx, 2),与 DB 同式;任一无效行计 0
    const usd = (r: Row) => {
        const amount = Number(r.amount)
        // 【本位币来自 prop,不是字面量】写死 'USD' 时:基准币(SGD)行会被要求
        // 填汇率、算成 0;而 USD 行反倒按 1:1 折算。两头都错。
        const fx = r.currency === baseCurrency ? 1 : Number(r.fx)
        if (!r.amount || Number.isNaN(amount) || amount <= 0) return 0
        if (r.currency !== baseCurrency && (!r.fx || Number.isNaN(fx) || fx <= 0)) return 0
        return Math.round(amount * fx * 100) / 100
    }
    const sumDebit = Math.round(rows.filter((r) => r.side === 'debit').reduce((s, r) => s + usd(r), 0) * 100) / 100
    const sumCredit = Math.round(rows.filter((r) => r.side === 'credit').reduce((s, r) => s + usd(r), 0) * 100) / 100
    const balanced = sumDebit === sumCredit && sumDebit > 0

    const grouped = TYPE_ORDER.map((type) => ({
        type,
        options: accounts.filter((a) => a.account_type === type),
    })).filter((g) => g.options.length > 0)

    return (
        <form action={formAction} className="space-y-4">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}
            {state.fieldErrors &&
                Object.entries(state.fieldErrors).map(([k, msg]) => (
                    <p key={k} className="text-red-600 text-sm">
                        {msg}
                    </p>
                ))}

            <div className="flex flex-wrap gap-4">
                {/* 日期(必填,默认今天)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.entryDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="entry_date"
                        required
                        defaultValue={todayIsoLocal()}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* 摘要(必填)*/}
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.memo')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="memo"
                        required
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* 分录行 */}
            <div className="space-y-3">
                {rows.map((r) => (
                    <div key={r.key} className="flex flex-wrap items-end gap-2 border border-gray-200 rounded p-3">
                        <div className="flex-1 min-w-[14rem]">
                            <label className="block text-sm font-medium mb-1">
                                {t('finance.colAccount')} <span className="text-red-600">*</span>
                            </label>
                            <select
                                name="account_code"
                                required
                                value={r.account_code}
                                onChange={(e) => updateRow(r.key, { account_code: e.target.value })}
                                className="w-full border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value="" disabled>
                                    {t('finance.selectAccount')}
                                </option>
                                {grouped.map((g) => (
                                    <optgroup key={g.type} label={t('finance.accountType.' + g.type)}>
                                        {g.options.map((a) => (
                                            <option key={a.code} value={a.code}>
                                                {a.code} - {a.name}
                                            </option>
                                        ))}
                                    </optgroup>
                                ))}
                            </select>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('finance.side')}</label>
                            <select
                                name="side"
                                value={r.side}
                                onChange={(e) => updateRow(r.key, { side: e.target.value as Row['side'] })}
                                className="border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value="debit">{t('finance.debit')}</option>
                                <option value="credit">{t('finance.credit')}</option>
                            </select>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('output.sale.currency')}</label>
                            <select
                                name="currency"
                                value={r.currency}
                                onChange={(e) => updateRow(r.key, { currency: e.target.value })}
                                className="border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value="USD">USD</option>
                                <option value="SGD">SGD</option>
                            </select>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('finance.amount')} <span className="text-red-600">*</span>
                            </label>
                            {/* DecimalInput 每行仍只产出一个同名字段,
                                getAll('amount_ccy') 的按行对位不变 */}
                            <DecimalInput
                                name="amount_ccy"
                                required
                                value={r.amount}
                                onChange={(raw) => updateRow(r.key, { amount: raw })}
                                className="w-32 border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                        {r.currency !== baseCurrency ? (
                            <div>
                                <label className="block text-sm font-medium mb-1">
                                    {t('output.sale.fxRate')} <span className="text-red-600">*</span>
                                </label>
                                <DecimalInput
                                    name="fx_rate"
                                    required
                                    value={r.fx}
                                    onChange={(raw) => updateRow(r.key, { fx: raw })}
                                    placeholder={t('output.sale.fxHint')}
                                    className="w-32 border border-gray-300 px-3 py-2 rounded"
                                />
                            </div>
                        ) : (
                            // USD 行提交空 fx,保持 getAll 位置对齐
                            <input type="hidden" name="fx_rate" value="" />
                        )}
                        <div className="flex-1 min-w-[10rem]">
                            <label className="block text-sm font-medium mb-1">{t('finance.lineMemo')}</label>
                            <input
                                type="text"
                                name="line_memo"
                                value={r.memo}
                                onChange={(e) => updateRow(r.key, { memo: e.target.value })}
                                className="w-full border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                        <button
                            type="button"
                            onClick={() => removeRow(r.key)}
                            disabled={rows.length <= 2}
                            className="text-red-600 hover:underline disabled:text-gray-400 px-2 py-2 text-sm"
                        >
                            {t('finance.removeLine')}
                        </button>
                    </div>
                ))}
            </div>

            <button
                type="button"
                onClick={addRow}
                className="border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 text-sm"
            >
                {t('finance.addLine')}
            </button>

            {/* 实时合计 + 平衡指示 */}
            <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.debit')}:</span>
                    <span className="font-mono font-medium">{formatAmount(sumDebit, baseCurrency)}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.credit')}:</span>
                    <span className="font-mono font-medium">{formatAmount(sumCredit, baseCurrency)}</span>
                </div>
                <span
                    className={
                        'px-2 py-1 rounded text-xs ' +
                        (balanced ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')
                    }
                >
                    {balanced
                        ? t('finance.balanceIndicator.balanced')
                        : t('finance.balanceIndicator.unbalanced')}
                </span>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('finance.submitEntry')}
                </button>
                <Link
                    href="/finance/journal"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}

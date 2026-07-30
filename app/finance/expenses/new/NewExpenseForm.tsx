'use client'

// 开支表单:费用科目(仅 active expense 科目)、金额/币种/汇率(默认 SGD ——
// 本地开销多为新币,与销售面板的 USD 默认刻意不同)、付款状态(默认挂账 ——
// 账单通常先到后付):paid → 银行账户(默认随币种,可改)+ 收款方(可选);
// unpaid → 供应商(必选,后续核销要用)。底部实时 USD 预览 + 将要生成的分录说明。
// 提交走 createExpense(rpc record_expense)。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { createExpense, type CreateExpenseState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { formatUsd } from '@/lib/format'

const initialState: CreateExpenseState = {}

export type AccountOption = { code: string; name: string }
export type SupplierOption = { id: string; name: string }

// 本地日期(YYYY-MM-DD),用作费用日期默认值(避免 UTC 偏移)。
function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

const round2 = (n: number) => Math.round(n * 100) / 100

export default function NewExpenseForm({
    accounts,
    suppliers,
}: {
    accounts: AccountOption[]
    suppliers: SupplierOption[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createExpense, initialState)

    const [accountCode, setAccountCode] = useState('')
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState('SGD') // 本地开销默认新币(销售面板默认 USD,刻意不同)
    const [fx, setFx] = useState('')
    const [paymentStatus, setPaymentStatus] = useState<'paid' | 'unpaid'>('unpaid')
    const [bank, setBank] = useState('1000') // 初始币种 SGD → 1000

    // 银行账户默认跟随币种(SGD → 1000,USD → 1010),之后仍可手动改
    function onCurrencyChange(c: string) {
        setCurrency(c)
        setBank(c === 'SGD' ? '1000' : '1010')
    }

    // 实时 USD 金额:round(amount × fx, 2),与 DB 同式;无效输入计 0
    const amountNum = Number(amount)
    const fxNum = currency === 'USD' ? 1 : Number(fx)
    const amountValid = !!amount && !Number.isNaN(amountNum) && amountNum > 0
    const fxValid = currency === 'USD' || (!!fx && !Number.isNaN(fxNum) && fxNum > 0)
    const amountUsd = amountValid && fxValid ? round2(amountNum * fxNum) : 0

    const accountLabel = accounts.find((a) => a.code === accountCode)
    const previewAccount = accountLabel ? `${accountLabel.code} ${accountLabel.name}` : '…'

    return (
        <form action={formAction} className="space-y-4">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                {/* 费用日期(默认今天)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('expense.form.date')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="expense_date"
                        required
                        defaultValue={todayIsoLocal()}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* 费用科目(仅 active expense 科目,按编码排序)*/}
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('expense.form.account')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="account_code"
                        required
                        value={accountCode}
                        onChange={(e) => setAccountCode(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>
                            {t('expense.form.selectAccount')}
                        </option>
                        {accounts.map((a) => (
                            <option key={a.code} value={a.code}>
                                {a.code} {a.name}
                            </option>
                        ))}
                    </select>
                </div>
            </div>

            <div className="flex flex-wrap gap-4">
                {/* 金额(必填,原币)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('expense.form.amount')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="number"
                        name="amount"
                        required
                        step="any"
                        min="0"
                        value={amount}
                        onChange={(e) => setAmount(e.target.value)}
                        className="w-36 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* 币种(默认 SGD)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('expense.form.currency')}</label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => onCurrencyChange(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="SGD">SGD</option>
                        <option value="USD">USD</option>
                    </select>
                </div>
                {/* 汇率(非 USD 必填)*/}
                {currency !== 'USD' && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('expense.form.fxRate')} <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="number"
                            name="fx_rate"
                            required
                            step="any"
                            min="0"
                            value={fx}
                            onChange={(e) => setFx(e.target.value)}
                            placeholder={t('output.sale.fxHint')}
                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                )}
                {/* 付款状态(默认挂账)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('expense.form.paymentStatus')}</label>
                    <select
                        name="payment_status"
                        value={paymentStatus}
                        onChange={(e) => setPaymentStatus(e.target.value === 'paid' ? 'paid' : 'unpaid')}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="unpaid">{t('expense.status.unpaid')}</option>
                        <option value="paid">{t('expense.status.paid')}</option>
                    </select>
                </div>
                {/* paid → 银行账户(默认随币种);unpaid → 供应商(必选)*/}
                {paymentStatus === 'paid' ? (
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('expense.form.bankAccount')}</label>
                        <select
                            name="bank_account"
                            value={bank}
                            onChange={(e) => setBank(e.target.value)}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="1000">{t('finance.bank.1000')}</option>
                            <option value="1010">{t('finance.bank.1010')}</option>
                        </select>
                    </div>
                ) : (
                    <div className="flex-1 min-w-[16rem]">
                        <label className="block text-sm font-medium mb-1">
                            {t('expense.form.supplier')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="supplier_id"
                            required
                            defaultValue=""
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="" disabled>
                                {t('expense.form.selectSupplier')}
                            </option>
                            {suppliers.map((s) => (
                                <option key={s.id} value={s.id}>
                                    {s.name}
                                </option>
                            ))}
                        </select>
                    </div>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                {/* 收款方(paid 时可选的自由文本)*/}
                {paymentStatus === 'paid' && (
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('expense.form.payeeName')}</label>
                        <input
                            type="text"
                            name="payee_name"
                            className="w-64 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                )}
                {/* 备注 */}
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('expense.form.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* 实时预览:USD 金额 + 将要生成的分录说明 */}
            <div className="bg-gray-50 rounded p-4 text-sm space-y-1">
                <div>
                    <span className="font-mono font-medium">
                        {t('expense.amountPreview', { amount: formatUsd(amountUsd) })}
                    </span>
                    {currency !== 'USD' && amountValid && fxValid && (
                        <span className="text-gray-500 ml-2 font-mono">
                            ({currency} {formatUsd(amountNum)} @ {fxNum})
                        </span>
                    )}
                </div>
                <p className="text-gray-500">
                    {paymentStatus === 'paid'
                        ? t('expense.previewPaid', {
                              account: previewAccount,
                              bank: t('finance.bank.' + bank),
                          })
                        : t('expense.previewUnpaid', { account: previewAccount })}
                </p>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('expense.form.submitting') : t('expense.form.submit')}
                </button>
                <Link
                    href="/finance/expenses"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}

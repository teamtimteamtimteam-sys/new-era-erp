'use client'

import { CounterpartyOptions } from '@/app/components/finance/counterpartyOptions'
// 开支表单:费用科目(仅 active expense 科目)、金额/币种/汇率(默认 SGD ——
// 本地开销多为新币,与销售面板的 USD 默认刻意不同)、付款状态(默认挂账 ——
// 账单通常先到后付):paid → 银行账户(默认随币种,可改)+ 收款方(可选);
// unpaid → 供应商(必选,后续核销要用)。底部实时 USD 预览 + 将要生成的分录说明。
// 提交走 createExpense(rpc record_expense)。
import { useActionState, useState } from 'react'
import { bankAccountFor, currencyOfBank } from '@/lib/currencyMap'
import Link from 'next/link'
import { createExpense, type CreateExpenseState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'

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
    employees,
    baseCurrency,
}: {
    accounts: AccountOption[]
    suppliers: SupplierOption[]
    employees: SupplierOption[]
    baseCurrency: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createExpense, initialState)

    const [accountCode, setAccountCode] = useState('')
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState('SGD') // 本地开销默认新币(销售面板默认 USD,刻意不同)
    const [paymentStatus, setPaymentStatus] = useState<'paid' | 'unpaid'>('unpaid')
    // FIN-22:资本性支出 —— 勾上后科目固定 1500(隐藏域),同一事务生成台账行
    const [capital, setCapital] = useState(false)
    const [residual, setResidual] = useState('')
    const [bank, setBank] = useState('1000') // 初始币种 SGD → 1000

    // 银行账户默认跟随币种(SGD → 1000,USD → 1010),之后仍可手动改
    function onCurrencyChange(c: string) {
        setCurrency(c)
        setBank(bankAccountFor(c))
    }

    // 实时预览只对本位币直给;外币的 SGD 值由当日牌价决定(DB 侧),预览不猜数
    const amountNum = Number(amount)
    const amountValid = !!amount && !Number.isNaN(amountNum) && amountNum > 0
    const amountSgd = currency === baseCurrency && amountValid ? round2(amountNum) : null

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
                {/* FIN-22:资本性支出开关 —— 勾上后借 1500 而不是费用科目,
                    同一事务生成固定资产台账行(资产不脱离应付/付款存在)*/}
                <div className="self-end pb-2">
                    <label className="inline-flex items-center gap-2 text-sm font-medium">
                        <input type="checkbox" name="capital" checked={capital}
                               onChange={(e) => setCapital(e.target.checked)} />
                        {t('expense.form.capital')}
                    </label>
                </div>
                {/* 费用科目(仅 active expense 科目,按编码排序);资本行固定 1500 */}
                {!capital ? (
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
                ) : (
                    <p className="flex-1 min-w-[16rem] self-end pb-2 text-sm text-gray-600">
                        {t('expense.form.capitalHint')}
                    </p>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                {/* 金额(必填,原币)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('expense.form.amount')} <span className="text-red-600">*</span>
                    </label>
                    <DecimalInput
                        name="amount"
                        required
                        value={amount}
                        onChange={setAmount}
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
                {/* FIN-0:外币按费用日行方卖出价(tt_sell)自动估值,当天没牌价直接拒 */}
                {currency !== baseCurrency && (
                    <p className="text-xs text-gray-500 self-end pb-2 max-w-56">{t('common.fxBoardRateHint')}</p>
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
                        {/* PAYEE-1b:挂账的往来对象 —— 供应商【或】员工(报销)。
                            一个下拉、两组选项:一次选择就是一个不可分割的答案,
                            没有第二个字段能和它矛盾(库里那条 XOR 的表单形态)。
                            默认仍是"请选择",供应商在前 —— 既有用法一步没变。 */}
                        <label className="block text-sm font-medium mb-1">
                            {t('expense.form.counterparty')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="counterparty"
                            required
                            defaultValue=""
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="" disabled>
                                {t('expense.form.selectCounterparty')}
                            </option>
                            <CounterpartyOptions
                                suppliers={suppliers}
                                employees={employees}
                                supplierLabel={t('finance.counterpartyKind.supplier')}
                                employeeLabel={t('finance.counterpartyKind.employee')}
                                employeesEmptyLabel={t('finance.employeesEmpty')} />
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

            {/* ── FIN-22:资产明细(仅资本行)。购置日 = 上面的费用日;
                在役日可留空(未投用不折旧),折旧从【在役日】起算 ── */}
            {capital && (
                <div className="border border-gray-300 rounded p-4 space-y-3">
                    <h3 className="text-sm font-bold text-gray-700">{t('expense.form.assetSection')}</h3>
                    <div className="flex flex-wrap gap-4">
                        <div className="flex-1 min-w-[16rem]">
                            <label className="block text-sm font-medium mb-1">
                                {t('assets.colDescription')} <span className="text-red-600">*</span>
                            </label>
                            <input type="text" name="asset_description" required={capital}
                                   className="w-full border border-gray-300 px-3 py-2 rounded" />
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('assets.colCategory')}</label>
                            <select name="asset_category" defaultValue="equipment"
                                    className="border border-gray-300 px-3 py-2 rounded">
                                <option value="equipment">{t('assets.category.equipment')}</option>
                                <option value="vehicle">{t('assets.category.vehicle')}</option>
                                <option value="office">{t('assets.category.office')}</option>
                                <option value="other">{t('assets.category.other')}</option>
                            </select>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('assets.colInService')}</label>
                            <input type="date" name="asset_in_service_date"
                                   className="border border-gray-300 px-3 py-2 rounded" />
                            <p className="text-xs text-gray-500 mt-1">{t('expense.form.inServiceHint')}</p>
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('assets.colLife')} <span className="text-red-600">*</span>
                            </label>
                            <input type="number" name="asset_life_months" min={1} step={1} required={capital}
                                   className="w-28 border border-gray-300 px-3 py-2 rounded" />
                        </div>
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('expense.form.residual', { ccy: baseCurrency })}
                            </label>
                            <DecimalInput name="asset_residual" value={residual} onChange={setResidual}
                                          className="w-32 border border-gray-300 px-3 py-2 rounded" />
                        </div>
                    </div>
                </div>
            )}

            {/* 实时预览:USD 金额 + 将要生成的分录说明 */}
            <div className="bg-gray-50 rounded p-4 text-sm space-y-1">
                <div>
                    <span className="font-mono font-medium">
                        {amountSgd !== null
                            ? t('expense.amountPreview', { amount: formatMoneyBare(amountSgd, '同句 amountPreview 文案「金额:{amount} {ccy}」里的 {ccy}'), ccy: baseCurrency })
                            : t('common.fxBoardRateHint')}
                    </span>
                    {currency !== baseCurrency && amountValid && (
                        <span className="text-gray-500 ml-2 font-mono">
                            ({currency} {formatMoneyBare(amountNum, '同格内紧邻的 {currency} 前缀')})
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

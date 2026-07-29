'use client'

// 收付款表单:方向切换(收=客户 / 付=供应商),币种↔银行账户联动(非 USD 出汇率输入),
// 选定往来单位后列出其未结单据逐张核销('fill' 快捷填充 = min(未结, 未冲销余额)),
// 底部实时 USD 款额 / 冲销合计 / 未冲销余额(>0 = 挂账,允许)。提交走 createPayment。
// NOTE: 两侧未结单据全量随 props 下发,此处按往来单位过滤 —— 免一次选择后的往返;
// 数据量小(未结清才进视图),体量上来再改按需加载。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { createPayment, type CreatePaymentState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { formatUsd } from '@/lib/format'

const initialState: CreatePaymentState = {}

export type PartyOption = { id: string; name: string }

export type OpenItem = {
    doc_id: string // in → sales_record_id / out → inbound_batch_id
    party_id: string
    doc_code: string
    doc_date: string
    open_usd: number
}

// 本地日期(YYYY-MM-DD),用作收付日期默认值(避免 UTC 偏移)。
function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

const round2 = (n: number) => Math.round(n * 100) / 100

export default function NewPaymentForm({
    customers,
    suppliers,
    arItems,
    apItems,
    initialDirection,
}: {
    customers: PartyOption[]
    suppliers: PartyOption[]
    arItems: OpenItem[]
    apItems: OpenItem[]
    initialDirection: 'in' | 'out'
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createPayment, initialState)

    const [direction, setDirection] = useState<'in' | 'out'>(initialDirection)
    const [partyId, setPartyId] = useState('')
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState('USD')
    const [fx, setFx] = useState('')
    const [bank, setBank] = useState('1010') // 初始币种 USD → 1010
    const [alloc, setAlloc] = useState<Record<string, string>>({})

    // 方向切换清空往来单位与核销;换往来单位清空核销
    function onDirectionChange(d: 'in' | 'out') {
        setDirection(d)
        setPartyId('')
        setAlloc({})
    }
    function onPartyChange(id: string) {
        setPartyId(id)
        setAlloc({})
    }
    // 银行账户默认跟随币种(SGD → 1000,USD → 1010),之后仍可手动改
    function onCurrencyChange(c: string) {
        setCurrency(c)
        setBank(c === 'SGD' ? '1000' : '1010')
    }

    const parties = direction === 'in' ? customers : suppliers
    const items = (direction === 'in' ? arItems : apItems).filter((i) => i.party_id === partyId)

    // 实时 USD 款额:round(amount × fx, 2),与 DB 同式;无效输入计 0
    const amountNum = Number(amount)
    const fxNum = currency === 'USD' ? 1 : Number(fx)
    const amountValid = !!amount && !Number.isNaN(amountNum) && amountNum > 0
    const fxValid = currency === 'USD' || (!!fx && !Number.isNaN(fxNum) && fxNum > 0)
    const payUsd = amountValid && fxValid ? round2(amountNum * fxNum) : 0

    const allocValue = (docId: string) => {
        const v = Number(alloc[docId])
        return alloc[docId] && !Number.isNaN(v) && v > 0 ? v : 0
    }
    const totalAllocated = round2(items.reduce((s, i) => s + allocValue(i.doc_id), 0))
    const unallocated = round2(payUsd - totalAllocated)

    // fill:该行填到 min(未结额, 未冲销余额[不计本行])
    function fill(item: OpenItem) {
        const others = totalAllocated - allocValue(item.doc_id)
        const remaining = Math.max(0, round2(payUsd - others))
        const v = Math.min(item.open_usd, remaining)
        setAlloc((a) => ({ ...a, [item.doc_id]: v > 0 ? String(v) : '' }))
    }

    return (
        <form action={formAction} className="space-y-4">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                {/* 方向 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('finance.side')}</label>
                    <select
                        name="direction"
                        value={direction}
                        onChange={(e) => onDirectionChange(e.target.value === 'out' ? 'out' : 'in')}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="in">{t('finance.direction.in')}</option>
                        <option value="out">{t('finance.direction.out')}</option>
                    </select>
                </div>
                {/* 往来单位(必填;收=客户,付=供应商)*/}
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.colCounterparty')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="counterparty_id"
                        required
                        value={partyId}
                        onChange={(e) => onPartyChange(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>
                            {t('finance.selectCounterparty')}
                        </option>
                        {parties.map((p) => (
                            <option key={p.id} value={p.id}>
                                {p.name}
                            </option>
                        ))}
                    </select>
                </div>
            </div>

            <div className="flex flex-wrap gap-4">
                {/* 金额(必填,原币)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.amount')} <span className="text-red-600">*</span>
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
                {/* 币种 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.sale.currency')}</label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => onCurrencyChange(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="USD">USD</option>
                        <option value="SGD">SGD</option>
                    </select>
                </div>
                {/* 汇率(非 USD 必填)*/}
                {currency !== 'USD' && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('output.sale.fxRate')} <span className="text-red-600">*</span>
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
                {/* 银行账户(默认随币种)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('finance.bankAccount')}</label>
                    <select
                        name="bank_account"
                        value={bank}
                        onChange={(e) => setBank(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="1010">{t('finance.bank.1010')}</option>
                        <option value="1000">{t('finance.bank.1000')}</option>
                    </select>
                </div>
                {/* 收付日期(默认今天)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.paymentDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="payment_date"
                        required
                        defaultValue={todayIsoLocal()}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* 备注 */}
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('finance.memo')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* 核销:选定往来单位后列其未结单据 */}
            {partyId && (
                items.length > 0 ? (
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDocument')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDate')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colOpen')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colAllocate')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {items.map((i) => (
                                <tr key={i.doc_id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">{i.doc_code}</td>
                                    <td className="border border-gray-300 px-4 py-2">{i.doc_date}</td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatUsd(i.open_usd)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        <input type="hidden" name="alloc_id" value={i.doc_id} />
                                        <input
                                            type="number"
                                            name="alloc_amount"
                                            step="any"
                                            min="0"
                                            max={i.open_usd}
                                            value={alloc[i.doc_id] ?? ''}
                                            onChange={(e) =>
                                                setAlloc((a) => ({ ...a, [i.doc_id]: e.target.value }))
                                            }
                                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                                        />
                                        <button
                                            type="button"
                                            onClick={() => fill(i)}
                                            className="ml-2 text-blue-600 hover:underline text-sm"
                                        >
                                            {t('finance.fillAll')}
                                        </button>
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                ) : (
                    <p className="text-sm text-gray-500">{t('finance.noOpenItems')}</p>
                )
            )}

            {/* 实时合计:USD 款额 / 冲销合计 / 未冲销(>0 = 挂账,允许)*/}
            <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colAmount')}:</span>
                    <span className="font-mono font-medium">{formatUsd(payUsd)}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.totalAllocated')}:</span>
                    <span className="font-mono font-medium">{formatUsd(totalAllocated)}</span>
                </div>
                <div className={unallocated < 0 ? 'text-red-600' : 'text-gray-500'}>
                    <span className="mr-1">{t('finance.unallocated')}:</span>
                    <span className="font-mono">{formatUsd(unallocated)}</span>
                </div>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('finance.submitPayment')}
                </button>
                <Link
                    href="/finance/payments"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}

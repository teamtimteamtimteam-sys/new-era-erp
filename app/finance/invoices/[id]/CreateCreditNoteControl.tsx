'use client'

// CN-1:开一张贷项凭证的表单。
//
// 【本表单不自己判断能冲多少】三条天花板在服务端,拒绝由数据库按名给出。
// 这里做的只有三件事:
//   * 把【两个上限】写在行上 —— 未释放的负债 / 已释放的收入,两个数对应两种
//     完全不同的事,而"这一行还能冲多少"取决于你选哪一种(CMP-2);
//   * 类型是【选出来的,不是猜出来的】—— 少发了货与事后减价过的账不同科目,
//     让系统按"有没有发货"替人选,就是替他做了一个会计判断;
//   * 后果句在按下之前:这张凭证会减少客户在【这张发票】上欠的钱。
// 表单上的提示是【礼貌】,不是保护。
import { useActionState, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { createCreditNote, type CreditNoteState } from './creditNoteActions'

export type CnLineOption = {
    id: string
    line_no: number
    description: string
    unit: string
    amount_ccy: number
    /** null = 看不到发货(module.sales.view 缺席),不是 0 */
    unreleased: number | null
    releasedRemaining: number | null
}

const initialState: CreditNoteState = {}

export default function CreateCreditNoteControl({
    invoiceId, invoiceCode, currency, openCcy, lines,
}: {
    invoiceId: string; invoiceCode: string; currency: string
    openCcy: number; lines: CnLineOption[]
}) {
    const t = useTranslations()
    const bound = createCreditNote.bind(null, invoiceId)
    const [state, formAction, isPending] = useActionState(bound, initialState)
    const [open, setOpen] = useState(false)
    const [noteDate, setNoteDate] = useState('')
    const [kind, setKind] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, 'unshipped_cancel'])))
    const [amount, setAmount] = useState<Record<string, string>>({})

    const entered = lines
        .map((l) => ({ l, n: Number(amount[l.id] ?? '') }))
        .filter((x) => (amount[x.l.id] ?? '').trim() !== '' && !Number.isNaN(x.n))
    const total = Math.round(entered.reduce((s, x) => s + x.n, 0) * 100) / 100
    const overOpen = total > openCcy
    // 【日期空着就不给按】它决定冲销落进哪个会计期间,而服务端也【独立】拒空
    // (AGENTS.md:两道闸,UI 那道不是保护)。
    const blocked = noteDate.trim() === '' || entered.length === 0 || overOpen

    if (!open) {
        return (
            <button type="button" onClick={() => setOpen(true)}
                    className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50">
                {t('cn.create')}
            </button>
        )
    }

    return (
        <form action={formAction} className="border border-gray-300 rounded p-3 space-y-3">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded text-sm">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap items-end gap-4">
                <div>
                    <label className="block text-xs text-gray-600 mb-1">
                        {t('cn.noteDate')} <span className="text-red-600">*</span>
                    </label>
                    <input type="date" name="note_date" value={noteDate}
                           onChange={(e) => setNoteDate(e.target.value)}
                           className="border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-xs text-gray-600 mb-1">
                        {t('cn.reason')} <span className="text-red-600">*</span>
                    </label>
                    <input type="text" name="reason" required
                           className="w-full border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
            </div>
            <p className="text-xs text-gray-500">{t('cn.noteDateHint')}</p>

            <table className="w-full border-collapse border border-gray-300 text-sm">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-2 py-2 text-left">#</th>
                        <th className="border border-gray-300 px-2 py-2 text-left">{t('cn.colLine')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">{t('cn.colUnreleased')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">{t('cn.colReleased')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-left">{t('cn.colKind')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">{t('cn.colQty')}</th>
                        <th className="border border-gray-300 px-2 py-2 text-right">{t('cn.colAmount', { ccy: currency })}</th>
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l) => {
                        const k = kind[l.id] ?? 'unshipped_cancel'
                        const ceiling = k === 'unshipped_cancel' ? l.unreleased : l.releasedRemaining
                        const n = Number(amount[l.id] ?? '')
                        const over = (amount[l.id] ?? '').trim() !== '' && ceiling !== null && n > ceiling
                        return (
                            <tr key={l.id}>
                                <td className="border border-gray-300 px-2 py-2">
                                    {l.line_no}
                                    <input type="hidden" name="cn_line_id" value={l.id} />
                                    <input type="hidden" name="cn_kind" value={k} />
                                </td>
                                <td className="border border-gray-300 px-2 py-2">{l.description}</td>
                                <td className="border border-gray-300 px-2 py-2 text-right font-mono text-xs">
                                    {l.unreleased === null
                                        ? <span className="font-sans text-gray-500">{t('common.restricted')}</span>
                                        : formatMoneyBare(l.unreleased, '同表列头 冲减({ccy}),整张表单同一个币种')}
                                </td>
                                <td className="border border-gray-300 px-2 py-2 text-right font-mono text-xs">
                                    {l.releasedRemaining === null
                                        ? <span className="font-sans text-gray-500">{t('common.restricted')}</span>
                                        : formatMoneyBare(l.releasedRemaining, '同表列头 冲减({ccy}),整张表单同一个币种')}
                                </td>
                                <td className="border border-gray-300 px-2 py-2">
                                    <select value={k}
                                            onChange={(e) => setKind((s) => ({ ...s, [l.id]: e.target.value }))}
                                            className="border border-gray-300 px-1 py-1 rounded text-xs">
                                        <option value="unshipped_cancel">{t('cn.kind.unshipped_cancel')}</option>
                                        <option value="revenue_reduction">{t('cn.kind.revenue_reduction')}</option>
                                    </select>
                                </td>
                                <td className="border border-gray-300 px-2 py-2 text-right">
                                    {/* 【数量可空,而且这不是偷懒】一次整批折让往往不对应
                                        任何数量,硬要一个就得编一个 —— 金额才是主语 */}
                                    <input type="number" step="any" min="0" name="cn_qty"
                                           className="w-20 border border-gray-300 px-1 py-1 rounded text-right text-xs" />
                                </td>
                                <td className="border border-gray-300 px-2 py-2 text-right">
                                    <input type="number" step="any" min="0" name="cn_amount"
                                           value={amount[l.id] ?? ''}
                                           onChange={(e) => setAmount((s) => ({ ...s, [l.id]: e.target.value }))}
                                           className="w-24 border border-gray-300 px-1 py-1 rounded text-right" />
                                    {over && (
                                        <p className="text-xs text-red-600 mt-1">
                                            {t('cn.overCeiling', { ceiling: formatMoneyBare(ceiling as number, '同表列头 冲减({ccy}),整张表单同一个币种') })}
                                        </p>
                                    )}
                                </td>
                            </tr>
                        )
                    })}
                </tbody>
            </table>

            <div className="flex flex-wrap items-baseline gap-x-4 text-sm">
                <span>
                    <span className="text-gray-600">{t('cn.totalLabel')}:</span>{' '}
                    <span className="font-mono">{formatAmount(total, currency)}</span>
                </span>
                <span className="text-gray-500">
                    {t('cn.openLabel', { amount: formatMoneyBare(openCcy, '本句里紧跟着 {ccy}'), ccy: currency })}
                </span>
            </div>
            {overOpen && <p className="text-xs text-red-600">{t('cn.overOpen')}</p>}

            {/* 【后果句在按下之前】—— 这张凭证会过账,而凭证只增不改 */}
            <p className="text-xs text-gray-600">{t('cn.consequence', { code: invoiceCode })}</p>

            <div className="flex gap-3">
                <button type="submit" disabled={isPending || blocked}
                        className="bg-blue-600 text-white px-3 py-1 rounded text-sm hover:bg-blue-700 disabled:bg-gray-400">
                    {isPending ? t('common.saving') : t('cn.submit')}
                </button>
                <button type="button" onClick={() => setOpen(false)}
                        className="border border-gray-300 px-3 py-1 rounded text-sm hover:bg-gray-50">
                    {t('common.cancel')}
                </button>
            </div>
            {noteDate.trim() === '' && <p className="text-xs text-amber-700">{t('cn.blockedNoDate')}</p>}
        </form>
    )
}

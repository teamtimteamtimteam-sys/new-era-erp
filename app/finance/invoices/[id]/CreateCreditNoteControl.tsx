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
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { tableC } from '@/app/components/ui/table-style'

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
canEdit
}: {
    invoiceId: string; invoiceCode: string; currency: string
    openCcy: number; lines: CnLineOption[]

canEdit: boolean
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
            <PermissionGate code="module.finance.edit" allowed={canEdit}>
            <Button type="button" onClick={() => setOpen(true)}
                    variant="secondary">
                {t('cn.create')}
            </Button>
            </PermissionGate>
        )
    }

    // 【这张表单不再单独上闸】上面那个"新建"钮已经上了闸,没有权限的人打不开它;
    // 而给整张表单上闸会连它自己的「取消」一起禁掉 —— 把人困在一张既提交不了、
    // 也关不掉的表单里。闸放在【打得开它的那个钮】上。
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

            {/* ════════════════════════════════════════════════════════════════
                ★ TABLE-PHONE-4:七列 → 手机档留四列(# · 发票行 · 数量 · 冲减)。
                被拿掉的三列(尚未交付 / 已交付、可冲减 / 类型)一个字段都没丢:
                带着各自的列头叠在「发票行」那一格里,见下面 sm:hidden 的那一块。

                ★★【为什么留的是「数量」而不是「类型」—— 这不是取舍,是【正确性】★★
                `cn_qty` 是并列数组的一员(cn_line_id / cn_kind / cn_qty / cn_amount
                按下标配对)。折叠一列是用 CSS 藏,【藏起来的 input 照样提交】——
                把 cn_qty 画两遍就等于每行往那个数组里塞两格,整组配对当场错位。
                于是凡是带 name 的输入框,这一刀一律【留在看得见的那四列里】。
                而「类型」那个 <select> 自己【不带 name】:它的值由第一格里那个
                单独渲染一次的 <input type="hidden" name="cn_kind"> 携带,
                所以它画两遍是安全的 —— 两份都受同一个 kind[l.id] 控制。
                ☞ 代价说清楚:类型决定用哪个上限,收进折叠区意味着改它要多滚一下。
                  拿正确性换这一下,换得起。
                ════════════════════════════════════════════════════════════════ */}
            <table className={`${tableC.root} w-full`}>
                <thead>
                    <tr className={tableC.headRow}>
                        <th className={`${tableC.headCell} text-left`}>#</th>
                        <th className={`${tableC.headCell} text-left`}>{t('cn.colLine')}</th>
                        <th className={`${tableC.headCell} hidden sm:table-cell text-right`}>{t('cn.colUnreleased')}</th>
                        <th className={`${tableC.headCell} hidden sm:table-cell text-right`}>{t('cn.colReleased')}</th>
                        <th className={`${tableC.headCell} hidden sm:table-cell text-left`}>{t('cn.colKind')}</th>
                        <th className={`${tableC.headCell} text-right`}>{t('cn.colQty')}</th>
                        <th className={`${tableC.headCell} text-right`}>{t('cn.colAmount', { ccy: currency })}</th>
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l) => {
                        const k = kind[l.id] ?? 'unshipped_cancel'
                        const ceiling = k === 'unshipped_cancel' ? l.unreleased : l.releasedRemaining
                        const n = Number(amount[l.id] ?? '')
                        const over = (amount[l.id] ?? '').trim() !== '' && ceiling !== null && n > ceiling
                        // ★ TABLE-PHONE-4:两档共用的写法【提出来写一次】——
                        //   把控件抄成两份就是让两份将来各走各的,而漂移在桌面上是看不见的
                        //   (桌面那一份永远是对的那一份)。提一次,两处引用同一个描述。
                        const unreleasedText = l.unreleased === null
                            ? <span className="font-sans text-gray-500">{t('common.restricted')}</span>
                            : formatMoneyBare(l.unreleased, '同表列头 冲减({ccy}),整张表单同一个币种')
                        const releasedText = l.releasedRemaining === null
                            ? <span className="font-sans text-gray-500">{t('common.restricted')}</span>
                            : formatMoneyBare(l.releasedRemaining, '同表列头 冲减({ccy}),整张表单同一个币种')
                        // 这个 <select> 【不带 name】,值由第一格那个渲染一次的 hidden input 携带,
                        // 所以两档各画一份是安全的;两份共用同一个 k / setKind。
                        const kindSelect = (
                            <select value={k}
                                    onChange={(e) => setKind((s) => ({ ...s, [l.id]: e.target.value }))}
                                    className="border border-gray-300 px-1 py-1 rounded text-xs">
                                <option value="unshipped_cancel">{t('cn.kind.unshipped_cancel')}</option>
                                <option value="revenue_reduction">{t('cn.kind.revenue_reduction')}</option>
                            </select>
                        )
                        return (
                            <tr className={tableC.bodyRow} key={l.id}>
                                <td className={tableC.cell}>
                                    {l.line_no}
                                    <input type="hidden" name="cn_line_id" value={l.id} />
                                    <input type="hidden" name="cn_kind" value={k} />
                                </td>
                                <td className={tableC.cell}>
                                    {l.description}
                                    {/* ★ TABLE-PHONE-4:手机档拿掉的三列,带着各自的列头叠在这里。
                                        类型是个能点的控件,所以它单独占一行、标签在左、控件在右 ——
                                        一个被挤在窄缝里的 <select> 不算"还能用"。 */}
                                    <div className="sm:hidden mt-1 space-y-1 font-sans text-xs text-gray-600">
                                        <div className="font-mono">
                                            <span className="font-sans text-gray-500">{t('cn.colUnreleased')}: </span>
                                            {unreleasedText}
                                        </div>
                                        <div className="font-mono">
                                            <span className="font-sans text-gray-500">{t('cn.colReleased')}: </span>
                                            {releasedText}
                                        </div>
                                        <div className="flex items-center gap-1">
                                            <span className="text-gray-500 shrink-0">{t('cn.colKind')}: </span>
                                            {kindSelect}
                                        </div>
                                    </div>
                                </td>
                                <td className={`${tableC.cell} hidden sm:table-cell text-right font-mono`}>
                                    {unreleasedText}
                                </td>
                                <td className={`${tableC.cell} hidden sm:table-cell text-right font-mono`}>
                                    {releasedText}
                                </td>
                                <td className={`${tableC.cell} hidden sm:table-cell`}>
                                    {kindSelect}
                                </td>
                                <td className={`${tableC.cell} text-right`}>
                                    {/* 【数量可空,而且这不是偷懒】一次整批折让往往不对应
                                        任何数量,硬要一个就得编一个 —— 金额才是主语 */}
                                    <input type="number" step="any" min="0" name="cn_qty"
                                           className="w-20 border border-gray-300 px-1 py-1 rounded text-right text-xs" />
                                </td>
                                <td className={`${tableC.cell} text-right`}>
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
                <Button type="submit" disabled={isPending || blocked}>
                    {isPending ? t('common.saving') : t('cn.submit')}
                </Button>
                <Button type="button" onClick={() => setOpen(false)}
                        variant="secondary">
                    {t('common.cancel')}
                </Button>
            </div>
            {noteDate.trim() === '' && <p className="text-xs text-amber-700">{t('cn.blockedNoDate')}</p>}
        </form>
    )
}

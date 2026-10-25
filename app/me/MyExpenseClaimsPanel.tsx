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
//
// ★ TABLE-CONVERT-1(2026-09-10):手搓表格 → 组件。
//   【手机上留哪几列一个字没改 —— 而它今天是【四】列,不是三列】
//     留:单号 · 金额 · 状态 · 撤回钮那一列;折:消费日 · 事由。
//   ★★ 撤回钮那一列是 priority,而这是【接着 TABLE-STYLE-1 / R1 往下走】:
//     那一刀(Tim 裁定,2026-09-09)把这一列从「折进单号格」改回了「自己留在
//     明面上」,理由是【够不着的动作等于不存在】。在组件里"折"意味着那颗钮
//     落进展开区 —— 要先点开一行才够得着。所以它必须 priority:true,
//     否则这一次转换会把上一刀刚做的裁定悄悄撤销。规矩的出处见
//     docs/base-components.md §二十.1 与 Column.priority 的抬头。
//   ☞ TABLE-CONVERT-0 普查 §5 那一行把撤回钮记成【折进去了】—— 那份普查
//     跑在 TABLE-STYLE-1 落地【之前】,记的是当时的源码。**以今天的源码为准。**
//   叠在单号格里那一段手写的展开块【拿掉了】:组件自己画那一段。
//
// ★ EMP-SELF-1(G2,Tim 2026-09-27):多一列「决定」(谁、何时、备注,DecisionCell)。
//   备注此前叠在「事由」格里;现在它跟着决定人走,于是从事由格里拿掉 —— 同一句话不在一行里出现两次。
//
// ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q4–Q7 · Q10):一张报销单 = 一句用途 + 一个币种 + 若干笔明细
//   (每一笔:哪天 · 收据上的金额 · 说明 · 没有收据时的理由)。同一个日历月;外币的单所有明细同一天 —— 两条都由
//   submit_expense_claim_items 按名拒,这里不再判一遍。在 CLAIM-RECEIPTS-1 之前员工传不了收据,所以每一笔都要写理由。
//   这张表单【没有】草稿(Step 0b Q10)。
// ★ CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q2 · Q3 · Q5 · Q9 · Q12):每一笔有它自己的文件选择框(一份或几份);提交之后紧接着逐份传
//   (照片先在浏览器里缩成 JPEG,PDF 原样);一份传失败,在下面的表里那一笔上重试。每一笔要么有文件、要么有无收据理由,才按得下提交 ——
//   库在批准时照样逐笔查。表里每一笔列出它的收据,单还在 submitted 时可以再加、可以拿掉一份(Q5)。
import { CONTROL_INPUT, CONTROL_FILE_BUTTON } from '@/app/components/ui/control-style'
import { useState, useTransition, type ReactNode } from 'react'
import { useRouter } from 'next/navigation'
import { submitClaim, withdrawClaim } from '@/app/finance/claims/actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { businessToday } from '@/lib/format'  // DATE-PICK-1:日期框的上限按新加坡的今天,与服务端拒「将来」的那一天同一天
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney, xDate } from '@/lib/export/cells'
import DecisionCell, { decisionText, type Decision } from './DecisionCell'
import { useSortHref } from '@/app/components/ui/use-sort-href'
import type { ListSort } from '@/lib/listSort'
import ClaimReceipts, { PREPARE_FAILURE_KEYS, type ReceiptRow } from './ClaimReceipts'
import { prepareReceipt, uploadReceipt, RECEIPT_ACCEPT, type ReceiptLimits } from './uploadClaimReceipt'

export type MyClaimItem = {
    id: string; line_no: number; spend_date: string; amount_ccy: number; description: string; no_receipt_reason: string | null
    /** TABLE-EXPORT-2b-1:这一笔有没有 attached 的收据(meRows.ts 挂上来;导出取到的单可能不在 receipts 那份清单里) */
    has_receipt: boolean
}
type Row = {
    claim_id: string; code: string; spend_date: string; amount_ccy: number
    currency: string; description: string; status: string
    is_owing: boolean; is_paid: boolean
    decision_notes: string | null
    // EXPENSE-MULTILINE-1:明细(页面另读 expense_claim_items,按单挂上来)
    items: MyClaimItem[]
    expense_reversed: boolean | null
    // CLAIM-GST-1:批准之后那张费用单上的净额与税(expense_claim_status 末尾追加的两列)
    expense_net_ccy: number | null; expense_tax_ccy: number | null
}

const money = (n: number) =>
    Number(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

// AUDIT-TRAIL-1c-3(Tim 的 Q20 的另一半):表下面一张一行,点开是这张报销单的审计记录 —— 报销人自己读(my_expense_claim,M8:
//   没有页面码,报销单自己的读规则就是门)。审批留痕那一支不给本人开口子,所以那几行是 Restricted(Q4);谁决定的、为什么,
//   本人在表里的「决定」一格已经看得到(EMP-SELF-1)。
export default function MyExpenseClaimsPanel({
    employeeId, rows, total, sort, exportHref, baseCurrency, decisions, trails = {}, receipts = [], limits = null,
}: {
    employeeId: string | null; rows: Row[]; baseCurrency: string; decisions: Record<string, Decision>; trails?: Record<string, ReactNode>
    /** TABLE-EXPORT-2b-1(Tim Q2 · Q5):自己的费用报销一共几张 —— 页面只画最近 50 张,多出来就说出来;导出走路由取全 */
    total: number
    /** TABLE-FEATURES-1 Q9:在数据库里排(meRows.ts 的 MY_EXPENSE_SORT,参数前缀 `exp_`);导出地址带同一个顺序 */
    sort: ListSort
    exportHref: string
    /** CLAIM-RECEIPTS-1:这几张单上 attached 的收据(页面另读 expense_claim_receipts) */
    receipts?: ReceiptRow[]
    /** CLAIM-RECEIPTS-1:收据的上限(claim_receipt_limits —— 与门户同一个数) */
    limits?: ReceiptLimits | null
}) {
    const t = useTranslations()
    const router = useRouter()
    // TABLE-FEATURES-1 Q9:换顺序之后落回这一块(#claims),不跳回页顶
    const expSortHref = useSortHref('exp_')
    const sortHref = (key: string, dir: 'asc' | 'desc') => `${expSortHref(key, dir)}#claims`
    const [open, setOpen] = useState(false)
    // 【花钱那天不预填】—— 一个决定成本落在哪个期间的日期,预填就是奖励留空;
    // 服务端也独立地拒空(合取,不是二选一)。逐笔。
    type ItemDraft = { key: string; spendDate: string; bad: boolean; amount: string; description: string; noReceipt: string; files: File[] }
    const blankItem = (): ItemDraft => ({ key: Math.random().toString(36).slice(2), spendDate: '', bad: false, amount: '', description: '', noReceipt: '', files: [] })
    const [items, setItems] = useState<ItemDraft[]>(() => [blankItem()])
    const setItem = (key: string, patch: Partial<ItemDraft>) => setItems((xs) => xs.map((x) => (x.key === key ? { ...x, ...patch } : x)))
    const [purpose, setPurpose] = useState('')
    const [currency, setCurrency] = useState(baseCurrency)
    const [error, setError] = useState<string | null>(null)
    const [notice, setNotice] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    // Q12:每一笔要么有文件、要么有无收据理由(库在批准时照样逐笔查)
    const canSubmit = purpose.trim() !== '' && items.every((x) => x.spendDate !== '' && !x.bad && x.amount !== '' && x.description.trim() !== ''
        && (x.files.length > 0 || x.noReceipt.trim() !== ''))
    const reset = () => { setItems([blankItem()]); setPurpose('') }

    /* 撤回钮。TABLE-PHONE-3 当时把它写成一个共用的画法,是因为同一颗钮要在两个
       断点各画一次(桌面在自己那一列,手机叠在「单号」格里);TABLE-STYLE-1 之后
       它【只画一次】了 —— 那一列在两个断点都留在明面上。
       ☞ 留着这个具名的画法,是因为它现在就是那一列的 render。
       动作与它自己的 submitted 判定一个字没改。 */
    // ★ OVERTIME-1 折进来的(EMP-SELF-1 决定 1 被 Tim 的 Q21 推翻):撤不了的行【不再藏钮】——
    //   已批准的那一行,钮看得见、按不动,旁边一行说为什么(与医疗申报那块同一句话、同一个样子)。
    //   驳回的与已撤回的不画任何控件:那里没有一个被拒绝的动作(医疗那块的先例)。
    const withdrawControl = (r: (typeof rows)[number]) =>
        r.status === 'submitted' ? (
            <Button variant="reversal" size="xs" type="button" disabled={pending}
                onClick={() => {
                    setError(null)
                    startTransition(async () => {
                        const x = await withdrawClaim(r.claim_id)
                        if (x.error) setError(x.error)
                    })
                }}
                title={t('expenseClaims.withdrawHint')}>
                {t('expenseClaims.withdraw')}
            </Button>
        ) : r.status === 'approved' ? (
            <>
                <Button variant="reversal" size="xs" type="button" disabled>{t('expenseClaims.withdraw')}</Button>
                <span className="block text-xs text-[color:var(--brand-muted-text)] max-w-[14rem] ml-auto">
                    {t('expenseClaims.withdrawDecidedReason')}
                </span>
            </>
        ) : null

    // 一笔的凭据那半句:格子与导出共用
    const receiptNote = (it: MyClaimItem) =>
        it.has_receipt ? t('expenseClaims.hasReceipt')
            : it.no_receipt_reason ? `${t('expenseClaims.noReceipt')}: ${it.no_receipt_reason}`
                : t('expenseClaims.noReceipt')
    const columns: ExportableColumn<Row>[] = [
        { key: 'ref', sortable: true, header: t('expenseClaims.colRef'), priority: true, render: (r) => r.code, exportAs: (r) => xText(r.code) },
        {
            key: 'spent', sortable: true, header: t('expenseClaims.colSpent'),
            render: (r) => r.spend_date,
            exportAs: (r) => xDate(r.spend_date),
        },
        {
            key: 'description', header: t('expenseClaims.colDescription'),
            // TABLE-EXPORT-2b-1:组合格 —— 用途,然后逐笔照屏幕那一行写(第 n 笔 · 说明 · 金额 — 有收据 / 无收据理由),一格文字
            exportAs: (r) => xText([r.description, ...r.items.map((it) =>
                `${t('expenseClaims.itemNo', { n: it.line_no })} · ${it.description} · ${money(it.amount_ccy)} — ${receiptNote(it)}`)].join('; ')),
            render: (r) => (
                <>
                    {r.description}
                    {/* EXPENSE-MULTILINE-1:用途之下逐笔 —— 说明、金额与它的凭据 */}
                    {r.items.map((it) => (
                        <span key={it.line_no} className="block text-xs text-gray-500">
                            {t('expenseClaims.itemNo', { n: it.line_no })} · {it.description} · {money(it.amount_ccy)}
                            {' — '}
                            {receiptNote(it)}
                            {/* CLAIM-RECEIPTS-1:这一笔的收据;单还在 submitted 时可以再加、可以拿掉(Q5 · Q9) */}
                            <ClaimReceipts itemId={it.id} receipts={receipts.filter((x) => x.item_id === it.id)}
                                canUpload={r.status === 'submitted'} limits={limits} />
                        </span>
                    ))}
                </>
            ),
        },
        {
            key: 'amount', header: t('expenseClaims.colAmount'), align: 'right', priority: true,
            // CLAIM-GST-1:报的是含税总额;批准之后说出它被拆成了什么 —— 读落库的两个数,不在这里再算。
            // 导出写含税总额这一个数(带币种);下面那行净额 / 税拆分是附注,不进这一格(一格一个值)
            exportAs: (r) => xMoney(r.amount_ccy, r.currency),
            render: (r) => (
                <>
                    {money(r.amount_ccy)} {r.currency}
                    {r.expense_tax_ccy != null && Number(r.expense_tax_ccy) > 0 && r.expense_net_ccy != null && (
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">
                            {t('expenseClaims.splitNetGst', { net: money(r.expense_net_ccy), tax: money(r.expense_tax_ccy) })}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'status', sortable: true, header: t('expenseClaims.colStatus'), priority: true,
            // 状态之下那一行(已冲销 / 欠付 / 已付)是字,不是样式 —— 一起写进这一格
            exportAs: (r) => xText([t('expenseClaims.status_' + r.status),
                r.expense_reversed ? t('expenseClaims.reversed') : null,
                !r.expense_reversed && r.is_owing ? t('expenseClaims.owing') : null,
                !r.expense_reversed && r.is_paid ? t('expenseClaims.paid') : null].filter(Boolean).join(' · ')),
            render: (r) => (
                <>
                    {t('expenseClaims.status_' + r.status)}
                    {r.expense_reversed && (
                        <span className="block text-xs text-red-700">{t('expenseClaims.reversed')}</span>
                    )}
                    {!r.expense_reversed && r.is_owing && (
                        <span className="block text-xs text-amber-800">{t('expenseClaims.owing')}</span>
                    )}
                    {!r.expense_reversed && r.is_paid && (
                        <span className="block text-xs text-green-700">{t('expenseClaims.paid')}</span>
                    )}
                </>
            ),
        },
        {
            key: 'decision', header: t('me.decisionCol'),
            render: (r) => <DecisionCell decision={decisions[r.claim_id]} cancelled={false} />,
            exportAs: (r) => xText(decisionText(t, decisions[r.claim_id], false)),
        },
        // ★ 动作列 —— 空列头与转换之前逐字相同,priority 的理由见抬头。
        { key: 'actions', header: '', align: 'right', priority: true, render: withdrawControl, exportAs: false },
    ]

    return (
        <section className="mb-8">
            <h2 className="mb-1">{t('expenseClaims.myTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">{t('expenseClaims.myHint')}</p>
            {/* 【备用金是被否决的,不是没做】—— 让读的人遇到一个决定,而不是一个缺口 */}
            <p className="text-xs text-gray-400 mb-3">{t('expenseClaims.pettyCashRuledOut')}</p>

            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            {notice && (
                <div className="mb-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">{notice}</div>
            )}

            {employeeId && !open && (
                <Button variant="default" className="mb-3 text-sm" type="button" onClick={() => setOpen(true)}>
                    {t('expenseClaims.submit')}
                </Button>
            )}
            {employeeId && open && (
                <div className="mb-4 max-w-3xl space-y-3 rounded border border-gray-300 p-3">
                    <div className="flex flex-wrap items-end gap-3">
                        <label className="min-w-0 flex-1 basis-64">{t('expenseClaims.purpose')}
                            <input value={purpose} onChange={(e) => setPurpose(e.target.value)}
                                className={`${CONTROL_INPUT} block w-full`} />
                            <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.purposeHint')}</span></label>
                        <label className="">{t('expenseClaims.currency')}
                            <input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())}
                                className={`${CONTROL_INPUT} block w-20`} /></label>
                    </div>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.itemsHint')}</p>
                    {items.map((x, n) => (
                        <div key={x.key} className="flex flex-wrap items-end gap-3 rounded border border-gray-200 p-2">
                            <span className="w-full text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.itemNo', { n: n + 1 })}</span>
                            <label className="">{t('expenseClaims.spendDate')}
                                <DatePicker value={x.spendDate} max={businessToday()}
                                    onChange={(v) => setItem(x.key, { spendDate: v })}
                                    onInvalidChange={(bad) => setItem(x.key, { bad })}
                                    className="flex" /></label>
                            <label className="">{t('expenseClaims.amount')}
                                <input type="number" step="0.01" min="0" value={x.amount}
                                    onChange={(e) => setItem(x.key, { amount: e.target.value })}
                                    className={`${CONTROL_INPUT} block w-32`} /></label>
                            <label className="min-w-0 flex-1 basis-56">{t('expenseClaims.description')}
                                <input value={x.description} onChange={(e) => setItem(x.key, { description: e.target.value })}
                                    className={`${CONTROL_INPUT} block w-full`} /></label>
                            {/* CLAIM-RECEIPTS-1(Q2 · Q9):这一笔的收据 —— 一份或几份;手机上这个框给「拍照 · 照片图库 · 文件」 */}
                            <label className="min-w-0 flex-1 basis-56">{t('expenseClaims.attachReceipt')}
                                <input type="file" multiple accept={RECEIPT_ACCEPT}
                                    onChange={(e) => setItem(x.key, { files: Array.from(e.target.files ?? []) })}
                                    className={`${CONTROL_FILE_BUTTON} block max-w-full`} />
                                {x.files.length > 1 && (
                                    <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.receipts.filesChosen', { n: x.files.length })}</span>
                                )}</label>
                            <label className="min-w-0 flex-1 basis-56">{t('expenseClaims.noReceiptReason')}
                                <input value={x.noReceipt} onChange={(e) => setItem(x.key, { noReceipt: e.target.value })}
                                    className={`${CONTROL_INPUT} block w-full`} /></label>
                            {items.length > 1 && (
                                <Button variant="secondary" size="xs" type="button"
                                    aria-label={t('expenseClaims.removeItemAria', { n: n + 1 })}
                                    onClick={() => setItems((xs) => xs.filter((y) => y.key !== x.key))}>
                                    {t('expenseClaims.removeItem')}
                                </Button>
                            )}
                        </div>
                    ))}
                    <p className="text-xs text-[color:var(--brand-muted-text)]">
                        {t('expenseClaims.spendDateHint')} {t('expenseClaims.amountHint')} {t('expenseClaims.noReceiptReasonHint')}
                    </p>
                    {limits?.set && limits.max_bytes != null && (
                        <p className="text-xs text-[color:var(--brand-muted-text)]">
                            {t('expenseClaims.receipts.limitsHint', { mb: String(Math.round(limits.max_bytes / 1048576)) })}
                        </p>
                    )}
                    <div className="flex flex-wrap gap-2">
                        <Button variant="secondary" size="xs" type="button" onClick={() => setItems((xs) => [...xs, blankItem()])}>
                            {t('expenseClaims.addItem')}
                        </Button>
                        <Button type="button" disabled={pending || !canSubmit}
                            onClick={() => {
                                setError(null); setNotice(null)
                                startTransition(async () => {
                                    const r = await submitClaim({
                                        employeeId: employeeId!, currency, purpose,
                                        items: items.map((x) => ({ spendDate: x.spendDate, amount: x.amount,
                                                                   description: x.description, noReceiptReason: x.noReceipt })),
                                    })
                                    if (r.error) { setError(r.error); return }
                                    // Q12:单已提交 —— 紧接着逐份传每一笔的收据;传不上的,在表里那一笔上重试
                                    const problems: string[] = []
                                    for (const [n, x] of items.entries()) {
                                        const itemId = r.items?.find((i) => i.line_no === n + 1)?.item_id
                                        for (const f of x.files) {
                                            if (!itemId || !limits) { problems.push(f.name); continue }
                                            const p = await prepareReceipt(f, limits)
                                            if (!p.ok) { problems.push(`${f.name}: ${t(PREPARE_FAILURE_KEYS[p.why])}`); continue }
                                            const e = await uploadReceipt(itemId, p)
                                            if (e) problems.push(`${f.name}: ${e}`)
                                        }
                                    }
                                    if (problems.length) setNotice(t('expenseClaims.receipts.someFailed', { code: r.code ?? '', list: problems.join(' · ') }))
                                    setOpen(false); reset()
                                    router.refresh()
                                })
                            }}>
                            {t('expenseClaims.submit')}
                        </Button>
                    </div>
                </div>
            )}
            <RowCapNotice shown={rows.length} total={total} />
            <DataTable
                rows={rows}
                columns={columns}
                rowKey={(r) => r.claim_id}
                phone={{ mode: 'columns' }}
                empty={t('expenseClaims.none')}
                exportSpec={{ name: 'me-expense-claims', title: t('expenseClaims.myTitle'), serverRows: exportHref }}
                sorting={{ mode: 'server', coverage: { shown: rows.length, total }, active: sort, href: sortHref }}
            />
            {rows.length > 0 && (
                <div className="mt-4 space-y-2">
                    {rows.map((r) => (
                        <div key={r.claim_id} className="text-sm">
                            <span className="text-xs text-[color:var(--brand-muted-text)]">{r.code}</span>
                            {trails[r.claim_id]}
                        </div>
                    ))}
                </div>
            )}
        </section>
    )
}

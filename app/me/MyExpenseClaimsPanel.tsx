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
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { submitClaim, withdrawClaim } from '@/app/finance/claims/actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { DataTable, type Column } from '@/app/components/ui/data-table'

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

    /* 撤回钮。TABLE-PHONE-3 当时把它写成一个共用的画法,是因为同一颗钮要在两个
       断点各画一次(桌面在自己那一列,手机叠在「单号」格里);TABLE-STYLE-1 之后
       它【只画一次】了 —— 那一列在两个断点都留在明面上。
       ☞ 留着这个具名的画法,是因为它现在就是那一列的 render。
       动作与它自己的 submitted 判定一个字没改。 */
    const withdrawControl = (r: (typeof rows)[number]) => (
        <>
        {r.status === 'submitted' && (
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
        )}
        </>
    )

    const columns: Column<Row>[] = [
        { key: 'ref', header: t('expenseClaims.colRef'), priority: true, render: (r) => r.code },
        {
            key: 'spent', header: t('expenseClaims.colSpent'),
            render: (r) => r.spend_date,
        },
        {
            key: 'description', header: t('expenseClaims.colDescription'),
            render: (r) => (
                <>
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
                </>
            ),
        },
        {
            key: 'amount', header: t('expenseClaims.colAmount'), align: 'right', priority: true, render: (r) => `${money(r.amount_ccy)} ${r.currency}`,
        },
        {
            key: 'status', header: t('expenseClaims.colStatus'), priority: true,
            render: (r) => (
                <>
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
                </>
            ),
        },
        // ★ 动作列 —— 空列头与转换之前逐字相同,priority 的理由见抬头。
        { key: 'actions', header: '', align: 'right', priority: true, render: withdrawControl },
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

            {employeeId && !open && (
                <Button variant="default" className="mb-3 text-sm" type="button" onClick={() => setOpen(true)}>
                    {t('expenseClaims.submit')}
                </Button>
            )}
            {employeeId && open && (
                <div className="mb-4 rounded border border-gray-300 p-3 flex flex-wrap gap-3 items-end max-w-3xl">
                    <label className="">{t('expenseClaims.spendDate')}
                        <input type="date" value={spendDate} max={today()}
                            onChange={(e) => setSpendDate(e.target.value)}
                            className={`${CONTROL_INPUT} block`} />
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.spendDateHint')}</span></label>
                    <label className="">{t('expenseClaims.amount')}
                        <input type="number" step="0.01" min="0" value={amount}
                            onChange={(e) => setAmount(e.target.value)}
                            className={`${CONTROL_INPUT} block w-32`} /></label>
                    <label className="">{t('expenseClaims.currency')}
                        <input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())}
                            className={`${CONTROL_INPUT} block w-20`} /></label>
                    <label className="flex-1 min-w-[16rem]">{t('expenseClaims.description')}
                        <input value={description} onChange={(e) => setDescription(e.target.value)}
                            className={`${CONTROL_INPUT} block w-full`} />
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.descriptionHint')}</span></label>
                    <label className="flex-1 min-w-[16rem]">{t('expenseClaims.noReceiptReason')}
                        <input value={noReceipt} onChange={(e) => setNoReceipt(e.target.value)}
                            className={`${CONTROL_INPUT} block w-full`} />
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('expenseClaims.noReceiptReasonHint')}</span></label>
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

            <DataTable
                rows={rows}
                columns={columns}
                rowKey={(r) => r.claim_id}
                phone={{ mode: 'columns' }}
                empty={t('expenseClaims.none')}
            />
        </section>
    )
}

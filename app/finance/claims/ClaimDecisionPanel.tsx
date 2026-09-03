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
import { DataTable, type Column } from '@/app/components/ui/data-table'

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

    // ★【已决登记簿的列 —— 手机上留【单号】与【金额】】★
    //   · 单号是身份,而且是人嘴里说的那个东西;
    //   · 金额是这张表存在的理由 —— 看已决报销就是在看"批了多少钱"。
    //   报销人、花费日期、状态(含冲销/欠款/已付那几行小字)都进展开区:
    //   它们是【看到那一行之后才问的】。
    //   【状态那一格整块搬过来,一个字没改】—— 它一格里最多能说四句话,
    //   而那四句的层次是 CLAIM-1 的判断,不是本刀的。
    const decidedColumns: Column<ClaimRow>[] = [
        { key: 'ref', header: t('expenseClaims.colRef'), priority: true, className: 'font-mono text-xs', render: (c) => c.code },
        { key: 'who', header: t('expenseClaims.colWho'), render: (c) => c.employee_name },
        { key: 'spent', header: t('expenseClaims.colSpent'), className: 'font-mono text-xs', render: (c) => c.spend_date },
        {
            key: 'amount', header: t('expenseClaims.colAmount'), priority: true, align: 'right',
            className: 'font-mono',
            render: (c) => `${money(c.amount_ccy)} ${c.currency}`,
        },
        {
            key: 'status', header: t('expenseClaims.colStatus'),
            render: (c) => (
                <>
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
                </>
            ),
        },
    ]

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

            {/* 列描述符住在这个文件里,因为它本来就已经是 'use client' ——
                另外三页要多一个文件,是因为它们的 page.tsx 是服务端组件。 */}
            <h2 className="text-lg font-semibold mb-2">{t('expenseClaims.decidedTitle')}</h2>
            {/* ★★【CONV-1:只有【这一张】换成了 DataTable —— 上面那个决定队列没动】★★
                这一页有两半:上面是【做决定的地方】(select / input / 提交),
                下面是【已决的登记簿】。只有下半张是只读账簿,而 DataTable 是一个
                只读账簿的渲染器 —— 它没有行内编辑这回事(见 docs/list-page-template.md
                「19 张可编辑网格是另一套模板」)。
                所以本刀【只碰下半张】,上面那半个字没改。 */}
            {decided.length === 0 ? (
                <p className="text-sm text-gray-500">{t('expenseClaims.noneForEmployee')}</p>
            ) : (
                <DataTable
                    rows={decided}
                    columns={decidedColumns}
                    rowKey={(c) => c.claim_id}
                    phone={{ mode: 'columns' }}
                />
            )}
        </div>
    )
}

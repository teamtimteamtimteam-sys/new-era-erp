// app/finance/expenses/[id]/page.tsx
// 开支详情:头部卡(编号/日期/科目/金额原币+汇率+USD/付款状态/银行或供应商/
// 收款方/状态)+ 关联分录链接 + 挂账开支的结算区(口径同 ap_open_items:已结只计
// posted 收付款的核销;reversed 核销灰色删除线保留)+ 凭据附件面板(kind 'expense')。
// posted → 冲销按钮;reversed → "已被 X 冲销"横幅;镜像单 → "冲销自 X"横幅回链原单。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare, formatTimestamp } from '@/lib/format'
import FinanceAttachmentsPanel from '@/app/components/finance/FinanceAttachmentsPanel'
import ReverseExpenseButton from './ReverseExpenseButton'
import ReleasePrepaymentPanel from './ReleasePrepaymentPanel'
import { can } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type AllocRow = {
    id: string
    allocated_base: number
    payments: {
        id: string
        code: string
        payment_date: string
        status: string
    } | null
}

export default async function ExpenseDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: expense, error } = await supabase
        .from('expenses')
        .select('id, code, expense_date, account_code, amount_ccy, currency, fx_rate, amount_base, payment_status, bank_account_code, supplier_id, payee_name, notes, journal_entry_id, status, reversed_by_expense, purchase_order_line_id')
        .eq('id', id)
        .single()

    if (error || !expense) {
        notFound()
    }

    // ── EQP-1c-b(P5):这张费用单能不能冲定金 ─────────────────────────────
    // 三个事实,【全部问数据库,一个都不自己算】:
    //   1. 它挂在哪一条采购单行上(EQP-1b-ii 的那一列);
    //   2. 它自己还欠多少 —— ap_open_items.open_ccy,以【单据币种】计,
    //      正是 apply_prepayment 的 p_amount 所用的单位;
    //   3. 那张采购单上还有多少定金没冲 —— purchase_order_status.prepaid_remaining_base,
    //      以本位币计。
    // 【两个数不同币种,页面【不】替它取 min】—— 跨币种的上限要读定金的加权
    // 平均汇率才算得出,而那是 apply_prepayment 的事(R1/R2/R3 三条支路)。
    // 在这里算等于把 FIN-12 那个"页面自己算汇率"的毛病换个地方再犯一次。
    const canEdit = await can('module.finance.edit')
    let release: { poId: string; poCode: string; openCcy: number; remainingBase: number } | null = null
    if (expense.status === 'posted' && expense.payment_status === 'unpaid' && expense.purchase_order_line_id) {
        const lineRes = await supabase.from('purchase_order_lines')
            .select('purchase_order_id, purchase_orders(code)')
            .eq('id', expense.purchase_order_line_id).maybeSingle()
        const ln = lineRes.data as { purchase_order_id: string; purchase_orders: { code: string } | null } | null
        if (ln) {
            const [openRes, statusRes] = await Promise.all([
                supabase.from('ap_open_items').select('open_ccy').eq('doc_kind', 'expense').eq('doc_id', expense.id).maybeSingle(),
                supabase.from('purchase_order_status').select('prepaid_remaining_base').eq('po_id', ln.purchase_order_id).maybeSingle(),
            ])
            release = {
                poId: ln.purchase_order_id,
                poCode: ln.purchase_orders?.code ?? '—',
                openCcy: Number(openRes.data?.open_ccy ?? 0),
                remainingBase: Number(statusRes.data?.prepaid_remaining_base ?? 0),
            }
        }
    }

    // 科目名 / 供应商 / 分录 / 核销行 / 镜像单双向 / 附件,页级小查询
    const [accountRes, supplierRes, journalRes, allocsRes, reversedByRes, reversalOfRes, attachRes] =
        await Promise.all([
            supabase
                .from('accounts')
                .select('code, name_en, name_zh')
                .eq('code', expense.account_code)
                .single(),
            expense.supplier_id
                ? supabase.from('suppliers').select('legal_name').eq('id', expense.supplier_id).single()
                : Promise.resolve({ data: null, error: null }),
            expense.journal_entry_id
                ? supabase.from('journal_entries').select('id, code').eq('id', expense.journal_entry_id).single()
                : Promise.resolve({ data: null, error: null }),
            supabase
                .from('payment_allocations')
                .select('id, allocated_base, payments(id, code, payment_date, status)')
                .eq('expense_id', id)
                .order('created_at', { ascending: true }),
            expense.reversed_by_expense
                ? supabase.from('expenses').select('id, code').eq('id', expense.reversed_by_expense).single()
                : Promise.resolve({ data: null, error: null }),
            // 本单是否为镜像:查"谁把我记为 reversed_by_expense"(是则回链原单)
            supabase
                .from('expenses')
                .select('id, code')
                .eq('reversed_by_expense', id)
                .maybeSingle(),
            supabase
                .from('finance_attachments')
                .select('id, file_name, file_path, file_size, mime_type, doc_type, notes, created_at')
                .eq('expense_id', id)
                .is('deleted_at', null)
                .order('created_at', { ascending: false }),
        ])

    const accountName = accountRes.data
        ? locale === 'zh'
            ? accountRes.data.name_zh
            : accountRes.data.name_en
        : ''

    const allocs = ((allocsRes.data as unknown as AllocRow[] | null) ?? [])

    // 已结额只计 posted 收付款的核销(与 ap_open_items 口径一致);reversed 行仍展示。
    const settled =
        Math.round(
            allocs
                .filter((a) => a.payments?.status === 'posted')
                .reduce((s, a) => s + a.allocated_base, 0) * 100
        ) / 100
    const open = Math.round((expense.amount_base - settled) * 100) / 100

    // 在服务端按当前语言格式化时间,再传给客户端面板 —— 避免客户端水合不一致
    const attachments = (mustRows(attachRes)).map((a) => ({
        id: a.id,
        file_name: a.file_name,
        file_path: a.file_path,
        file_size: a.file_size,
        mime_type: a.mime_type,
        doc_type: a.doc_type,
        notes: a.notes,
        created_at_display: formatTimestamp(a.created_at, dateLocale),
    }))

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/expenses" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('expense.detailTitle')}</h1>

            {/* 冲销横幅:已被冲销 → 链镜像单;本单是镜像 → 回链原单 */}
            {expense.status === 'reversed' && reversedByRes.data && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    <Link
                        href={`/finance/expenses/${reversedByRes.data.id}`}
                        className="text-blue-600 hover:underline"
                    >
                        {t('expense.reversedBanner', { code: reversedByRes.data.code })}
                    </Link>
                </div>
            )}
            {reversalOfRes.data && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    <Link
                        href={`/finance/expenses/${reversalOfRes.data.id}`}
                        className="text-blue-600 hover:underline"
                    >
                        {t('expense.reversalOfBanner', { code: reversalOfRes.data.code })}
                    </Link>
                </div>
            )}

            {/* 头部卡 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('expense.colCode')}:</span>
                    <span className="font-mono font-medium">{expense.code}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('expense.colDate')}:</span>
                    <span>{expense.expense_date}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('expense.colAccount')}:</span>
                    <span className="font-mono">{expense.account_code}</span>
                    <span className="ml-1">{accountName}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('expense.colAmount')}:</span>
                    <span className="font-mono font-medium">
                        {expense.currency} {formatMoneyBare(expense.amount_ccy, '同格内紧邻的 expense.currency 前缀')}
                    </span>
                    {expense.currency !== baseCurrency && (
                        <span className="text-gray-500 ml-1 font-mono">
                            @ {expense.fx_rate} = {formatMoneyBare(expense.amount_base, '同格内紧随其后的 {baseCurrency} 后缀')} {baseCurrency}
                        </span>
                    )}
                </div>
                <div>
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (expense.payment_status === 'paid'
                                ? 'bg-green-100 text-green-800'
                                : 'bg-amber-100 text-amber-800')
                        }
                    >
                        {t('expense.status.' + expense.payment_status)}
                    </span>
                </div>
                {expense.payment_status === 'paid' ? (
                    <div>
                        <span className="text-gray-600 mr-1">{t('expense.form.bankAccount')}:</span>
                        <span>{t('finance.bank.' + expense.bank_account_code)}</span>
                    </div>
                ) : (
                    <div>
                        <span className="text-gray-600 mr-1">{t('expense.form.supplier')}:</span>
                        <span>{supplierRes.data?.legal_name ?? '—'}</span>
                    </div>
                )}
                {expense.payee_name && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('expense.form.payeeName')}:</span>
                        <span>{expense.payee_name}</span>
                    </div>
                )}
                <div>
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (expense.status === 'posted'
                                ? 'bg-green-100 text-green-800'
                                : 'bg-gray-200 text-gray-700')
                        }
                    >
                        {t('finance.status.' + expense.status)}
                    </span>
                </div>
                {expense.status === 'posted' && <ReverseExpenseButton expenseId={expense.id} />}
            </div>

            {/* EQP-1c-b(P5):设备侧的冲抵门。只在【这张费用单确实挂在一条采购单行上】
                时出现 —— 没有那条行,就没有"哪张单上的定金"这个问题。
                进料侧那扇门在 app/inbound/[id]/edit,两扇门对应两种应付单据。 */}
            {release && (
                <ReleasePrepaymentPanel
                    expenseId={expense.id} poId={release.poId} poCode={release.poCode}
                    openCcy={release.openCcy} currency={String(expense.currency)}
                    remainingBase={release.remainingBase} baseCurrency={baseCurrency}
                    canEdit={canEdit}
                />
            )}

            {expense.notes && (
                <p className="text-sm text-gray-600 mb-4">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {expense.notes}
                </p>
            )}

            {/* 关联分录 */}
            {journalRes.data && (
                <p className="text-sm mb-4">
                    <span className="text-gray-600 mr-1">{t('finance.linkedJournal')}:</span>
                    <Link
                        href={`/finance/journal/${journalRes.data.id}`}
                        className="text-blue-600 hover:underline font-mono"
                    >
                        {journalRes.data.code}
                    </Link>
                </p>
            )}

            {/* 挂账开支:结算区(镜像 AR/AP 单据详情页)*/}
            {expense.payment_status === 'unpaid' && (
                <>
                    <div className="bg-gray-50 rounded p-4 mb-4 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                        <div>
                            <span className="text-gray-600 mr-1">{t('finance.settledAmount')}:</span>
                            <span className="font-mono">{formatAmount(settled, baseCurrency)}</span>
                        </div>
                        <div>
                            <span className="text-gray-600 mr-1">{t('finance.openAmount')}:</span>
                            <span className="font-mono font-bold">{formatAmount(open, baseCurrency)}</span>
                        </div>
                    </div>

                    <h2 className="text-lg font-semibold mb-3">{t('finance.settlementHistory')}</h2>
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colPayment')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.paymentDate')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAllocated')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colStatus')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {allocs.map((a) => {
                                const reversed = a.payments?.status === 'reversed'
                                return (
                                    <tr key={a.id} className={reversed ? 'text-gray-400' : ''}>
                                        <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                            {a.payments ? (
                                                <Link
                                                    href={`/finance/payments/${a.payments.id}`}
                                                    className={
                                                        reversed
                                                            ? 'text-gray-400 hover:underline line-through'
                                                            : 'text-blue-600 hover:underline'
                                                    }
                                                >
                                                    {a.payments.code}
                                                </Link>
                                            ) : (
                                                '—'
                                            )}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 text-sm">
                                            {a.payments?.payment_date ?? '—'}
                                        </td>
                                        <td
                                            className={
                                                'border border-gray-300 px-4 py-2 text-right font-mono text-sm' +
                                                (reversed ? ' line-through' : '')
                                            }
                                        >
                                            {formatAmount(a.allocated_base, baseCurrency)}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 text-sm">
                                            {reversed ? (
                                                <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-500">
                                                    {t('finance.reversedMark')}
                                                </span>
                                            ) : (
                                                <span className="px-2 py-1 rounded text-xs bg-green-100 text-green-800">
                                                    {t('finance.status.posted')}
                                                </span>
                                            )}
                                        </td>
                                    </tr>
                                )
                            })}
                            {allocs.length === 0 && (
                                <tr>
                                    <td colSpan={4} className="border border-gray-300 px-4 py-4 text-center text-gray-500 text-sm">
                                        {t('finance.noOpenItems')}
                                    </td>
                                </tr>
                            )}
                        </tbody>
                        {allocs.length > 0 && (
                            <tfoot>
                                <tr className="bg-gray-100 font-bold">
                                    <td className="border border-gray-300 px-4 py-2" colSpan={2}>
                                        {t('finance.settledAmount')}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatAmount(settled, baseCurrency)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2" />
                                </tr>
                            </tfoot>
                        )}
                    </table>
                </>
            )}

            {/* 凭据附件(发票/收据)*/}
            <FinanceAttachmentsPanel parent={{ kind: 'expense', id: expense.id }} rows={attachments} />
        </div>
    )
}

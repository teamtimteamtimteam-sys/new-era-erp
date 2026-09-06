// app/sales/customers/[id]/page.tsx
// 客户【状况页】—— SAL-B6。
//
// 【为什么它存在】SAL-B 建了信用管控,却没有任何一块屏把【限额】与【敞口】放在
// 一起:限额在编辑表单上(一个可改的字段),敞口在应收页上(按客户合计,看不见
// 限额),没有一处拿两者相比。于是"这个客户越限了"这件事只有两个说法 ——
// 首页的一块牌子,和销售被拒的那一刻。走查时那块牌子指向客户【列表】,
// 而列表上一个字都不提信用。
//
// 【它是一个仓位,不是一张设置表】只读,不放任何字段;要改限额/冻结,走那条
// 明确的链接去编辑表单。这条分界正是它存在的理由:把一个活的财务仓位塞进
// 编辑表单,等于邀请读者去改那个让告警消失、却不改变事实的数字。
// (同一条判断也写进了 docs/dashboard-arm-inventory.md:编辑表单是【编辑即补救】
//  时的正确去处,不是"编辑只让信号消失"时的去处。)
//
// 【三段各有各的门,缺一段就说「受限」而不是显示 0】
//   身份 —— customers(module.customers.view)
//   信用 —— customer_credit_status(同上;敞口走有检查的外壳,见该视图注释)
//   明细 —— ar_open_items(module.finance.view)—— 【看得见限额不等于看得见账】,
//           所以这一段单独把关,无权时整段是「受限」,不是一张空表。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import { can } from '@/lib/permissions'
import StatementPanel from '../StatementPanel'
import ChasePanel from '../ChasePanel'
import ContactsPanel, { type ContactRow } from '../ContactsPanel'
import { mustRows } from '@/lib/db-helpers'
import { collectionContext } from '../chaseActions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'

type CreditRow = {
    customer_id: string
    code: string
    legal_name: string
    credit_limit_base: number | null
    credit_hold: boolean
    exposure_base: number | null
    headroom_base: number | null
    sales_blocked: boolean
}

// CHASE-1:催收那一段的两组行。
// 【承诺是数组,但它最多一个】UNIQUE(chase_id) —— 摊平时取 [0] 是在陈述那条约束。
type ChaseRow = {
    id: string; code: string; chased_on: string; channel: string
    reached: boolean; contacted_person: string | null; summary: string
    owed_base: number; superseded_at: string | null
    promise: { promised_amount_ccy: number; currency: string
               promised_date: string; outcome: string | null } | null
    documents: { subject_type: string; subject_code: string | null }[]
}
type OpenPromiseRow = {
    promise_id: string; chase_id: string; chase_code: string; chased_on: string
    promised_amount_ccy: number; currency: string; promised_amount_base: number
    promised_date: string; is_overdue: boolean; applied_since_base: number
}

// 催收上下文要一个【今天】—— 而这是唯一一处默认成今天是【对】的地方:
// 它读的是"现在欠多少"(与冻结的那个数并排显示),不是在记录一件发生过的事。
// 记录那一侧(chased_on)刻意没有默认值,两者不是同一个问题。
function todayISO(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

type OpenItem = {
    sales_record_id: string
    doc_code: string
    sale_date: string
    open_base: number
    days_outstanding: number
    bucket: string
}

export default async function CustomerStatusPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。
    const denied = await requireModule(MOD.customers)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()

    // PARTY-1:这个客户的联系人们(软删的不列)。
    // 主联系人排在最前,其余按名字 —— 屏幕上最要紧的那一行不该要人去找。
    const contacts = mustRows(
        await supabase.from('counterparty_contacts')
            .select('id, name, name_inferred, role, email, phone, is_primary, notes')
            .eq('customer_id', id).is('deleted_at', null)
            .order('is_primary', { ascending: false }).order('name'),
        'counterparty_contacts') as ContactRow[]
    const canFinance = await can('module.finance.view')
    // PARTY-1:联系人的编辑权按【归属那一侧】—— 与 save_counterparty_contact 里那句同源
    const canEditCustomer = await can('module.customers.edit')

    const { data: cust, error } = await supabase
        .from('customers')
        .select('id, code, legal_name, country, status')
        .eq('id', id)
        .is('deleted_at', null)
        .single()
    if (error || !cust) notFound()

    const { data: creditRaw } = await supabase
        .from('customer_credit_status')
        .select('customer_id, code, legal_name, credit_limit_base, credit_hold, exposure_base, headroom_base, sales_blocked')
        .eq('customer_id', id)
        .maybeSingle()
    const credit = (creditRaw as CreditRow | null) ?? null

    // 明细只有持 module.finance.view 的人看得到 —— 不去查,而不是查了拿零行
    const openItems: OpenItem[] = canFinance
        ? (mustRows(
              await supabase
                  .from('ar_open_items')
                  .select('sales_record_id, doc_code, sale_date, open_base, days_outstanding, bucket')
                  .eq('customer_id', id)
                  .order('sale_date')
          ) as OpenItem[])
        : []

    // STATEMENT-1:这个客户【已经出过】的对账单。与明细同一道门(module.finance.view)——
    // 看得见限额不等于看得见账,而对账单就是账寄出去的样子。
    // 【无权时不去查,而不是查了拿零行】—— 零行读起来是"还没出过",那是一句假话。
    const issuedStatements = canFinance
        ? (mustRows(
              await supabase
                  .from('customer_statements')
                  .select('id, code, period_start, period_end, closing_base, issued_at, superseded_at')
                  .eq('customer_id', id)
                  .order('period_end', { ascending: false })
          ) as unknown as {
              id: string; code: string; period_start: string; period_end: string
              closing_base: number; issued_at: string; superseded_at: string | null
          }[])
        : []
    const canIssueStatement = await can('module.finance.edit')

    // CHASE-1:催收记录 + 还没了结的承诺。与明细、对账单同一道门。
    // 【无权时不去查,而不是查了拿零行】—— 零行读起来是"从没催过",那是一句假话。
    const chases = canFinance
        ? (mustRows(
              await supabase
                  .from('collection_chases')
                  .select('id, code, chased_on, channel, reached, contacted_person, summary, '
                        + 'owed_base, superseded_at, '
                        + 'collection_promises(promised_amount_ccy, currency, promised_date, outcome), '
                        + 'collection_chase_documents(subject_type, subject_code)')
                  .eq('customer_id', id)
                  .order('chased_on', { ascending: false })
          ) as unknown as (Omit<ChaseRow, 'promise' | 'documents'> & {
              collection_promises: ChaseRow['promise'][]
              collection_chase_documents: ChaseRow['documents']
          })[])
        : []
    // 【嵌进来的一对多在这里摊平】—— 一次对话一个承诺(UNIQUE chase_id),
    // 所以那个数组要么空要么一个;取 [0] 是在陈述那条约束,不是在赌。
    const chaseRows: ChaseRow[] = chases.map((c) => ({
        ...c,
        promise: c.collection_promises?.[0] ?? null,
        documents: c.collection_chase_documents ?? [],
    }))

    // 还没了结的承诺,每一个带着它自己的【证据】—— 由 DB 那支函数算,
    // 因为它要读 customer_statement_data,而那个数不许在这里再算一遍。
    const collectionCtx = canFinance
        ? ((await collectionContext(id, todayISO())).data as {
              owed_base: number; base_currency: string
              promises_open: OpenPromiseRow[]
          } | undefined)
        : undefined

    const row = (label: string, value: React.ReactNode) => (
        <div className="flex justify-between py-1">
            <span className="text-gray-600">{label}</span>
            <span className="font-mono">{value}</span>
        </div>
    )

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link href="/sales/customers" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex flex-wrap items-center justify-between gap-3 mb-4">
                <h1 className="text-2xl font-bold">
                    {cust.legal_name}
                    <span className="ml-3 font-mono text-base text-gray-500">{cust.code}</span>
                </h1>
                {/* 【改限额/冻结在别处】这一页不放字段 —— 见文件头 */}
                <Button asChild variant="outline" size="sm">
                    <Link
                        href={`/sales/customers/${id}/edit`}
                    >
                        {t('customers.status.editLink')}
                    </Link>
                </Button>
            </div>

            <p className="text-sm text-gray-600 mb-6">
                {cust.country ?? '—'}
                <span className="mx-2">·</span>
                {cust.status}
            </p>

            {/* ── 信用仓位 ─────────────────────────────────────────────────── */}
            <section className="mb-8">
                <h2 className="text-lg font-semibold mb-2">{t('customers.status.creditTitle')}</h2>
                {/* SO-3a:敞口从此包含【已开票未发货】的订单流发票 —— 面板显示的数
                    与开票/销售被拒时用的数【按构造是同一个】(都出自
                    customer_ar_exposure_base,它的第二项与应收账龄第二支读同一张
                    内层视图)。这一句放在这里,是为了让看见数字的人知道口径。 */}
                <p className="text-xs text-gray-500 mb-2">{t('customers.status.exposureIncludesInvoiced')}</p>
                {credit === null ? (
                    // 拿不到行 = 无权。【不是 0】—— 0 读作"没有限额、余额充足"
                    <p className="text-sm text-gray-500">{t('common.restricted')}</p>
                ) : (
                    <div className="bg-gray-50 rounded p-4 text-sm max-w-md">
                        {credit.credit_hold && (
                            <p className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mb-3">
                                {t('customers.status.onHold')}
                            </p>
                        )}
                        {row(
                            t('customers.status.limit'),
                            credit.credit_limit_base === null
                                ? t('customers.status.noLimit')
                                : formatAmount(credit.credit_limit_base, baseCurrency)
                        )}
                        {row(t('customers.status.exposure'), formatAmount(credit.exposure_base, baseCurrency))}
                        {credit.credit_limit_base !== null &&
                            row(
                                t('customers.status.headroom'),
                                <span className={credit.sales_blocked ? 'text-red-700 font-bold' : ''}>
                                    {formatAmount(credit.headroom_base, baseCurrency)}
                                </span>
                            )}
                        {credit.sales_blocked && !credit.credit_hold && (
                            <p className="bg-red-100 border border-red-400 text-red-700 px-3 py-2 rounded mt-3">
                                {t('customers.status.overLimit')}
                            </p>
                        )}
                    </div>
                )}
            </section>

            {/* ── 敞口由哪些单据构成 ───────────────────────────────────────── */}
            <section>
                <h2 className="text-lg font-semibold mb-2">{t('customers.status.openTitle')}</h2>
                {!canFinance ? (
                    // 看得见限额不等于看得见账 —— 整段受限,不是一张空表
                    <p className="text-sm text-gray-500">{t('common.restricted')}</p>
                ) : openItems.length === 0 ? (
                    <p className="text-sm text-gray-500">{t('customers.status.noOpenItems')}</p>
                ) : (
                    <div className="overflow-x-auto">
                        <table className="w-full border-collapse border border-gray-300 text-sm">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('customers.status.colDoc')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('customers.status.colDate')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('customers.status.colOpen', { ccy: baseCurrency })}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('customers.status.colDays')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {openItems.map((it) => (
                                    <tr key={it.sales_record_id}>
                                        <td className="border border-gray-300 px-3 py-2">
                                            <Link
                                                href={`/finance/receivables/${it.sales_record_id}`}
                                                className="text-blue-600 hover:underline font-mono"
                                            >
                                                {it.doc_code}
                                            </Link>
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2">{it.sale_date}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatAmount(it.open_base, baseCurrency)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {it.days_outstanding}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                )}
            </section>

            {/* ── STATEMENT-1:对账单 ────────────────────────────────────────
                【为什么整段挂在 canFinance 上】对账单就是这个客户的账寄出去的样子;
                读不到明细的人也不该读到它。无权时【整段不渲染】——
                与上面那一段同一条:一张空表对读不到内容的人只是噪音,
                而"受限"要说出来,不能长得像"还没有出过"。 */}
            {canFinance && (
                <StatementPanel
                    customerId={id}
                    issued={issuedStatements}
                    canIssue={canIssueStatement}
                />
            )}

            {/* ── CHASE-1:催收记录 ──────────────────────────────────────────
                【为什么紧挨着对账单】对账单是寄出去的那张纸,催收是【那张纸之后
                发生的那场对话】—— 勘察把两件事并成一刀正是这个理由。
                无权时【整段不渲染】,与上面两段同一条。 */}
            {canFinance && (
                <ChasePanel
                    customerId={id}
                    chases={chaseRows}
                    openPromises={collectionCtx?.promises_open ?? []}
                    owedToday={collectionCtx?.owed_base ?? 0}
                    baseCurrency={baseCurrency}
                    canEdit={canIssueStatement}
                />
            )}

            {/* ── PARTY-1:联系人 ────────────────────────────────────────────
                ★【标题与那句说明【在服务端渲染】,不藏在客户端开关后面】★
                昨天记下的第三条冒烟盲区:一条藏在客户端开关后面的针,
                这支 fetch 冒烟【永远】看不见 —— 那样的断言不是覆盖,是自欺。
                所以这一段的抬头与"它不是一方两身"那句话就画在页面上。
                【为什么不挂在 canFinance 上】联系人属于客户主数据,
                读得到这个客户的人就读得到他的联系人 —— 与对账单那一段不同。 */}
            <section className="mt-6">
                <h2 className="text-lg font-semibold mb-1">{t('contacts.sectionTitle')}</h2>
                <p className="text-xs text-gray-600 mb-2 max-w-3xl">{t('contacts.sectionWhat')}</p>
                <ContactsPanel customerId={id} rows={contacts} canEdit={canEditCustomer} />
            </section>
        </div>
    )
}

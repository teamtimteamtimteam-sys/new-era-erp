// app/finance/trial-balance/page.tsx
// 试算平衡:journal_lines 按科目聚合(全部分录 —— 冲销对自然对消),
// 按科目类型分组小计,底部 Σ借 = Σ贷。零发生额科目默认隐藏,?all=1 显示。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【CONV-6 ⑥:「显示零发生额科目」此前会把人送去【财务 Overview】】★★
// ════════════════════════════════════════════════════════════════════════════
// 【机制,查出来的,不是猜的】NAV-CLEANUP-1 ③ 把这一页从 /finance 搬到
//   /finance/trial-balance,而这条链接是**自指的**:它写的是
//   `showAll ? <模块根> : <模块根 + ?all=1>` —— 一个当时正确、搬家之后
//   指向别人的地址。CONV-7 又把 /finance 做成了 Overview,于是点「显示零发生额
//   科目」的人落在一张三条陈述的 Overview 上,而它连"零发生额"这四个字都不认。
//   **两刀都没错,错在没有人问过"谁写着这一页的旧地址"。**
//   (连文件抬头那行注释都还写着 app/finance/page.tsx —— 一并改了。)
//
// ★【为什么全站的检查一条都没抓到它 —— 这才是这一条真正的教训】★
//   scripts/check-nav-routes.mjs 的退休路径那一支查的是【被搬走的前缀】,
//   而 `/finance` **没有被搬走**:它今天仍然是一条完全合法的路由。
//   退休的是"/finance 【是】试算平衡"这件事,而那是一件【语义】,不是一个字符串。
//   ★ CONV-6 因此给那支检查加了第 ⑥ 条判据:**一条带查询参数的站内链接,
//     它指的那一页必须真的读那个参数。** 这条旧链接当场变红 ——
//     财务 Overview 根本不读 `all`。判据与注入实测见那个文件。
//   ★【顺带一条实测出来的分寸,写在这里因为它是本页教出来的】★
//     那条判据【连注释一起查】,与退休路径那一支同一个口径。所以本抬头
//     刻意【不写出】那条坏链接的字面量 —— 一段可以直接复制走的坏地址,
//     与代码里的坏地址一样会被人用上。要举例,就描述它,不要写出它。★
// ════════════════════════════════════════════════════════════════════════════
import { Fragment } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { tableC } from '@/app/components/ui/table-style'

// ★ CONV-4:不套 DataTable —— 与 balance-sheet 同一条理由(按科目类型
//   动态分组 + 每组小计 + 底部借贷合计,不是记录列表)。
//   见 balance-sheet/page.tsx 顶注。

const TYPE_ORDER = ['asset', 'liability', 'equity', 'revenue', 'cogs', 'expense'] as const

type AccountRow = {
    id: string
    code: string
    name_en: string
    name_zh: string
    account_type: string
    is_active: boolean
}

export default async function FinancePage({
    searchParams,
}: {
    searchParams: Promise<{ all?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    // 借方/贷方/净额三个列头都不写币种 —— 数字自己带(CCY-1)
    const baseCurrency = await getBaseCurrency()
    const showAll = sp.all === '1'

    const [accountsRes, linesRes] = await Promise.all([
        supabase
            .from('accounts')
            .select('id, code, name_en, name_zh, account_type, is_active')
            .order('code'),
        supabase.from('journal_lines').select('account_id, debit, credit'),
    ])

    if (accountsRes.error || linesRes.error) {
        const err = accountsRes.error ?? linesRes.error
        return (
            <div className="p-8">
                <h1 className="mb-4">{t('finance.trialBalance')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(err, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    const accounts = (mustRows(accountsRes)) as AccountRow[]
    const lines = mustRows(linesRes)

    // 按科目聚合借/贷
    const agg = new Map<string, { debits: number; credits: number }>()
    for (const l of lines) {
        const cur = agg.get(l.account_id) ?? { debits: 0, credits: 0 }
        cur.debits += l.debit
        cur.credits += l.credit
        agg.set(l.account_id, cur)
    }

    const accountName = (a: AccountRow) => (locale === 'zh' ? a.name_zh : a.name_en)

    const totalDebits = Math.round(lines.reduce((s, l) => s + l.debit, 0) * 100) / 100
    const totalCredits = Math.round(lines.reduce((s, l) => s + l.credit, 0) * 100) / 100

    // 分组(固定顺序);默认只显示有发生额的科目
    const groups = TYPE_ORDER.map((type) => ({
        type,
        rows: accounts
            .filter((a) => a.account_type === type)
            .map((a) => {
                const v = agg.get(a.id) ?? { debits: 0, credits: 0 }
                return {
                    ...a,
                    debits: Math.round(v.debits * 100) / 100,
                    credits: Math.round(v.credits * 100) / 100,
                    net: Math.round((v.debits - v.credits) * 100) / 100,
                }
            })
            .filter((r) => showAll || r.debits !== 0 || r.credits !== 0),
    })).filter((g) => g.rows.length > 0)

    return (
        <ListPage title={t('finance.trialBalance')} state={{ kind: 'ok' }}>
            <div className="mb-4 text-sm">
                <Link
                    href={showAll ? '/finance/trial-balance' : '/finance/trial-balance?all=1'}
                    className="hover:underline app-link"
                >
                    {showAll ? t('finance.hideZero') : t('finance.showAll')}
                </Link>
            </div>

            {totalDebits !== totalCredits && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 font-bold">
                    {t('finance.unbalancedWarning')}
                </div>
            )}

            <table className={`${tableC.root} w-full`}>
                <thead>
                    {/* ★ TABLE-PHONE-2:手机档三列 —— 编号 · 科目 · 净额。
                        【身份占两格是有理由的】:一个科目在这套系统里由编号与名字
                        【一起】认出来 —— 编号是拿来引用的把手,名字才是它的意思,
                        光有编号读起来就是一串没有主语的数字。
                        借方/贷方在 390px 上不画,叠进「编号」那一格(各带列头);
                        净额正是这两者的差,所以留它不等于丢掉那两个事实。 */}
                    <tr className={tableC.headRow}>
                        <th className={`${tableC.headCell} text-left`}>{t('finance.colCode')}</th>
                        <th className={`${tableC.headCell} text-left`}>{t('finance.colAccount')}</th>
                        <th className={`${tableC.headCell} hidden sm:table-cell text-right tabular-nums`}>{t('finance.colDebits')}</th>
                        <th className={`${tableC.headCell} hidden sm:table-cell text-right tabular-nums`}>{t('finance.colCredits')}</th>
                        <th className={`${tableC.headCell} text-right tabular-nums`}>{t('finance.colNet')}</th>
                    </tr>
                </thead>
                <tbody>
                    {groups.map((g) => (
                        <Fragment key={g.type}>
                            {/* ★ colSpan 不能随断点变,所以这条分组抬头写两份 ——
                                手机档跨 3 列,桌面档跨 5 列。字一模一样。 */}
                            <tr className={`${tableC.bodyRow} bg-gray-50`}>
                                <td colSpan={3} className={`${tableC.cell} sm:hidden font-semibold`}>
                                    {t('finance.accountType.' + g.type)}
                                </td>
                                <td colSpan={5} className={`${tableC.cell} hidden sm:table-cell font-semibold`}>
                                    {t('finance.accountType.' + g.type)}
                                </td>
                            </tr>
                            {g.rows.map((r) => (
                                <tr className={tableC.bodyRow} key={r.id}>
                                    <td className={tableC.cell}>
                                        {r.code}
                                        {/* ★ 手机档拿掉的借方/贷方叠在这里,各带自己的列头。 */}
                                        <div className="sm:hidden mt-1 space-y-0.5 font-sans text-xs text-gray-600">
                                            <div>
                                                <span className="text-gray-500">{t('finance.colDebits')}: </span>
                                                <span>{formatAmount(r.debits, baseCurrency)}</span>
                                            </div>
                                            <div>
                                                <span className="text-gray-500">{t('finance.colCredits')}: </span>
                                                <span>{formatAmount(r.credits, baseCurrency)}</span>
                                            </div>
                                        </div>
                                    </td>
                                    <td className={tableC.cell}>
                                        {accountName(r)}
                                        {!r.is_active && (
                                            <span className="ml-2 px-2 py-0.5 bg-gray-200 rounded text-xs">
                                                {t('finance.inactive')}
                                            </span>
                                        )}
                                    </td>
                                    <td className={`${tableC.cell} hidden sm:table-cell text-right tabular-nums`}>
                                        {formatAmount(r.debits, baseCurrency)}
                                    </td>
                                    <td className={`${tableC.cell} hidden sm:table-cell text-right tabular-nums`}>
                                        {formatAmount(r.credits, baseCurrency)}
                                    </td>
                                    <td
                                        className={`${tableC.cell} ${'text-right tabular-nums ' +
                                            (r.net < 0 ? 'text-red-600' : '')}`}
                                    >
                                        {formatAmount(r.net, baseCurrency)}
                                    </td>
                                </tr>
                            ))}
                        </Fragment>
                    ))}
                    {groups.length === 0 && (
                        <tr className={tableC.bodyRow}>
                            {/* colSpan 不能随断点变 —— 手机档三列,桌面档五列。 */}
                            <td colSpan={3} className="px-3 py-8 align-middle sm:hidden text-center text-gray-500">
                                {t('finance.emptyState')}
                            </td>
                            <td colSpan={5} className="px-3 py-8 align-middle hidden sm:table-cell text-center text-gray-500">
                                {t('finance.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
                <tfoot>
                    <tr className={`${tableC.bodyRow} bg-gray-100 font-bold`}>
                        {/* ★ 合计行同样写两份 —— 手机档标签格跨 2 列(编号+科目),
                            桌面档也跨 2 列,但手机档另外把借贷两个合计【叠】进来:
                            那两列在 390px 上不画,而"借贷相不相等"正是试算表的用处。 */}
                        <td colSpan={2} className={`${tableC.cell} sm:hidden`}>
                            {t('finance.totalsLabel')}
                            <span className="block mt-0.5 text-xs font-normal text-gray-600">
                                {t('finance.colDebits')} {formatAmount(totalDebits, baseCurrency)}
                                {' · '}
                                {t('finance.colCredits')} {formatAmount(totalCredits, baseCurrency)}
                            </span>
                        </td>
                        <td colSpan={2} className={`${tableC.cell} hidden sm:table-cell`}>{t('finance.totalsLabel')}</td>
                        <td className={`${tableC.cell} hidden sm:table-cell text-right tabular-nums`}>
                            {formatAmount(totalDebits, baseCurrency)}
                        </td>
                        <td className={`${tableC.cell} hidden sm:table-cell text-right tabular-nums`}>
                            {formatAmount(totalCredits, baseCurrency)}
                        </td>
                        <td className={tableC.cell} />
                    </tr>
                </tfoot>
            </table>
        </ListPage>
    )
}

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
                <h1 className="text-2xl font-bold mb-4">{t('finance.trialBalance')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(err, null, 2)}</pre>
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
                    className="text-blue-600 hover:underline"
                >
                    {showAll ? t('finance.hideZero') : t('finance.showAll')}
                </Link>
            </div>

            {totalDebits !== totalCredits && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 font-bold">
                    {t('finance.unbalancedWarning')}
                </div>
            )}

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colAccount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colDebits')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colCredits')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colNet')}</th>
                    </tr>
                </thead>
                <tbody>
                    {groups.map((g) => (
                        <Fragment key={g.type}>
                            <tr className="bg-gray-50">
                                <td colSpan={5} className="border border-gray-300 px-4 py-2 font-semibold">
                                    {t('finance.accountType.' + g.type)}
                                </td>
                            </tr>
                            {g.rows.map((r) => (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">{r.code}</td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {accountName(r)}
                                        {!r.is_active && (
                                            <span className="ml-2 px-2 py-0.5 bg-gray-200 rounded text-xs">
                                                {t('finance.inactive')}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatAmount(r.debits, baseCurrency)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatAmount(r.credits, baseCurrency)}
                                    </td>
                                    <td
                                        className={
                                            'border border-gray-300 px-4 py-2 text-right font-mono text-sm ' +
                                            (r.net < 0 ? 'text-red-600' : '')
                                        }
                                    >
                                        {formatAmount(r.net, baseCurrency)}
                                    </td>
                                </tr>
                            ))}
                        </Fragment>
                    ))}
                    {groups.length === 0 && (
                        <tr>
                            <td colSpan={5} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('finance.emptyState')}
                            </td>
                        </tr>
                    )}
                </tbody>
                <tfoot>
                    <tr className="bg-gray-100 font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">{t('finance.totalsLabel')}</td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatAmount(totalDebits, baseCurrency)}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatAmount(totalCredits, baseCurrency)}
                        </td>
                        <td className="border border-gray-300 px-4 py-2" />
                    </tr>
                </tfoot>
            </table>
        </ListPage>
    )
}

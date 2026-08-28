// app/finance/wht/page.tsx
// WHT-1:**欠 IRAS 的预提税读在这里**,汇缴也在这里。
//
// 【这一页是 4.1 的后半句:"未清偿的负债在哪里读"】前半句(在哪里裁定)是
// 费用单那张表单 —— 裁定属于债务,所以它必须发生在债务被记下来的那一刻。
//
// ★【关于这一页,有一件事必须写在它自己身上】★ 线上【一个非居民服务商都没有】
//   (实测:4 家真供应商,2 家 SG 货物、1 家 CN 货物、1 家 SG 货代;
//    0 家 service_vendor)。所以这一页今天渲染的【永远是空状态那一半】,
//   而【有数据的那一半没有任何东西在走它】—— fixture 走的是函数,不是页面。
//   这不是一句免责声明,是一个有先例的风险:/finance/freight/new 的货代下拉
//   自建成起就是空的,冒烟一路绿了好几周(FRT-FIX)。
//   **返回条件:第一家真实的非居民服务商到场时,这一页的有数据分支要被人走一遍。**
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import Subnav from '../Subnav'
import { RemitControl } from './WhtControls'

export default async function WhtPage() {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const base = await getBaseCurrency()

    const [liabRes, remitRes, naturesRes, ratesRes, gapRes] = await Promise.all([
        supabase.from('wht_liability_by_month')
            .select('period_month, withheld_base, remitted_base, unremitted_base, due_date, is_overdue')
            .order('period_month', { ascending: false }),
        supabase.from('wht_remittances')
            .select('id, code, period_month, remitted_on, amount_base, filed_reference, notes')
            .order('period_month', { ascending: false }).order('remitted_on', { ascending: false }),
        supabase.from('wht_natures')
            .select('code, name_en, name_zh, statute_ref, sort_order').eq('is_active', true).order('sort_order'),
        supabase.from('wht_rates')
            .select('nature, rate_pct, effective_from, effective_to').order('nature').order('effective_from'),
        // ★【那个量过的缺口,数出来摆在脸上】★ 未申报税务居民身份的供应商数。
        // 它不是装饰:一家【未申报】的非居民服务商,今天可以被记费用、被付款,
        // 而系统一分钱都不会代扣。理由整段写在 db/tables/suppliers.sql 的
        // tax_residence 列注释里(那是一个量过成本的取舍,16 份 fixture)。
        // 这里【数出来】,是 4.2「具名缺席,不是空白」在这一页上的用法。
        supabase.from('suppliers').select('id', { count: 'exact', head: true })
            .is('deleted_at', null).is('tax_residence', null),
    ])
    const liability = mustRows(liabRes)
    const remittances = mustRows(remitRes)
    const natures = mustRows(naturesRes)
    const rates = mustRows(ratesRes)
    const residenceGap = mustCount(gapRes)

    // 【只有真的欠着的月份才进汇缴下拉】—— 让屏幕offer 一个服务端一定会拒的动作,
    // 是本仓库记过的那条"页面不该给出只会报错的按钮"。
    const owing = liability.filter((r) => Number(r.unremitted_base) > 0)

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-1">{t('wht.title')}</h1>
            <p className="text-sm text-gray-600 mb-4">{t('wht.subtitle')}</p>
            <Subnav />

            {/* ── 未申报居民身份的供应商:一个【数】,不是一句提醒 ───────────── */}
            <p className={'text-sm mb-6 px-3 py-2 rounded border ' +
                (residenceGap > 0
                    ? 'bg-amber-50 border-amber-300 text-amber-900'
                    : 'bg-green-50 border-green-300 text-green-900')}>
                {residenceGap > 0 ? (
                    <>
                        <strong>{t('wht.residenceGapTitle', { n: String(residenceGap) })}</strong>
                        <br />
                        {t('wht.residenceGapBody')}
                    </>
                ) : t('wht.residenceGapNone')}
            </p>

            {/* ── 欠 IRAS 多少 ───────────────────────────────────────────────── */}
            <h2 className="font-semibold mb-2">{t('wht.liabilityHeading')}</h2>
            {liability.length === 0 ? (
                // 【具名的缺席】"还没有代扣过任何税"是一句关于账本的真话,
                // 而一张空表读起来像页面坏了。
                <div className="text-sm mb-6 bg-gray-50 border border-gray-300 px-3 py-2 rounded">
                    <strong>{t('wht.noneTitle')}</strong>
                    <br />
                    <span className="text-gray-600">{t('wht.noneBody')}</span>
                </div>
            ) : (
                <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                    <thead className="bg-gray-50">
                        <tr>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colMonth')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-right">{t('wht.colWithheld')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-right">{t('wht.colRemitted')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-right">{t('wht.colUnremitted')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colDue')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {liability.map((r) => {
                            const days = Math.round(
                                (new Date(r.due_date as string).getTime() - Date.now()) / 86_400_000)
                            return (
                                <tr key={r.period_month as string}>
                                    <td className="border border-gray-300 px-2 py-1 font-mono">
                                        {String(r.period_month).slice(0, 7)}
                                    </td>
                                    {/* 【已代扣与已汇缴分开报,不抹平】一个月被汇过之后又出现新的代扣,
                                        余额会重新变正 —— 那是对的。与 gst_return_boxes
                                        那条"当时报了多少"与"现在算出来多少"逐字同源。 */}
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">
                                        {formatAmount(Number(r.withheld_base), base)}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">
                                        {formatAmount(Number(r.remitted_base), base)}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono font-semibold">
                                        {formatAmount(Number(r.unremitted_base), base)}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-xs">
                                        <span className="font-mono">{String(r.due_date)}</span>
                                        {Number(r.unremitted_base) > 0 && (
                                            r.is_overdue
                                                ? <span className="ml-2 text-red-700 font-semibold">{t('wht.overdue')}</span>
                                                : <span className="ml-2 text-gray-600">{t('wht.dueIn', { n: String(days) })}</span>
                                        )}
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}

            {/* ── 汇缴 ───────────────────────────────────────────────────────── */}
            <h2 className="font-semibold mb-2">{t('wht.remitHeading')}</h2>
            <div className="mb-6">
                <RemitControl
                    months={owing.map((r) => ({
                        month: String(r.period_month).slice(0, 10),
                        label: String(r.period_month).slice(0, 7),
                        amount: formatAmount(Number(r.unremitted_base), base),
                    }))}
                />
            </div>

            <h2 className="font-semibold mb-2">{t('wht.remittancesHeading')}</h2>
            {remittances.length === 0 ? (
                <p className="text-sm text-gray-600 mb-6">{t('wht.noRemittances')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                    <thead className="bg-gray-50">
                        <tr>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colCode')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colMonth')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colRemittedOn')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-right">{t('wht.colAmount')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colIrasRef')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {remittances.map((r) => (
                            <tr key={r.id as string}>
                                <td className="border border-gray-300 px-2 py-1 font-mono">{r.code as string}</td>
                                <td className="border border-gray-300 px-2 py-1 font-mono">{String(r.period_month).slice(0, 7)}</td>
                                <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{String(r.remitted_on)}</td>
                                <td className="border border-gray-300 px-2 py-1 text-right font-mono">
                                    {formatAmount(Number(r.amount_base), base)}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 text-xs">{r.filed_reference as string}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {/* ── 法定税率:一张【待核对】的表 ─────────────────────────────────── */}
            <h2 className="font-semibold mb-2">{t('wht.ratesHeading')}</h2>
            {/* ★ 这一段是 1.5/G 在屏幕上的落点:形状是工程判断,数字是法律事实 ★ */}
            <p className="text-sm mb-3 bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded">
                <strong>{t('wht.ratesUnverifiedTitle')}</strong>
                <br />
                {t('wht.ratesUnverifiedBody')}
            </p>
            <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                <thead className="bg-gray-50">
                    <tr>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colNature')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colRate')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('wht.colStatute')}</th>
                    </tr>
                </thead>
                <tbody>
                    {natures.map((n) => {
                        const mine = rates.filter((r) => r.nature === n.code)
                        return (
                            <tr key={n.code as string}>
                                {/* 【按界面语言选一个,不是把两个拼起来】与仓库里另外
                                    一百多处同一个写法;check-bilingual-concat 盯着它。 */}
                                <td className="border border-gray-300 px-2 py-1">
                                    {locale === 'zh' ? (n.name_zh as string) : (n.name_en as string)}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 font-mono text-xs">
                                    {mine.map((r) => (
                                        <div key={r.effective_from as string}>
                                            {Number(r.rate_pct)}% · {String(r.effective_from)} → {(r.effective_to as string) ?? '—'}
                                        </div>
                                    ))}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 text-xs text-gray-600">
                                    {n.statute_ref as string}
                                </td>
                            </tr>
                        )
                    })}
                </tbody>
            </table>
        </div>
    )
}

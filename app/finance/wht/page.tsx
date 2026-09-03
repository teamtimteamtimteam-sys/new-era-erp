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
//
// CONV-4:套 CONV-1 的两文件模板(三张表共用一个客户端文件,理由见其抬头)。
// state 恒为 'ok' —— 这一页没有"整页无内容"这回事,三张表各自的空态各说各的。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import { RemitControl } from './WhtControls'
import { ListPage } from '@/app/components/ui/list-page'
import { WhtLiabilityTable, WhtRemittancesTable, WhtRatesTable, type LiabilityRow, type RemittanceRow, type WhtRateRow } from './WhtTables'

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

    const liabilityRows: LiabilityRow[] = liability.map((r) => ({
        periodMonth: String(r.period_month),
        withheldBase: Number(r.withheld_base),
        remittedBase: Number(r.remitted_base),
        unremittedBase: Number(r.unremitted_base),
        dueDate: String(r.due_date),
        isOverdue: !!r.is_overdue,
        daysUntilDue: Math.round((new Date(r.due_date as string).getTime() - Date.now()) / 86_400_000),
        baseCurrency: base,
    }))

    const remittanceRows: RemittanceRow[] = remittances.map((r) => ({
        id: r.id as string,
        code: r.code as string,
        periodMonth: String(r.period_month),
        remittedOn: String(r.remitted_on),
        amountBase: Number(r.amount_base),
        baseCurrency: base,
        filedReference: r.filed_reference as string,
    }))

    const rateRows: WhtRateRow[] = natures.map((n) => ({
        code: n.code as string,
        // 【按界面语言选一个,不是把两个拼起来】与仓库里另外一百多处同一个写法;
        // check-bilingual-concat 盯着它。
        name: locale === 'zh' ? (n.name_zh as string) : (n.name_en as string),
        statuteRef: n.statute_ref as string,
        rates: rates.filter((r) => r.nature === n.code),
    }))

    return (
        <ListPage title={t('wht.title')} intro={t('wht.subtitle')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}>
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
            <div className="mb-6">
                <WhtLiabilityTable
                    rows={liabilityRows}
                    empty={
                        // 【具名的缺席】"还没有代扣过任何税"是一句关于账本的真话,
                        // 而一张空表读起来像页面坏了。
                        <div className="text-sm">
                            <strong>{t('wht.noneTitle')}</strong>
                            <br />
                            <span className="text-gray-600">{t('wht.noneBody')}</span>
                        </div>
                    }
                />
            </div>

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
            <div className="mb-6">
                <WhtRemittancesTable rows={remittanceRows} empty={t('wht.noRemittances')} />
            </div>

            {/* ── 法定税率:一张【待核对】的表 ─────────────────────────────────── */}
            <h2 className="font-semibold mb-2">{t('wht.ratesHeading')}</h2>
            {/* ★ 这一段是 1.5/G 在屏幕上的落点:形状是工程判断,数字是法律事实 ★ */}
            <p className="text-sm mb-3 bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded">
                <strong>{t('wht.ratesUnverifiedTitle')}</strong>
                <br />
                {t('wht.ratesUnverifiedBody')}
            </p>
            <div className="mb-6">
                <WhtRatesTable rows={rateRows} />
            </div>
        </ListPage>
    )
}

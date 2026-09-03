// app/finance/gst/page.tsx
// GST:注册状态、税码与它们的生效税率、申报期间。
//
// CONV-4:套 CONV-1 的两文件模板 —— 两张表(税码参照、申报期间)都是只读账簿。
// state 恒为 'ok':这一页没有"进不去"或"整页无内容"这两种状态,注册状态与
// 税码字典总是有得说;期间可以是空的,但那不是全页的空,由 DataTable 自己的
// empty 说。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustRows, mustOne, mustCount } from '@/lib/db-helpers'
import { OpenPeriodControl } from './GstControls'
import { ListPage } from '@/app/components/ui/list-page'
import GstTaxCodesTable, { type TaxCodeRow } from './GstTaxCodesTable'
import GstPeriodsTable, { type GstPeriodRow } from './GstPeriodsTable'

export default async function GstPage() {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [settingsRes, codesRes, ratesRes, periodsRes, codedInvRes, codedExpRes] = await Promise.all([
        supabase.from('finance_settings').select('gst_registered, gst_registration_no').eq('id', true).single(),
        supabase.from('tax_codes').select('code, side, name_en, name_zh, f5_supply_box, f5_purchase_box, f5_tax_box, is_claimable, sort_order').order('sort_order'),
        supabase.from('tax_rates').select('tax_code, rate_pct, effective_from, effective_to').order('tax_code').order('effective_from'),
        supabase.from('gst_periods').select('id, code, period_start, period_end, status, filed_on, filed_reference, corrects_period_id').order('period_start', { ascending: false }),
        // ★【GST-2:测量的对象【变了】,因为 F5 的来源变了】★
        // GST-1 时代九格全部从总账推导,所以"总账里有没有带税码的行"就是
        // "F5 会不会全零"。**GST-2 之后销项侧从【单据】推导** —— 一张带税码的
        // 发票根本不经过总账就能让 box1 不为零。所以这里量的是【单据】:
        // 发票行 + 费用单。仍然是一个测量,不是一个假设。
        supabase.from('invoice_lines_masked').select('id', { count: 'exact', head: true }).not('tax_code', 'is', null),
        supabase.from('expenses').select('id', { count: 'exact', head: true }).not('tax_code', 'is', null),
    ])
    const settings = mustOne(settingsRes)
    const codes = mustRows(codesRes)
    const rates = mustRows(ratesRes)
    const periods = mustRows(periodsRes)
    const registered = settings?.gst_registered ?? false
    const codedDocs = mustCount(codedInvRes) + mustCount(codedExpRes)

    const taxCodeRows: TaxCodeRow[] = codes.map((c) => ({
        code: c.code,
        side: c.side,
        // 【按界面语言选一个,不是把两个拼起来】与仓库里另外 105 处同一个写法。
        // 拼接在中文界面下勉强能读,在英文界面下就是把中文推给一个读不懂它的人。
        name: locale === 'zh' ? c.name_zh : c.name_en,
        boxes: [c.f5_supply_box, c.f5_purchase_box, c.f5_tax_box].filter(Boolean).join(' · '),
        rates: rates.filter((r) => r.tax_code === c.code),
    }))

    const periodRows: GstPeriodRow[] = periods.map((p) => ({
        id: p.id,
        code: p.code,
        isCorrection: !!p.corrects_period_id,
        window: `${p.period_start} → ${p.period_end}`,
        filed: p.status === 'filed',
        filedOn: p.filed_on,
        filedReference: p.filed_reference,
    }))

    return (
        <ListPage title={t('gst.title')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}>
            {/* 【注册与否是一句要说出来的话,不是一个空白】 */}
            <p className={'text-sm mb-6 inline-block px-3 py-2 rounded border ' +
                (registered ? 'bg-green-50 border-green-300 text-green-900'
                            : 'bg-amber-50 border-amber-300 text-amber-900')}>
                {registered
                    ? t('gst.registeredYes', { no: settings?.gst_registration_no ?? '—' })
                    : t('gst.registeredNo')}
            </p>

            {/* ★【具名的缺席,不是空白】★ 一份全零的申报表读起来会像"这一季没有
                生意",所以"为什么是零"要说出来。**GST-2 之后这句话变了**:
                单据【已经接上了】,所以零的原因不再是"机器建好了但没接线",
                而是"还没有开出过任何带税码的单据"。 */}
            {registered && codedDocs === 0 && (
                <p className="text-sm mb-6 bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded">
                    {t('gst.noCodedDocuments')}
                </p>
            )}

            <h2 className="font-semibold mb-2">{t('gst.taxCodes')}</h2>
            <p className="text-xs text-gray-600 mb-2">{t('gst.taxCodesWhy')}</p>
            <div className="mb-6">
                <GstTaxCodesTable rows={taxCodeRows} />
            </div>

            <h2 className="font-semibold mb-2">{t('gst.periods')}</h2>
            <div className="mb-4"><OpenPeriodControl /></div>
            <div className="mb-6">
                <GstPeriodsTable rows={periodRows} />
            </div>

            <p className="text-xs text-gray-500">{t('gst.filingIsOutside')}</p>
        </ListPage>
    )
}

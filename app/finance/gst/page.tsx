// app/finance/gst/page.tsx
// GST:注册状态、税码与它们的生效税率、申报期间。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustRows, mustOne, mustCount } from '@/lib/db-helpers'
import { OpenPeriodControl } from './GstControls'

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

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('gst.title')}</h1>

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
                而是"还没有开出过任何带税码的单据"。前一句在这一刀之后是假的,
                留着它会让下一个读的人以为接线这件事还没做。 */}
            {registered && codedDocs === 0 && (
                <p className="text-sm mb-6 bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded">
                    {t('gst.noCodedDocuments')}
                </p>
            )}

            <h2 className="font-semibold mb-2">{t('gst.taxCodes')}</h2>
            <p className="text-xs text-gray-600 mb-2">{t('gst.taxCodesWhy')}</p>
            <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                <thead className="bg-gray-50">
                    <tr>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.code')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.side')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.name')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.f5Box')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.rates')}</th>
                    </tr>
                </thead>
                <tbody>
                    {codes.map((c) => {
                        const mine = rates.filter((r) => r.tax_code === c.code)
                        const boxes = [c.f5_supply_box, c.f5_purchase_box, c.f5_tax_box].filter(Boolean).join(' · ')
                        return (
                            <tr key={c.code}>
                                <td className="border border-gray-300 px-2 py-1 font-mono">{c.code}</td>
                                <td className="border border-gray-300 px-2 py-1">{c.side === 'output' ? t('gst.sideOutput') : t('gst.sideInput')}</td>
                                {/* 【按界面语言选一个,不是把两个拼起来】与仓库里另外 105 处同一个写法。
                                    拼接在中文界面下勉强能读,在英文界面下就是把中文推给一个读不懂它的人。 */}
                                <td className="border border-gray-300 px-2 py-1">{locale === 'zh' ? c.name_zh : c.name_en}</td>
                                {/* 【不进任何一格也要说出来,不能留白】 */}
                                <td className="border border-gray-300 px-2 py-1">
                                    {boxes || <span className="text-gray-500">{t('gst.noBox')}</span>}
                                </td>
                                <td className="border border-gray-300 px-2 py-1">
                                    {mine.length === 0
                                        ? <span className="text-amber-700">{t('gst.noRate')}</span>
                                        : mine.map((r) => (
                                            <div key={r.effective_from} className="font-mono text-xs">
                                                {Number(r.rate_pct)}% · {r.effective_from} → {r.effective_to ?? t('gst.current')}
                                            </div>
                                        ))}
                                </td>
                            </tr>
                        )
                    })}
                </tbody>
            </table>

            <h2 className="font-semibold mb-2">{t('gst.periods')}</h2>
            <div className="mb-4"><OpenPeriodControl /></div>
            {periods.length === 0 ? (
                // 【空状态说的是"还没有开过期间",不是一张空表】
                <p className="text-sm text-gray-600 mb-6">{t('gst.noPeriods')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                    <thead className="bg-gray-50">
                        <tr>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.period')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.window')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.status')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.filing')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {periods.map((p) => (
                            <tr key={p.id}>
                                <td className="border border-gray-300 px-2 py-1">
                                    <Link href={`/finance/gst/${p.id}`} className="text-blue-600 hover:underline font-mono">{p.code}</Link>
                                    {p.corrects_period_id && <span className="ml-2 text-xs text-amber-800">{t('gst.isCorrection')}</span>}
                                </td>
                                <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{p.period_start} → {p.period_end}</td>
                                <td className="border border-gray-300 px-2 py-1">{p.status === 'filed' ? t('gst.statusFiled') : t('gst.statusOpen')}</td>
                                <td className="border border-gray-300 px-2 py-1 text-xs">
                                    {p.status === 'filed'
                                        ? <>{p.filed_on} {p.filed_reference ? `· ${p.filed_reference}` : ''}</>
                                        : <span className="text-gray-500">{t('gst.notFiledYet')}</span>}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            <p className="text-xs text-gray-500">{t('gst.filingIsOutside')}</p>
        </div>
    )
}

// app/finance/gst/[periodId]/page.tsx
// 一个 GST 期间的 F5:每一格、每一格从哪来、以及【钻进去】。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { FileReturnControl, CorrectControl } from '../GstControls'

type Box = { box: string; label_en: string; label_zh: string; value: number; derived: boolean; note_zh?: string; note_en?: string }

export default async function GstPeriodPage({ params, searchParams }: {
    params: Promise<{ periodId: string }>
    searchParams: Promise<{ box?: string }>
}) {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const { periodId } = await params
    const { box } = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const periodRes = await supabase.from('gst_periods')
        .select('id, code, period_start, period_end, status, filed_on, filed_reference, notes, corrects_period_id')
        .eq('id', periodId).single()
    const period = mustOne(periodRes)
    if (!period) return <div className="p-8">{t('gst.periodMissing')}</div>

    const lockedRes = await supabase.from('finance_settings').select('locked_before').eq('id', true).single()
    const lockedBefore = mustOne(lockedRes)?.locked_before ?? null

    // 【已申报的期间读【抄下来的那一份】;未申报的现算】—— 两者是不同的问题。
    const filed = period.status === 'filed'
    const liveRes = await supabase.rpc('f5_return', {
        p_period_start: period.period_start, p_period_end: period.period_end,
    })
    const snapRes = filed
        ? await supabase.from('gst_return_boxes').select('box, label_en, label_zh, value_base').eq('period_id', periodId).order('box')
        : null

    const live = liveRes.data as unknown as { boxes: Box[]; ties: Record<string, unknown> } | null
    const snap = snapRes ? mustRows(snapRes) : []
    const detailRes = box
        ? await supabase.rpc('f5_box_detail', {
            p_period_start: period.period_start, p_period_end: period.period_end, p_box: box,
        })
        : null

    // 申报被挡住时的【具体】理由,而不是一个析取式
    const blockedWhy =
        filed ? t('gst.blockedAlreadyFiled', { on: period.filed_on ?? '' })
        : (!lockedBefore || lockedBefore <= period.period_end)
            ? t('gst.blockedNotLocked', { end: period.period_end, locked: lockedBefore ?? t('finance.notSet') })
            : undefined

    return (
        <div className="p-8 max-w-5xl">
            <p className="text-sm mb-2"><Link href="/finance/gst" className="text-blue-600 hover:underline">← {t('gst.title')}</Link></p>
            <h1 className="text-2xl font-bold mb-1">{period.code}</h1>
            <p className="text-sm text-gray-600 mb-4 font-mono">{period.period_start} → {period.period_end}</p>
            {period.corrects_period_id && (
                <p className="text-sm mb-4 bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded">
                    {t('gst.correctionOf')}{period.notes ? ` — ${period.notes}` : ''}
                </p>
            )}

            {filed && (
                <p className="text-sm mb-4 bg-green-50 border border-green-300 text-green-900 px-3 py-2 rounded">
                    {t('gst.filedOnBanner', { on: period.filed_on ?? '', ref: period.filed_reference ?? '—' })}
                </p>
            )}

            <div className="flex items-baseline justify-between mb-2">
                <h2 className="font-semibold">{filed ? t('gst.asFiled') : t('gst.asComputed')}</h2>
                {/* 【导出的是屏幕上这一份】—— 已申报导抄下来的,未申报导现算的,文件名里写明是哪一种 */}
                <a href={`/finance/gst/${periodId}/export`}
                   className="text-sm text-blue-600 hover:underline">{t('gst.exportCsv')}</a>
            </div>
            <table className="w-full border-collapse border border-gray-300 mb-2 text-sm">
                <thead className="bg-gray-50">
                    <tr>
                        <th className="border border-gray-300 px-2 py-1 text-left w-20">{t('gst.box')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.boxLabel')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-right">{t('gst.amount')}</th>
                        <th className="border border-gray-300 px-2 py-1 text-left w-28">{t('gst.openBox')}</th>
                    </tr>
                </thead>
                <tbody>
                    {(filed ? snap.map((b) => ({ box: b.box, label_zh: b.label_zh, label_en: b.label_en, value: Number(b.value_base), derived: true }))
                            : (live?.boxes ?? [])).map((b) => (
                        <tr key={b.box} className={box === b.box ? 'bg-blue-50' : ''}>
                            <td className="border border-gray-300 px-2 py-1 font-mono">{b.box.replace('box', '')}</td>
                            <td className="border border-gray-300 px-2 py-1">
                                {b.label_zh} / {b.label_en}
                                {/* 【结构性为零要说出来,不能只显示 0】 */}
                                {'derived' in b && !b.derived && (
                                    <span className="block text-xs text-gray-600">{t('gst.notDerived')}</span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{Number(b.value).toFixed(2)}</td>
                            <td className="border border-gray-300 px-2 py-1">
                                {['box1','box2','box3','box5','box6','box7'].includes(b.box)
                                    ? <Link href={`/finance/gst/${periodId}?box=${b.box}`} className="text-blue-600 hover:underline text-xs">{t('gst.openBox')}</Link>
                                    : <span className="text-xs text-gray-500">{t('gst.notDrillable')}</span>}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>

            {/* 【勾稽:两条独立的路,而且它说得出自己怎么算的】 */}
            {live?.ties != null && (
                <p className={'text-xs mb-6 px-3 py-2 rounded border ' +
                    ((live.ties as { agrees?: boolean }).agrees
                        ? 'bg-green-50 border-green-300 text-green-900'
                        : 'bg-red-50 border-red-400 text-red-800')}>
                    {(live.ties as { agrees?: boolean }).agrees ? t('gst.tiesOk') : t('gst.tiesBroken')}
                    {' '}
                    <span className="font-mono">
                        {String((live.ties as { box6_from_tax_account?: number }).box6_from_tax_account)}
                        {' vs '}
                        {String((live.ties as { box6_recomputed_from_supplies?: number }).box6_recomputed_from_supplies)}
                    </span>
                    <span className="block mt-1">{String((live.ties as { how_zh?: string }).how_zh ?? '')}</span>
                </p>
            )}

            {box && (
                <>
                    <h2 className="font-semibold mb-2">{t('gst.boxDetail', { box: box.replace('box', '') })}</h2>
                    {detailRes?.error ? (
                        <p className="text-sm text-red-700 mb-6">{detailRes.error.message}</p>
                    ) : (detailRes?.data as unknown[] | null)?.length ? (
                        <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                            <thead className="bg-gray-50">
                                <tr>
                                    <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.entry')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.date')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.memo')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.source')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-right">{t('gst.amount')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {(detailRes!.data as { entry_id: string; entry_code: string; entry_date: string; memo: string; source_type: string; tax_code: string | null; amount_base: number }[]).map((d) => (
                                    <tr key={d.entry_id + d.entry_code}>
                                        <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{d.entry_code}</td>
                                        <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{d.entry_date}</td>
                                        <td className="border border-gray-300 px-2 py-1">{d.memo}</td>
                                        <td className="border border-gray-300 px-2 py-1 text-xs">{d.source_type}{d.tax_code ? ` · ${d.tax_code}` : ''}</td>
                                        <td className="border border-gray-300 px-2 py-1 text-right font-mono">{Number(d.amount_base).toFixed(2)}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    ) : (
                        <p className="text-sm text-gray-600 mb-6">{t('gst.boxEmpty')}</p>
                    )}
                </>
            )}

            <h2 className="font-semibold mb-2">{t('gst.recordFiling')}</h2>
            <p className="text-xs text-gray-600 mb-2">{t('gst.filingIsOutside')}</p>
            <div className="mb-6"><FileReturnControl periodId={periodId} blockedWhy={blockedWhy} /></div>

            {filed && (
                <>
                    <h2 className="font-semibold mb-2">{t('gst.raiseCorrection')}</h2>
                    <p className="text-xs text-gray-600 mb-2">{t('gst.correctionWhy')}</p>
                    <CorrectControl periodId={periodId} />
                </>
            )}
        </div>
    )
}

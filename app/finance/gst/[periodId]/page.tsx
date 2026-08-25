// app/finance/gst/[periodId]/page.tsx
// 一个 GST 期间的 F5:每一格、每一格从哪来、以及【钻进去】。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
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
    const locale = await getLocale()

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

    // 【被打开的那一格的数字】—— 钻取那一段要把它重复出来,好让"空"读起来
    // 是一个答案而不是一次失败。已申报读快照,未申报读现算的那一份,与上面同源。
    const openBoxValue = box
        ? (filed
            ? Number(snap.find((r) => r.box === box)?.value_base ?? 0)
            : Number((live?.boxes ?? []).find((b) => b.box === box)?.value ?? 0))
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
                                    // 【#box-detail:让链接跳到它打开的那一段】GST-FIX-1 实测:
                                    // 钻取确实渲染了,但它落在文档 28% 处 —— 从表格顶上点一下,
                                    // 视口一动不动。**一个看起来什么都没做的控件,比一个明确拒绝的更坏。**
                                    ? <Link href={`/finance/gst/${periodId}?box=${b.box}#box-detail`} className="text-blue-600 hover:underline text-xs">{t('gst.openBox')}</Link>
                                    : <span className="text-xs text-gray-500">{t('gst.notDrillable')}</span>}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>

            {/* 【GST-2:勾稽是【三处说法、两条比较】,而两条都要看得见】
                只印一个"对上了/没对上"会把【哪一条】没对上藏起来,而两条指向
                的修法完全不同:单据 vs 法令是税率或数字错了;单据 vs 总账是
                某张票没过账、作废没冲销、或有人手工动过 2100。 */}
            {live?.ties != null && (() => {
                const ties = live.ties as {
                    agrees?: boolean
                    agrees_documents_vs_statute?: boolean
                    agrees_documents_vs_ledger?: boolean
                    box6_from_documents?: number
                    box6_recomputed_from_statute?: number
                    box6_from_tax_account?: number
                    how_zh?: string
                    how_en?: string
                }
                return (
                    <div className={'text-xs mb-6 px-3 py-2 rounded border ' +
                        (ties.agrees
                            ? 'bg-green-50 border-green-300 text-green-900'
                            : 'bg-red-50 border-red-400 text-red-800')}>
                        <p className="font-medium">{ties.agrees ? t('gst.tiesOk') : t('gst.tiesBroken')}</p>
                        <p className="mt-1">
                            {ties.agrees_documents_vs_statute ? '✓' : '✗'}{' '}
                            {t('gst.tieDocsVsStatute')}{' '}
                            <span className="font-mono">
                                {String(ties.box6_from_documents)} vs {String(ties.box6_recomputed_from_statute)}
                            </span>
                        </p>
                        <p>
                            {ties.agrees_documents_vs_ledger ? '✓' : '✗'}{' '}
                            {t('gst.tieDocsVsLedger')}{' '}
                            <span className="font-mono">
                                {String(ties.box6_from_documents)} vs {String(ties.box6_from_tax_account)}
                            </span>
                        </p>
                        <p className="mt-1">{String(locale === 'zh' ? (ties.how_zh ?? '') : (ties.how_en ?? ''))}</p>
                    </div>
                )
            })()}

            {/* ★【钻取那一段:锚点 + 看得见的边框】★ GST-FIX-1
                实测发现的不是"钻取坏了"—— 它是对的,而且与 F5 逐格一致。
                坏的是【反馈】:点一下之后,变化是一行淡蓝底色加上 28% 处的一段文字,
                而人的视口在原地。所以这里做三件事:给它一个 id 让链接跳得过来、
                给它一个边框让它在页面上是一块【东西】、并且把这一格的数字重复一遍,
                好让"空"读起来是一个答案而不是一次失败。
                data-box-detail 是给冒烟用的机器标记 —— 本仓库此前从不发查询串,
                于是整条钻取路径没有任何自动检查看得见(见 docs/known-issues.md)。 */}
            {box && (
                <section id="box-detail" data-box-detail={box}
                         className="border-2 border-blue-300 bg-blue-50/40 rounded p-4 mb-6 scroll-mt-4">
                    <h2 className="font-semibold mb-1">{t('gst.boxDetail', { box: box.replace('box', '') })}</h2>
                    {/* 【把这一格的数字放在这里】没有它,"这一格里没有东西"读起来像查询失败;
                        有了它,读者立刻知道:这一格【本来就是】这个数。 */}
                    <p className="text-xs text-gray-600 mb-3">
                        {t('gst.boxDetailFor', {
                            box: box.replace('box', ''),
                            value: (openBoxValue ?? 0).toFixed(2),
                            currency: String((live as { currency?: string } | null)?.currency ?? ''),
                        })}
                    </p>
                    {detailRes?.error ? (
                        <p data-box-detail-error className="text-sm text-red-700">{detailRes.error.message}</p>
                    ) : (detailRes?.data as unknown[] | null)?.length ? (
                        <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                            <thead className="bg-gray-50">
                                <tr>
                                    <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.document')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.date')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.memo')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-left">{t('gst.source')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-right">{t('gst.amount')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {/* 【GST-2:列是【单据中性】的】销项侧钻回的是发票与贷项凭证,
                                    它们不是分录 —— 把一个发票编号印在"分录"那一列下面,
                                    正是"机器文字到了人面前"那一类的错。doc_kind 说这是什么。 */}
                                {(detailRes!.data as { doc_kind: string; doc_id: string; doc_code: string; doc_date: string; memo: string; tax_code: string | null; amount_base: number }[]).map((d, i) => (
                                    <tr key={d.doc_id + d.doc_code + i}>
                                        <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{d.doc_code}</td>
                                        <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{d.doc_date}</td>
                                        <td className="border border-gray-300 px-2 py-1">{d.memo}</td>
                                        <td className="border border-gray-300 px-2 py-1 text-xs">
                                            {t('gst.docKind.' + d.doc_kind)}{d.tax_code ? ` · ${d.tax_code}` : ''}
                                        </td>
                                        {/* 贷项凭证是负数 —— 它是一笔【负的供应】,照直印 */}
                                        <td className="border border-gray-300 px-2 py-1 text-right font-mono">{Number(d.amount_base).toFixed(2)}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    ) : (
                        /* 【空要说出【为什么】空】"这一格里没有东西"与"查询失败了"
                           在屏幕上长得一模一样。数字是 0 的时候就直说是 0;
                           数字不是 0 却钻不出行,那才是真的不对劲,单独说。 */
                        <p className="text-sm text-gray-700">
                            {(openBoxValue ?? 0) === 0
                                ? t('gst.boxEmptyBecauseZero')
                                : t('gst.boxEmptyButNonZero', { value: (openBoxValue ?? 0).toFixed(2) })}
                        </p>
                    )}
                </section>
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

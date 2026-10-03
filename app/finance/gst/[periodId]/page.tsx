// app/finance/gst/[periodId]/page.tsx
// 一个 GST 期间的 F5:每一格、每一格从哪来、以及【钻进去】。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { CorrectControl } from '../GstControls'
import GstFilingPanel, { type GstFilingView, type GstBoxLine } from './GstFilingPanel'
import { ListPage } from '@/app/components/ui/list-page'
import { F5BoxesTable, F5BoxDetailTable, type F5BoxRow, type F5DetailRow } from './GstTables'
import { Button } from '@/app/components/ui/button'
import { can } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'

type Box = { box: string; label_en: string; label_zh: string; value: number; derived: boolean; note_zh?: string; note_en?: string }

export default async function GstPeriodPage({ params, searchParams }: {
    params: Promise<{ periodId: string }>
    searchParams: Promise<{ box?: string; trail?: string }>
}) {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const canEditGate = await can('module.finance.edit')
    // APR-10:决定的门(module.finance.view + data.view_prices);谁是二级、谁是提单人由库裁
    const canPrices = await can('data.view_prices')
    const { periodId } = await params
    const { box, trail } = await searchParams
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
    // ★ APR-10:CFO 批准过的期间(approved)同样读快照 —— 批准那一刻抄下来的就是要报出去的那一份。
    const filed = period.status === 'filed'
    const snapshotted = filed || period.status === 'approved'
    const liveRes = await supabase.rpc('f5_return', {
        p_period_start: period.period_start, p_period_end: period.period_end,
    })
    const snapRes = snapshotted
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
        ? (snapshotted
            ? Number(snap.find((r) => r.box === box)?.value_base ?? 0)
            : Number((live?.boxes ?? []).find((b) => b.box === box)?.value ?? 0))
        : null

    // 提申报申请被挡住时的【具体】理由,而不是一个析取式(已申报 / 已批准的期间不画提交那一块)
    const blockedWhy =
        (!lockedBefore || lockedBefore <= period.period_end)
            ? t('gst.blockedNotLocked', { end: formatDate(period.period_end, locale), locked: formatDate(lockedBefore, locale) ?? t('finance.notSet') })
            : undefined

    // ★ APR-10:这一期的申报申请(在等的全部 + 最近了结的十张)。冻结的每一格、此刻的数(只对在等的算)、
    //   更正件的原件快照 —— 全由 gst_filing_requests_visible 一次给出,屏幕不自己算。
    type VisibleBox = { box: string; label_en?: string; label_zh?: string; value: number | string }
    const gfrRows = mustRows(await supabase.rpc('gst_filing_requests_visible', { p_period_id: periodId, p_recent: 10 }),
        'gst_filing_requests_visible') as unknown as {
        id: string; status: GstFilingView['status']; label: string
        boxes: VisibleBox[]; current_boxes: VisibleBox[] | null; current_matches: boolean | null
        original_code: string | null; original_boxes: VisibleBox[] | null; note: string | null
        created_at: string; created_by_email: string | null; raised_by_me: boolean
        decided_at: string | null; decided_by_email: string | null; decision_notes: string | null
        withdrawn_at: string | null; withdraw_reason: string | null
    }[]
    const toView = (r: (typeof gfrRows)[number]): GstFilingView => {
        const nowBy = new Map((r.current_boxes ?? []).map((b) => [b.box, Number(b.value)]))
        const origBy = new Map((r.original_boxes ?? []).map((b) => [b.box, Number(b.value)]))
        const lines: GstBoxLine[] = (r.boxes ?? []).map((b) => ({
            box: b.box,
            label: (locale === 'zh' ? b.label_zh : b.label_en) ?? b.box,
            frozen: Number(b.value),
            now: r.current_boxes ? (nowBy.get(b.box) ?? null) : null,
            original: r.original_code ? (origBy.get(b.box) ?? null) : null,
        }))
        return {
            id: r.id, status: r.status, label: r.label, lines,
            currentMatches: r.current_matches, originalCode: r.original_code, note: r.note,
            createdText: formatDate(r.created_at, locale) ?? '',
            raisedBy: r.created_by_email, raisedByMe: r.raised_by_me,
            decidedBy: r.decided_by_email, decisionNotes: r.decision_notes, withdrawReason: r.withdraw_reason,
        }
    }
    const gfrOpen = gfrRows.filter((r) => r.status === 'submitted').map(toView)
    const gfrHistory = gfrRows.filter((r) => r.status !== 'submitted').map(toView)


    // ★【行数据在服务端压平】双语标签在这里按 locale 选好,压成一个字符串过界。
    const DRILLABLE = ['box1', 'box2', 'box3', 'box5', 'box6', 'box7']
    const boxSource = snapshotted
        ? snap.map((b) => ({ box: b.box, label_zh: b.label_zh, label_en: b.label_en, value: Number(b.value_base), derived: true }))
        : (live?.boxes ?? [])
    const boxRows: F5BoxRow[] = boxSource.map((b) => ({
        id: b.box,
        boxNo: b.box.replace('box', ''),
        label: locale === 'zh' ? b.label_zh : b.label_en,
        notDerived: 'derived' in b && !b.derived,
        amountText: Number(b.value).toFixed(2),
        drillHref: DRILLABLE.includes(b.box) ? `/finance/gst/${periodId}?box=${b.box}#box-detail` : null,
        highlighted: box === b.box,
    }))

    const detailRows: F5DetailRow[] = (
        (detailRes?.data as { doc_kind: string; doc_id: string; doc_code: string; doc_date: string; memo: string; tax_code: string | null; amount_base: number }[] | null) ?? []
    ).map((d, i) => ({
        id: d.doc_id + d.doc_code + i,
        docCode: d.doc_code,
        docDate: formatDate(d.doc_date, locale),
        memo: d.memo,
        sourceText: t('gst.docKind.' + d.doc_kind) + (d.tax_code ? ` · ${d.tax_code}` : ''),
        amountText: Number(d.amount_base).toFixed(2),
    }))

    return (
        <ListPage
            maxWidth="max-w-5xl"
            // 转换前这条返回链接画在 <h1> 之上 —— breadcrumb 槽是同一个位置。
            breadcrumb={
                <p className="text-sm">
                    <Link href="/finance/gst" className="hover:underline app-link">← {t('gst.title')}</Link>
                </p>
            }
            title={period.code}
            intro={<span>{formatDate(period.period_start, locale)} → {formatDate(period.period_end, locale)}</span>}
            // ★★ 详情页恒为 ok —— 这个期间在不在由上面 mustOne + periodMissing 回答。
            state={{ kind: 'ok' }}
            notices={
                <>
                    {period.corrects_period_id && (
                        <p className="text-sm mb-4 bg-amber-50 border border-amber-300 text-amber-900 px-3 py-2 rounded">
                            {t('gst.correctionOf')}{period.notes ? ` — ${period.notes}` : ''}
                        </p>
                    )}
                    {period.status === 'approved' && (
                        <p className="text-sm mb-4 bg-blue-50 border border-blue-300 text-blue-900 px-3 py-2 rounded">
                            {t('gstFiling.approvedBanner')}
                        </p>
                    )}
                    {filed && (
                        <p className="text-sm mb-4 bg-green-50 border border-green-300 text-green-900 px-3 py-2 rounded">
                            {t('gst.filedOnBanner', { on: formatDate(period.filed_on, locale) ?? '', ref: period.filed_reference ?? '—' })}
                        </p>
                    )}
                </>
            }
        >
            <div className="flex items-baseline justify-between mb-2">
                <h2 className="">{filed ? t('gst.asFiled') : snapshotted ? t('gstFiling.asApproved') : t('gst.asComputed')}</h2>
                {/* 【导出的是屏幕上这一份】—— 已申报导抄下来的,未申报导现算的,文件名里写明是哪一种 */}
                <Button asChild variant="outline">
                    <a href={`/finance/gst/${periodId}/export`}>{t('gst.exportCsv')}</a>
                </Button>
            </div>
            <div className="mb-2">
                <F5BoxesTable rows={boxRows} />
            </div>

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
                            <span>
                                {String(ties.box6_from_documents)} vs {String(ties.box6_recomputed_from_statute)}
                            </span>
                        </p>
                        <p>
                            {ties.agrees_documents_vs_ledger ? '✓' : '✗'}{' '}
                            {t('gst.tieDocsVsLedger')}{' '}
                            <span>
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
                    <h2 className="mb-1">{t('gst.boxDetail', { box: box.replace('box', '') })}</h2>
                    {/* 【把这一格的数字放在这里】没有它,"这一格里没有东西"读起来像查询失败;
                        有了它,读者立刻知道:这一格【本来就是】这个数。 */}
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">
                        {t('gst.boxDetailFor', {
                            box: box.replace('box', ''),
                            value: (openBoxValue ?? 0).toFixed(2),
                            currency: String((live as { currency?: string } | null)?.currency ?? ''),
                        })}
                    </p>
                    {detailRes?.error ? (
                        <p data-box-detail-error className="text-sm text-red-700">{detailRes.error.message}</p>
                    ) : (
                        /* 【空要说出【为什么】空】"这一格里没有东西"与"查询失败了"
                           在屏幕上长得一模一样。数字是 0 的时候就直说是 0;
                           数字不是 0 却钻不出行,那才是真的不对劲,单独说。
                           ★ 这句区分现在由表自己的 empty 承担 —— 服务端把该说哪一句
                             算好了传进去,区分一个字都没有被压平。 */
                        <F5BoxDetailTable
                            rows={detailRows}
                            empty={
                                (openBoxValue ?? 0) === 0
                                    ? t('gst.boxEmptyBecauseZero')
                                    : t('gst.boxEmptyButNonZero', { value: (openBoxValue ?? 0).toFixed(2) })
                            }
                        />
                    )}
                </section>
            )}

            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('gst.filingIsOutside')}</p>
            {/* ★ 出口检查:申报申请那一块与更正控件都住 children,而 state 恒为 'ok',
                  所以它们不可能被任何空分支吃掉。
                ★ APR-10:申报从此是一张申请 —— 提、批、驳、撤回、批准之后记下申报,全在这一块里。 */}
            <GstFilingPanel
                periodId={periodId}
                periodCode={period.code}
                periodStatus={period.status as 'open' | 'approved' | 'filed'}
                open={gfrOpen}
                history={gfrHistory}
                blockedWhy={blockedWhy}
                canEdit={canEditGate}
                canDecide={canPrices}
                holdsDecideView={true}
            />

            {filed && (
                <>
                    <h2 className="mb-2">{t('gst.raiseCorrection')}</h2>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('gst.correctionWhy')}</p>
                    <CorrectControl canEdit={canEditGate} periodId={periodId} />
                </>
            )}

            {/* AUDIT-TRAIL-1c-2(Q22 · Q23):这个期间的审计记录 —— 开期(更正件说它为哪一期开的)、申报申请与它的审批、
                批准那一刻抄下来的每一格(并进申报那一条,只说英文)、记下申报。更正件【不】出现在原件的记录里(原件页上那条链接照旧) */}
            <AuditTrail subject="gst_period" id={periodId} show={trailCount(trail)} />
        </ListPage>
    )
}

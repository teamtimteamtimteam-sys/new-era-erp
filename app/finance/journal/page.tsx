// app/finance/journal/page.tsx
// 分录列表:最新在前,entry_date 日期区间 + count+range 分页(端口自 processing 列表)。
// 来源列按 source_type 本地化,可解析的 source_id 附业务单据链接(服务端小批量反查)。
//
// CONV-4:套 CONV-1 的两文件模板。state 恒为 'ok' —— 筛选工具栏是真实出口。
import { Suspense } from 'react'
import { DatePresetLinks } from '@/app/components/ui/date-presets'
import { SavedViewsBar } from '@/app/components/ui/saved-views'
import { loadSavedViews } from '@/lib/savedViewsServer'
import { readDatePresets } from '@/lib/datePresetsServer'
import { getBaseCurrency } from '@/lib/currency'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import JournalToolbar from './JournalToolbar'
import JournalTable, { type JournalRow } from './JournalTable'
import { parseJournalListParams, journalCount, journalPage, shapeJournalRows, journalListExportHref, journalTotals } from './journalRows'
import { mustOne, mustRows, mustCount } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { Button } from '@/app/components/ui/button'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import { can, canViewPrices } from '@/lib/permissions'
import JournalRequestsPanel, { type JournalRequestView } from './JournalRequestsPanel'
import { setSortParams } from '@/lib/listSort'
import { readAll, readAllIn } from '@/lib/readAll'

const JOURNAL_PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function JournalListPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; page?: string; trail?: string; sort?: string; dir?: string }>
}) {
    const locale = await getLocale()
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    // TABLE-FEATURES-3(Tim 2026-10-26 Q1–Q3):保存的视图 —— 地址为空时套用本人的默认视图(一次跳转,所以在任何别的查询之前);
    //   日期快捷区间也挪到这里:存视图时认区间名、打开时按今天重算,都要它。
    const presets = await readDatePresets(supabase)
    const viewDates = { fromKey: 'date_from', toKey: 'date_to', presets }
    const savedViews = await loadSavedViews(supabase, { listKey: '/finance/journal', sp, dates: viewDates })
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    // TABLE-EXPORT-2a:读取与「库里的行 → 表的行」(含每张分录的金额与来源链接)搬进 journalRows.ts,与清单导出路由共用一份。
    const params = parseJournalListParams(sp)
    const listParams = params
    const { dateFrom, dateTo } = params
    const requestedPage = parsePage(sp.page)

    // 1) 匹配总数 —— 数不出来就失败(mustCount),不读成 0
    const total = mustCount(await journalCount(supabase, params), 'journal_entries count')
    const totalPages = Math.max(1, Math.ceil(total / JOURNAL_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * JOURNAL_PAGE_SIZE
    const to = from + JOURNAL_PAGE_SIZE - 1

    // TABLE-FEATURES-2 Q1:表尾合计 = 所有符合筛选的分录,库算(不是这一页的和;冲销记负)
    const totals = await journalTotals(supabase, params)

    // 2) 取当前页(创建序最新在前)
    //    ★ TABLE-FEATURES-1 Q7:默认改为分录日最新在前(平局按建立时刻、再按 id);可按表头换序 —— 见 journalRows.ts
    const { data: entries, error } = await journalPage(supabase, params, from, to)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="mb-4">{t('finance.journalTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(error, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        setSortParams(params, listParams.sort)  // TABLE-FEATURES-1 Q9:翻页保留排序
        params.set('page', String(targetPage))
        return `/finance/journal?${params.toString()}`
    }

    // 3) 每张分录的金额(Σ借方,受限的给 null)+ 来源链接 —— 在 journalRows.ts 里
    const tableRows: JournalRow[] = await shapeJournalRows(supabase, entries ?? [], true)

    // ── APR-6:在等 CFO 的手工凭证 / 冲销申请(全部),以及最近了结的十张 ─────────────────────────
    // 申请表的读策略是 module.finance.view —— 进得了这一页的人都读得到,所以"读不到"只会是一次真的失败
    // (mustRows 抛),不会被当成"没有申请"。批 / 驳要 data.view_prices(门的另一半),撤回要
    // module.finance.edit 或是提单人本人(库那一侧按人判,这里只画钮)。
    // ★ U1-B(Tim:data.view_pay 的规矩):amount_base 在基表上已从 authenticated 收回 —— 读遮蔽伴生视图
    //   journal_requests_masked。一张工资分录(发薪 · 公积金 · 扣款)的冲销申请,金额就是那张分录的合计;
    //   不持 data.view_pay 的人那一格是 NULL,amount_restricted 说出"这个 NULL 是受限,不是零"。
    //   行谓词与基表的读策略同一个(module.finance.view),所以"读不到"仍然只会是一次真的失败。
    const reqCols = 'id, label, kind, status, entry_date, memo, lines, target_entry_id, amount_base, amount_restricted, credits_bank, result_journal_entry_id, decision_notes, withdraw_reason, created_at, created_by'
    const [openReqRes, histReqRes, settingsRes, canDecideRequest, canEditJournal, accountsRes] = await Promise.all([
        readAll(() => supabase.from('journal_requests_masked').select(reqCols).eq('status', 'submitted').order('created_at', { ascending: true }), { label: 'journal_requests_masked' }),
        supabase.from('journal_requests_masked').select(reqCols).neq('status', 'submitted').order('created_at', { ascending: false }).limit(10),
        supabase.from('finance_settings').select('locked_before').maybeSingle(),
        canViewPrices(),
        can('module.finance.edit'),
        supabase.from('accounts').select('code, name_en, name_zh'),
    ])
    const { data: meData, error: meErr } = await supabase.auth.getUser()
    const myUserId = meErr ? null : (meData.user?.id ?? null)
    type RawJournalRequest = {
        id: string; label: string; kind: JournalRequestView['kind']; status: JournalRequestView['status']
        entry_date: string; memo: string; lines: unknown; target_entry_id: string | null
        amount_base: number | null; amount_restricted: boolean
        credits_bank: boolean; result_journal_entry_id: string | null
        decision_notes: string | null; withdraw_reason: string | null; created_at: string; created_by: string
    }
    const rawRequests = [
        ...(mustRows(openReqRes, 'journal_requests_masked') as unknown as RawJournalRequest[]),
        ...(mustRows(histReqRes, 'journal_requests_masked') as unknown as RawJournalRequest[]),
    ]
    const lockedBefore = mustOne(settingsRes, 'finance_settings')?.locked_before ?? null
    const accountName = new Map(mustRows(accountsRes, 'accounts').map((a) => [a.code, locale === 'zh' ? a.name_zh : a.name_en]))
    const linkedIds = Array.from(new Set(rawRequests.flatMap((r) => [r.target_entry_id, r.result_journal_entry_id]).filter((x): x is string => !!x)))
    const linkedRes = linkedIds.length
        ? await readAllIn(linkedIds, (__ids) => supabase.from('journal_entries').select('id, code').in('id', __ids), { label: 'journal_entries' })
        : { data: [] as { id: string; code: string }[], error: null }
    const entryCode = new Map(mustRows(linkedRes, 'journal_entries').map((e) => [e.id, e.code]))
    type RawLine = { account_code?: string; side?: string; currency?: string; amount_ccy?: number; fx_rate?: number; line_memo?: string }
    const toView = (r: RawJournalRequest): JournalRequestView => ({
        id: r.id, label: r.label, kind: r.kind, status: r.status,
        entryDateText: formatDate(r.entry_date, locale),
        memo: r.memo,
        // 受限 → null + amountRestricted:面板印「受限」,不印一个由 NULL 变出来的 0.00(AGENTS.md「0.00 and 受限」)。
        amountBase: r.amount_restricted || r.amount_base === null ? null : Number(r.amount_base),
        amountRestricted: !!r.amount_restricted,
        creditsBank: r.credits_bank,
        periodLocked: lockedBefore !== null && r.entry_date < lockedBefore,
        lines: (Array.isArray(r.lines) ? (r.lines as RawLine[]) : []).map((l, i) => {
            // 本位币折算与 post_journal_entry 同式:round(amount × fx, 2);本位币行 fx = 1
            const base = Math.round(Number(l.amount_ccy ?? 0) * (l.currency === baseCurrency ? 1 : Number(l.fx_rate ?? 0)) * 100) / 100
            const text = formatAmount(base, baseCurrency)
            return {
                key: `${r.id}-${i}`,
                accountText: `${l.account_code ?? '—'} - ${accountName.get(l.account_code ?? '') ?? '—'}`,
                debitText: l.side === 'debit' ? text : '',
                creditText: l.side === 'credit' ? text : '',
                memo: l.line_memo ?? '',
            }
        }),
        targetEntry: r.target_entry_id ? { id: r.target_entry_id, code: entryCode.get(r.target_entry_id) ?? '—' } : null,
        resultEntry: r.result_journal_entry_id ? { id: r.result_journal_entry_id, code: entryCode.get(r.result_journal_entry_id) ?? '—' } : null,
        decisionNotes: r.decision_notes, withdrawReason: r.withdraw_reason,
        createdText: formatAuditStamp(r.created_at), raisedByMe: r.created_by === myUserId,
    })
    const openRequests = rawRequests.filter((r) => r.status === 'submitted').map(toView)
    const requestHistory = rawRequests.filter((r) => r.status !== 'submitted').map(toView)


    return (
        <ListPage title={t('finance.journalTitle')} state={{ kind: 'ok' }}>
            <JournalRequestsPanel
                trails={Object.fromEntries(rawRequests.map((r) => [r.id,
                    <AuditTrail key={r.id} subject="journal_request" id={r.id} show={trailCount(sp.trail)} anchor={`jr-trail-${r.id}`} compact />]))}
                open={openRequests}
                history={requestHistory}
                canDecide={canDecideRequest}
                canWithdraw={canEditJournal}
                baseCurrency={baseCurrency}
                lockedBeforeText={lockedBefore ? formatDate(lockedBefore, locale) : null}
            />

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <SavedViewsBar listKey="/finance/journal" views={savedViews} dates={viewDates} />
                <DatePresetLinks presets={presets} fromKey="date_from" toKey="date_to" pageKey="page" />
                <JournalToolbar />
            </Suspense>

            <div className="flex flex-wrap items-center gap-4 mb-4">
                <p className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('finance.recordCount', { count: total })}
                </p>
                {/* ★【总账导出的入口】★ 一个没有入口的导出路由,路由冒烟照样 200 ——
                    而这个仓库为「无门上线」付过两次账(SAL-B6 的客户页、
                    FRT-FIX 的货代下拉)。期间沿用工具栏此刻筛的那一段:
                    导出必须有期间,而让人再填一遍就是同一个问题问两次。
                    【筛选为空时不给链接,而是说出为什么】—— 一份"默认全部"的
                    总账导出说不出自己覆盖到哪天。 */}
                {dateFrom && dateTo ? (
                    <Button asChild variant="outline">
                        <a href={`/finance/journal/export?from=${dateFrom}&to=${dateTo}`}>
                            {t('glExport.button')}
                        </a>
                    </Button>
                ) : (
                    <span className="text-sm text-amber-700">{t('glExport.needPeriod')}</span>
                )}
            </div>

            <JournalTable rows={tableRows} empty={t('finance.emptyState')} baseCurrency={baseCurrency} exportHref={journalListExportHref(params)}
                          sort={params.sort} shown={tableRows.length} total={total} totals={totals} />

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('finance.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('finance.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('finance.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('finance.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}

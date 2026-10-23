// app/operation/capture/inbox/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-1(2026-10-06,规格 §6.4;MES-1 Step 0 Q11 · Q12 · Q15,Tim)· 数据收件箱
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】网关收下的每一条消息落在这里(规格 §6.4 的落地表)。网关那一次匿名调用只收下(received);
//   转换在员工的会话里跑 —— 本页的 "Process received"(Q11)。一类还没有转换器的消息停在 awaiting_transform;
//   内容错的消息转换失败(failed + 错误码),看得见、能重试、能带理由丢弃,永远不删(Q15)。
// 【门】requireFunction(FN.captureInbox) = module.processing.view;重试 / 丢弃要 action.manage_devices。
// 【筛】?status=<状态>;默认全部。【翻页】?page=,一页 200 行,最新的在前(TABLE-EXPORT-2b-2,Tim TABLE-EXPORT-2 Q2:从前只读最新 200 行而一字不说)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { formatAuditStamp } from '@/lib/dates'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { Button } from '@/app/components/ui/button'
import { INBOX_PAGE_SIZE, INBOX_STATUSES, inboxCount, inboxExports, inboxLabels, inboxPage, inboxStatus } from './inboxRows'
import { ProcessReceivedButton, RowActions } from './InboxControls'

// 固定 en-US 的千分位,与 RowCapNotice 同一个写法(2,005 而不是 2005)
const COUNT = new Intl.NumberFormat('en-US')

export default async function InboxPage({ searchParams }: { searchParams: Promise<{ status?: string; page?: string }> }) {
    const denied = await requireFunction(FN.captureInbox)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const canManage = await can('action.manage_devices')
    const sp = await searchParams
    const status = inboxStatus(sp.status)

    // 1) 匹配总数(同一条筛选)—— 数不出来的总数不是 0;2) 只取这一页的行
    const total = mustCount(await inboxCount(supabase, status), 'ingest_inbox count')
    const totalPages = Math.max(1, Math.ceil(total / INBOX_PAGE_SIZE))
    const page = Math.min(Math.max(1, Math.floor(Number(sp.page) || 1)), totalPages)
    const from = (page - 1) * INBOX_PAGE_SIZE
    const [rowsRes, labels, receivedRes] = await Promise.all([
        inboxPage(supabase, status, from, from + INBOX_PAGE_SIZE - 1),
        inboxLabels(supabase, locale),
        supabase.from('ingest_inbox').select('id', { count: 'exact', head: true }).eq('status', 'received'),
    ])
    const rows = mustRows(rowsRes, 'ingest_inbox')
    const { devices, classes } = labels
    const received = mustCount(receivedRes, 'ingest_inbox received')
    const pageHref = (p: number) => {
        const q = new URLSearchParams()
        if (status) q.set('status', status)
        if (p > 1) q.set('page', String(p))
        const qs = q.toString()
        return qs ? `/operation/capture/inbox?${qs}` : '/operation/capture/inbox'
    }

    const tableRows: CellRow[] = rows.map((r) => {
        const label = `#${r.id}${r.stream ? ` · ${r.stream} · ${r.seq}` : ''}`
        return {
            id: String(r.id),
            cells: {
                id: <span className="font-mono">#{r.id}</span>,
                at: <>{formatAuditStamp(r.received_at)}{r.clock_ahead && <span className="ml-1 text-xs text-amber-700">{t('inbox.clockAhead')}</span>}</>,
                device: r.device_id && devices.get(r.device_id)
                    ? <Link href={`/operation/devices/${r.device_id}`} className="app-link hover:underline">{devices.get(r.device_id)}</Link>
                    : t('inbox.manual'),
                dataClass: classes.get(r.data_class) ?? r.data_class,
                seq: r.stream ? `${r.stream} · ${r.seq}` : '—',
                status: (
                    <span data-inbox-status={r.status}>
                        {t('inbox.status.' + r.status)}
                        {r.error_code && <span className="block text-xs text-red-700"><code>{r.error_code}</code></span>}
                        {r.discard_reason && <span className="block text-xs text-[color:var(--brand-muted-text)]">{r.discard_reason}</span>}
                        {r.attempts > 1 && <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('inbox.attempts', { n: String(r.attempts) })}</span>}
                    </span>
                ),
                payload: (
                    <details>
                        <summary className="cursor-pointer text-xs text-[color:var(--brand-muted-text)]">{t('inbox.showPayload')}</summary>
                        <pre className="mt-1 max-w-md overflow-x-auto whitespace-pre-wrap break-all text-xs">{JSON.stringify(r.payload, null, 2)}</pre>
                        {r.transform_result != null && (
                            <pre className="mt-1 max-w-md overflow-x-auto whitespace-pre-wrap break-all text-xs">{JSON.stringify(r.transform_result, null, 2)}</pre>
                        )}
                    </details>
                ),
                actions: r.status === 'failed' || r.status === 'awaiting_transform'
                    ? <RowActions id={r.id} label={label} canManage={canManage} />
                    : null,
            },
            exports: inboxExports(r, labels, t),
        }
    })

    const filterLink = (s: string | null) => (
        <Link key={s ?? 'all'} href={s ? `/operation/capture/inbox?status=${s}` : '/operation/capture/inbox'}
              className={`app-link hover:underline ${status === s ? 'font-semibold' : ''}`}>
            {s ? t('inbox.status.' + s) : t('inbox.all')}
        </Link>
    )

    return (
        <ListPage
            breadcrumb={<Link href="/operation/devices" className="app-link hover:underline text-sm">← {t('devices.title')}</Link>}
            title={t('inbox.title')}
            intro={t('inbox.intro')}
            maxWidth="max-w-6xl"
            actions={<ProcessReceivedButton received={received} />}
            state={{ kind: 'ok' }}
        >
            <nav className="mb-4 flex flex-wrap gap-x-4 gap-y-1 text-sm" aria-label={t('inbox.filter')}>
                {filterLink(null)}
                {INBOX_STATUSES.map((s) => filterLink(s))}
            </nav>
            <CellsTable
                columns={[
                    { key: 'id', header: t('inbox.colId'), priority: true },
                    { key: 'status', header: t('inbox.colStatus'), priority: true },
                    { key: 'at', header: t('inbox.colReceived') },
                    { key: 'device', header: t('inbox.colDevice') },
                    { key: 'dataClass', header: t('inbox.colClass') },
                    { key: 'seq', header: t('inbox.colStreamSeq') },
                    { key: 'payload', header: t('inbox.colPayload') },
                    { key: 'actions', header: '', priority: true, control: true },
                ]}
                rows={tableRows}
                empty={t('inbox.empty')}
                exportSpec={{ name: 'operation-capture-inbox', title: t('inbox.title'),
                              serverRows: `/operation/capture/inbox/export${status ? `?status=${status}` : ''}` }}
            />
            <div className="mt-4 flex items-center justify-between gap-2" data-inbox-pager="">
                {page > 1 ? (
                    <Button asChild variant="outline"><Link href={pageHref(page - 1)}>{t('inbox.pagination.prev')}</Link></Button>
                ) : (
                    <Button variant="outline" disabled>{t('inbox.pagination.prev')}</Button>
                )}
                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('inbox.pagination.pageOf', { current: page, total: totalPages, count: COUNT.format(total) })}
                </span>
                {page < totalPages ? (
                    <Button asChild variant="outline"><Link href={pageHref(page + 1)}>{t('inbox.pagination.next')}</Link></Button>
                ) : (
                    <Button variant="outline" disabled>{t('inbox.pagination.next')}</Button>
                )}
            </div>
        </ListPage>
    )
}

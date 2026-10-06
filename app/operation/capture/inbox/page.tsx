// app/operation/capture/inbox/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-1(2026-10-06,规格 §6.4;MES-1 Step 0 Q11 · Q12 · Q15,Tim)· 数据收件箱
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】网关收下的每一条消息落在这里(规格 §6.4 的落地表)。网关那一次匿名调用只收下(received);
//   转换在员工的会话里跑 —— 本页的 "Process received"(Q11)。一类还没有转换器的消息停在 awaiting_transform;
//   内容错的消息转换失败(failed + 错误码),看得见、能重试、能带理由丢弃,永远不删(Q15)。
// 【门】requireFunction(FN.captureInbox) = module.processing.view;重试 / 丢弃要 action.manage_devices。
// 【筛】?status=<状态>;默认全部,最新的 200 行。
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
import { ProcessReceivedButton, RowActions } from './InboxControls'

const INBOX_STATUSES = ['received', 'failed', 'awaiting_transform', 'transformed', 'discarded'] as const

type Row = {
    id: number; received_at: string; source: string; device_id: string | null; data_class: string; stream: string | null
    seq: number | null; status: string; error_code: string | null; attempts: number; payload: unknown
    transform_result: unknown; discard_reason: string | null; clock_ahead: boolean
}

export default async function InboxPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
    const denied = await requireFunction(FN.captureInbox)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const canManage = await can('action.manage_devices')
    const sp = await searchParams
    const status = (INBOX_STATUSES as readonly string[]).includes(sp.status ?? '') ? sp.status! : null

    let q = supabase.from('ingest_inbox')
        .select('id, received_at, source, device_id, data_class, stream, seq, status, error_code, attempts, payload, transform_result, discard_reason, clock_ahead')
        .order('id', { ascending: false }).limit(200)
    if (status) q = q.eq('status', status)
    const [rowsRes, devRes, classRes, receivedRes] = await Promise.all([
        q,
        supabase.from('devices').select('id, code'),
        supabase.from('ingest_data_classes').select('code, name_en, name_zh'),
        supabase.from('ingest_inbox').select('id', { count: 'exact', head: true }).eq('status', 'received'),
    ])
    const rows = mustRows(rowsRes, 'ingest_inbox') as Row[]
    const devices = new Map((mustRows(devRes, 'devices') as { id: string; code: string }[]).map((d) => [d.id, d.code]))
    const classes = new Map((mustRows(classRes, 'ingest_data_classes') as { code: string; name_en: string; name_zh: string }[])
        .map((c) => [c.code, locale === 'zh' ? c.name_zh : c.name_en]))
    const received = mustCount(receivedRes, 'ingest_inbox received')

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
                    { key: 'actions', header: '', priority: true },
                ]}
                rows={tableRows}
                empty={t('inbox.empty')}
            />
        </ListPage>
    )
}

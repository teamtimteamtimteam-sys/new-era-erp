// app/settings/change-history/page.tsx
// HISTORY-1(Tim 的 Q26 · Q13 · Q14 · Q15,2026-09-28):变更记录 —— 一张【读得到】的通用记录。
//
// 【为什么它必须和记录同一刀】一份没有人读得到的记录不是做完的活(Tim 的 Q26)。这一页是
//   data.view_change_log 的唯一入口:只授 admin 与 cfo,一条注册表条目、两个属主(设置 + 财务的报表组)。
// 【读法只有一支】change_log_rows()(SECURITY DEFINER,自己查码、自己遮蔽)。本页不判断谁能看什么 ——
//   遮住的值由库里换成 {"$restricted": true},这里只负责把它画成「受限」;本来就空的值留白。
//   ☞ 「受限」与「空」是两件事(lib/permissions.ts 抬头那一条),所以两者在屏幕上长得不一样。
// 【筛选】日期(from / to,含当天)· 表 · 记录(主键里任一值)· 谁(账号,或"无会话")。GET 表单,
//   与 /settings/deleted 同一个做法 —— 链接可以抄给别人。
// 【分页】最新的在前,每页 50(Tim 的 Q14);键集分页(?before=<seq>)—— 记录只增不改,
//   偏移分页会在翻页时因为新写入而错位。「较新」回到上一页的起点靠 ?after_first 太绕,
//   所以只给「最新」与「较早」两个方向:从头读,或者往更早翻。
// 【表名是技术名】Tim 的 Q15:238 张表的显示名是登记在案的后续一项。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { isYmd } from '@/lib/dateFilter'
import { ListPage } from '@/app/components/ui/list-page'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { DateFilterInput } from '@/app/components/ui/date-filter-input'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { formatAuditStamp } from '@/lib/dates'
import ChangeHistoryTable, { type ChangeRow } from './ChangeHistoryTable'
import { FieldValue, rowKeyLabel } from './fieldValue'

const PAGE_SIZE = 50
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type LogRow = {
    seq: number
    occurred_at: string
    table_name: string
    row_key: Record<string, unknown> | null
    op: string
    actor_account: string | null
    actor_email: string | null
    actor_employee: string | null
    actor_employee_code: string | null
    actor_employee_name: string | null
    actor_kind: string
    db_role: string
    changed_columns: string[] | null
    old: Record<string, unknown> | null
    new: Record<string, unknown> | null
    redacted_at: string | null
    row_restricted: boolean
}

type Filters = {
    tables: string[]
    actors: { account: string; email: string | null; employee_code: string | null; employee_name: string | null }[]
}

export default async function ChangeHistoryPage({
    searchParams,
}: {
    searchParams: Promise<{ from?: string; to?: string; table?: string; record?: string; actor?: string; before?: string }>
}) {
    const denied = await requireFunction(FN.changeHistory)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    // 【失败必须失败】两支 RPC 都用 mustOne / mustRows —— 读不出来不许画成"没有改动"。
    const filters = (mustOne(await supabase.rpc('change_log_filters'), 'change_log_filters') ?? {
        tables: [],
        actors: [],
    }) as unknown as Filters

    const from = isYmd(sp.from ?? '') ? (sp.from as string) : ''
    const to = isYmd(sp.to ?? '') ? (sp.to as string) : ''
    const table = filters.tables.includes(sp.table ?? '') ? (sp.table as string) : ''
    const record = (sp.record ?? '').trim().slice(0, 200)
    const actor = sp.actor === 'none' ? 'none' : UUID.test(sp.actor ?? '') ? (sp.actor as string) : ''
    const before = /^\d{1,18}$/.test(sp.before ?? '') ? (sp.before as string) : ''

    const res = await supabase.rpc('change_log_rows', {
        p_from: from || undefined,
        p_to: to || undefined,
        p_table: table || undefined,
        p_record: record || undefined,
        p_actor: actor && actor !== 'none' ? actor : undefined,
        p_no_session: actor === 'none',
        p_before: before ? Number(before) : undefined,
        p_limit: PAGE_SIZE + 1,
    })
    const all = mustRows(res, 'change_log_rows') as unknown as LogRow[]
    const hasOlder = all.length > PAGE_SIZE
    const rows = all.slice(0, PAGE_SIZE)

    function href(next: Partial<Record<'from' | 'to' | 'table' | 'record' | 'actor' | 'before', string>>) {
        const p = new URLSearchParams()
        const v = { from, to, table, record, actor, before: '', ...next }
        for (const [k, val] of Object.entries(v)) if (val) p.set(k, val)
        const s = p.toString()
        return s ? `/settings/change-history?${s}` : '/settings/change-history'
    }

    const tableRows: ChangeRow[] = rows.map((r) => {
        const opLabel = t('changeHistory.op.' + r.op)
        const who =
            r.actor_kind === 'no_session' ? (
                <span className="text-gray-600">{t('changeHistory.noSession', { role: r.db_role })}</span>
            ) : (
                <span>
                    <span className="block break-all">{r.actor_email ?? t('changeHistory.unknownAccount')}</span>
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">
                        {r.actor_employee_code
                            ? `${r.actor_employee_code} — ${r.actor_employee_name ?? ''}`
                            : t('changeHistory.noEmployee')}
                    </span>
                </span>
            )

        let fields: React.ReactNode
        if (r.op === 'TRUNCATE') {
            fields = <span className="text-gray-600">{t('changeHistory.truncated')}</span>
        } else if (r.op === 'UPDATE') {
            const cols = r.changed_columns ?? []
            fields = (
                <ul className="space-y-0.5">
                    {cols.map((c) => (
                        <li key={c} className="break-words">
                            <span className="font-mono text-xs text-[color:var(--brand-muted-text)]">{c}</span>{' '}
                            <FieldValue value={r.old?.[c]} /> <span aria-hidden>→</span> <FieldValue value={r.new?.[c]} />
                        </li>
                    ))}
                </ul>
            )
        } else {
            const img = (r.op === 'DELETE' ? r.old : r.new) ?? {}
            const keys = Object.keys(img)
            fields = (
                <div>
                    <div className="text-xs text-[color:var(--brand-muted-text)] mb-0.5">
                        {r.op === 'DELETE' ? t('changeHistory.fullRowDeleted') : t('changeHistory.fullRowCreated')}
                    </div>
                    {keys.length === 0 ? (
                        <span className="text-gray-500">{t('changeHistory.noFields')}</span>
                    ) : (
                        <ul className="space-y-0.5">
                            {keys.map((k) => (
                                <li key={k} className="break-words">
                                    <span className="font-mono text-xs text-[color:var(--brand-muted-text)]">{k}</span>{' '}
                                    <FieldValue value={img[k]} />
                                </li>
                            ))}
                        </ul>
                    )}
                </div>
            )
        }

        return {
            key: String(r.seq),
            whenLabel: formatAuditStamp(r.occurred_at),
            whoCell: who,
            table: r.table_name,
            record: r.op === 'TRUNCATE' ? '—' : rowKeyLabel(r.row_key),
            opLabel,
            fieldsCell: (
                <>
                    {r.row_restricted && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">{t('changeHistory.rowRestricted')}</p>
                    )}
                    {r.redacted_at && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">
                            {t('changeHistory.redacted', { date: formatAuditStamp(r.redacted_at) })}
                        </p>
                    )}
                    {fields}
                </>
            ),
        }
    })

    const lastSeq = rows.length ? rows[rows.length - 1].seq : null

    return (
        <ListPage
            title={t('changeHistory.title')}
            intro={t('changeHistory.intro')}
            notices={
                <p className="text-sm text-[color:var(--brand-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-4 max-w-3xl">
                    {t('changeHistory.maskNote')}
                </p>
            }
            state={{ kind: 'ok' }}
        >
            {/* ── 筛选:日期 · 表 · 记录 · 谁 ─────────────────────────────── */}
            <form className="flex flex-wrap items-end gap-2 mb-4 text-sm" action="/settings/change-history">
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterFrom')}
                    <DateFilterInput name="from" defaultValue={from} />
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterTo')}
                    <DateFilterInput name="to" defaultValue={to} />
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterTable')}
                    <select name="table" defaultValue={table} className={CONTROL_SELECT}>
                        <option value="">{t('changeHistory.allTables')}</option>
                        {filters.tables.map((x) => (
                            <option key={x} value={x}>
                                {x}
                            </option>
                        ))}
                    </select>
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterRecord')}
                    <input
                        type="text"
                        name="record"
                        defaultValue={record}
                        placeholder={t('changeHistory.recordPlaceholder')}
                        className={CONTROL_INPUT}
                    />
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterActor')}
                    <select name="actor" defaultValue={actor} className={CONTROL_SELECT}>
                        <option value="">{t('changeHistory.allActors')}</option>
                        <option value="none">{t('changeHistory.noSessionActor')}</option>
                        {filters.actors.map((a) => (
                            <option key={a.account} value={a.account}>
                                {(a.email ?? a.account) + (a.employee_code ? ` — ${a.employee_code}` : '')}
                            </option>
                        ))}
                    </select>
                </label>
                <Button variant="secondary" type="submit">
                    {t('common.filter')}
                </Button>
                <Link href="/settings/change-history" className="px-2 py-1 hover:underline app-link">
                    {t('changeHistory.clear')}
                </Link>
            </form>

            <ChangeHistoryTable rows={tableRows} empty={t('changeHistory.empty')} />

            {/* ── 分页:最新 / 较早(键集,seq 倒序)──────────────────────────── */}
            <div className="flex flex-wrap items-center gap-3 mt-4 text-sm">
                <span className="text-[color:var(--brand-muted-text)]">{t('changeHistory.pageNote', { n: PAGE_SIZE })}</span>
                {before && (
                    <Link href={href({ before: '' })} className="hover:underline app-link">
                        {t('changeHistory.newest')}
                    </Link>
                )}
                {hasOlder && lastSeq !== null && (
                    <Link href={href({ before: String(lastSeq) })} className="hover:underline app-link">
                        {t('changeHistory.older')}
                    </Link>
                )}
            </div>
        </ListPage>
    )
}

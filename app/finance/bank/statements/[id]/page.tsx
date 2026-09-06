// app/finance/bank/statements/[id]/page.tsx
// 对账单详情:头部卡 + 导入提示横幅(?overlap= / ?dups=)+ 行表(金额右对齐、
// 负数标红、状态 pill、匹配到的分录链接、忽略理由)+ 页脚合计与 期初 + Σ = 期末 校验行。
// open → "开始对账"进工作台、可软删(坏导入丢弃);reconciled → 绿色横幅 + 重新打开。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatAmount, formatTimestamp } from '@/lib/format'
import DeleteStatementButton from './DeleteStatementButton'
import UnreconcileControl from './UnreconcileControl'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import StatementLinesTable, { type StatementLineRow } from './StatementLinesTable'
import { mustRows } from '@/lib/db-helpers'

type MatchRow = {
    statement_line_id: string
    journal_lines: {
        id: string
        journal_entries: { id: string; code: string } | null
    } | null
}

export default async function BankStatementDetailPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ overlap?: string; dups?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const { id } = await params
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: stmt, error } = await supabase
        .from('bank_statements')
        .select('id, code, bank_account_code, currency, period_start, period_end, opening_balance, closing_balance, file_name, status, reconciled_at, notes')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !stmt) {
        notFound()
    }

    const { data: lines } = await supabase
        .from('bank_statement_lines')
        .select('id, line_no, line_date, description, reference, amount, match_status, ignore_reason')
        .eq('statement_id', id)
        .order('line_no', { ascending: true })

    const rows = lines ?? []

    // ── BANK-REC:对账记录(冻结的那一份)+ 今天重算 ───────────────────────────
    // 【两个数字并排,谁也不替换谁】"我们当时是照着什么对上的"与"今天重算是多少"
    // 是两个问题。两者不一致【本身就是要给人看的信息】—— 与 GST 已申报的那一份
    // 同一条规矩。book_balance_now / book_balance_drift 由视图现算。
    //
    // 【视图的列在生成类型里【全是可空的】,而这里一次性收窄】
    // Postgres 表达不出"这个视图的这一列不会为空",于是 lib/database.types.ts
    // 把每一列都放宽成 nullable。底表上 reconciliation_id、三个余额、
    // reconciled_at 都是 NOT NULL(见 db/tables/bank_reconciliations.sql),
    // 所以收窄在这里做一次 —— **而不是在每个使用点上撒 `?? 0`**:
    // 那会把"读出来是空的"伪装成"这个数就是 0",正是 mustRows 那条规矩
    // (一次失败不是一个空集)要禁止的伪装。真正可空的只有 superseded_* 两列。
    type ReconRecord = {
        reconciliation_id: string
        currency: string
        bank_closing_balance: number
        book_balance: number
        difference: number
        reconciled_at: string
        superseded_at: string | null
        superseded_reason: string | null
        is_current: boolean
        book_balance_now: number
        book_balance_drift: number
        period_end: string
    }
    const recordsRes = await supabase
        .from('bank_reconciliation_record')
        .select('reconciliation_id, currency, bank_closing_balance, book_balance, difference, reconciled_at, superseded_at, superseded_reason, is_current, book_balance_now, book_balance_drift, period_end')
        .eq('statement_id', id)
        .order('reconciled_at', { ascending: false })
    const records = mustRows(recordsRes) as unknown as ReconRecord[]

    const varianceRes = records.length
        ? await supabase
              .from('bank_reconciliation_variance_items')
              .select('reconciliation_id, item_no, item_kind, amount, note')
              .in('reconciliation_id', records.map((r) => r.reconciliation_id))
              .order('item_no', { ascending: true })
        : { data: [], error: null }
    const varianceItems = mustRows(varianceRes)

    const itemsByRecon = new Map<string, typeof varianceItems>()
    for (const v of varianceItems) {
        const list = itemsByRecon.get(v.reconciliation_id) ?? []
        list.push(v)
        itemsByRecon.set(v.reconciliation_id, list)
    }

    const currentRecord = records.find((r) => r.is_current) ?? null
    const supersededRecords = records.filter((r) => !r.is_current)

    // 已匹配行配到的分录(页级一次 .in),供"匹配到"列展示链接
    const matchedLineIds = rows.filter((r) => r.match_status === 'matched').map((r) => r.id)
    const { data: matchRows } = matchedLineIds.length
        ? await supabase
              .from('bank_line_matches')
              .select('statement_line_id, journal_lines(id, journal_entries(id, code))')
              .in('statement_line_id', matchedLineIds)
        : { data: [] as MatchRow[] }
    const matchesByLine = new Map<string, { entry_id: string; entry_code: string }[]>()
    for (const m of (matchRows as unknown as MatchRow[] | null) ?? []) {
        const entry = m.journal_lines?.journal_entries
        if (!entry) continue
        const list = matchesByLine.get(m.statement_line_id) ?? []
        list.push({ entry_id: entry.id, entry_code: entry.code })
        matchesByLine.set(m.statement_line_id, list)
    }

    const sum = Math.round(rows.reduce((s, r) => s + r.amount, 0) * 100) / 100
    const computed = Math.round((stmt.opening_balance + sum) * 100) / 100
    const balanced = Math.round((computed - stmt.closing_balance) * 100) === 0

    const overlap = Number(sp.overlap) || 0
    const dups = Number(sp.dups) || 0


    // ★【行数据在服务端压平】(CONV-1 §①)。分录链接跨两跳反查已在上面做完。
    const tableRows: StatementLineRow[] = rows.map((r) => ({
        id: r.id,
        lineNo: String(r.line_no),
        lineDate: r.line_date,
        description: r.description ?? '—',
        reference: r.reference ?? '—',
        amountText: formatAmount(r.amount, null),
        negative: r.amount < 0,
        matchStatus: r.match_status,
        matches: (matchesByLine.get(r.id) ?? []).map((m) => ({ entryId: m.entry_id, entryCode: m.entry_code })),
        ignoreReason: r.ignore_reason ?? '—',
    }))

    // ★ 合计行是【数据】,不是 <tfoot> —— CONV-4 §⑨-3 定的型,CONV-8 §⑧ 复核保留。
    //   转换前那个标签 colSpan={4} 顶到金额左边;现在落在【摘要】那一列。
    if (tableRows.length > 0) {
        tableRows.push({
            id: '__total__',
            lineNo: '',
            lineDate: '',
            description: `${t('bank.colLines')}: ${rows.length}`,
            reference: '',
            amountText: formatAmount(sum, null),
            negative: false,
            matchStatus: '',
            matches: [],
            ignoreReason: '',
            isTotal: true,
        })
    }

    return (
        <ListPage
            maxWidth="max-w-6xl"
            breadcrumb={
                <Link href="/finance/bank/statements" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            }
            title={t('bank.detailTitle')}
            // ★ 出口:对账工作台。转换前它画在 h1 右边 —— actions 槽是同一个位置,
            //   而且它画在状态分支【之前】,所以任何空态都吃不掉它。
            actions={
                stmt.status === 'open' ? (
                    <Button asChild>
                        <Link href={`/finance/bank/statements/${stmt.id}/reconcile`}>{t('bank.openWorkspace')}</Link>
                    </Button>
                ) : undefined
            }
            // ★★ 详情页恒为 ok —— 这张报表在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
            notices={
                <>
                    {/* 已对账横幅 + 重新打开 —— 「重新打开」是一个出口,所以这一块
                        必须无条件画,而 notices 正是画在状态分支之前的那个槽。 */}
                    {stmt.status === 'reconciled' && (
                        <div className="bg-green-50 border border-green-300 text-green-900 px-4 py-3 rounded mb-4 text-sm flex flex-wrap items-center gap-3">
                            <span>
                                {t('bank.reconciledBanner', {
                                    when: stmt.reconciled_at
                                        ? formatTimestamp(stmt.reconciled_at, dateLocale)
                                        : '—',
                                })}
                            </span>
                            <UnreconcileControl statementId={stmt.id} subject={stmt.code} />
                        </div>
                    )}

                    {/* ── BANK-REC:对账记录 —— 每月的银行余额 / 账面余额 / 差额 / 说明 ──
                        【事后读得到】,不是只在对账那一刻断言过一次。 */}
                    {/* 【具名的缺席,不是空白】没有对过账的报表要【说】它没有对过账,
                        而不是让这一块整个消失 —— 消失与"读不出来"在屏幕上长得一模一样。 */}
                    <div className="border border-gray-300 rounded p-4 mb-4">
                        <h2 className="font-semibold mb-3">{t('bank.record.title')}</h2>
                        {!currentRecord && <p className="text-sm text-gray-600">{t('bank.record.none')}</p>}
                        {currentRecord && (
                        <>
                            <p className="text-sm text-gray-700 mb-1">
                                {t('bank.record.frozenTitle', {
                                    when: formatTimestamp(currentRecord.reconciled_at, dateLocale),
                                })}
                            </p>
                            <div className="flex flex-wrap gap-x-8 gap-y-1 text-sm mb-3">
                                <span>
                                    <span className="text-gray-600 mr-1">{t('bank.balancePanel.bankClosing')}:</span>
                                    <span className="font-mono">
                                        {formatAmount(currentRecord.bank_closing_balance, currentRecord.currency)}
                                    </span>
                                </span>
                                <span>
                                    <span className="text-gray-600 mr-1">{t('bank.balancePanel.bookBalance')}:</span>
                                    <span className="font-mono">
                                        {formatAmount(currentRecord.book_balance, currentRecord.currency)}
                                    </span>
                                </span>
                                <span>
                                    <span className="text-gray-600 mr-1">{t('bank.balancePanel.difference')}:</span>
                                    <span className="font-mono font-semibold">
                                        {formatAmount(currentRecord.difference, currentRecord.currency)}
                                    </span>
                                </span>
                            </div>

                            {/* 今天重算 —— 与上面那一组【并排】,不替换它 */}
                            <div className="bg-gray-50 rounded p-3 mb-3">
                                <p className="text-sm text-gray-700 mb-1">{t('bank.record.recomputedTitle')}</p>
                                <div className="flex flex-wrap gap-x-8 gap-y-1 text-sm">
                                    <span>
                                        <span className="text-gray-600 mr-1">{t('bank.record.bookNow')}:</span>
                                        <span className="font-mono">
                                            {formatAmount(currentRecord.book_balance_now, currentRecord.currency)}
                                        </span>
                                    </span>
                                    {currentRecord.book_balance_drift === 0 ? (
                                        <span className="text-green-800">{t('bank.record.noDrift')}</span>
                                    ) : (
                                        <span className="text-amber-900 font-medium">
                                            {t('bank.record.drift', {
                                                amount: formatAmount(currentRecord.book_balance_drift, currentRecord.currency),
                                            })}
                                        </span>
                                    )}
                                </div>
                                {currentRecord.book_balance_drift !== 0 && (
                                    <p className="text-xs text-gray-600 mt-1">
                                        {t('bank.record.driftNote', { date: currentRecord.period_end })}
                                    </p>
                                )}
                            </div>

                            {/* 写明的差额 */}
                            <h3 className="text-sm font-semibold mb-1">{t('bank.record.explanation')}</h3>
                            {(itemsByRecon.get(currentRecord.reconciliation_id) ?? []).length === 0 ? (
                                <p className="text-sm text-gray-600">{t('bank.record.noItems')}</p>
                            ) : (
                                <ul className="text-sm space-y-1">
                                    {(itemsByRecon.get(currentRecord.reconciliation_id) ?? []).map((v) => (
                                        <li key={v.item_no} className="flex flex-wrap gap-x-3">
                                            <span className="font-mono w-32 text-right">
                                                {formatAmount(v.amount, currentRecord.currency)}
                                            </span>
                                            <span className="text-gray-700">{t('bank.varianceKind.' + v.item_kind)}</span>
                                            <span className="text-gray-600">— {v.note}</span>
                                        </li>
                                    ))}
                                </ul>
                            )}
                        </>
                        )}
                    </div>

                    {supersededRecords.length > 0 && (
                        <div className="border border-gray-200 rounded p-4 mb-4 text-sm">
                            <h2 className="font-semibold mb-1">{t('bank.record.history')}</h2>
                            <p className="text-xs text-gray-600 mb-2">{t('bank.record.supersededNote')}</p>
                            <ul className="space-y-2">
                                {supersededRecords.map((r) => (
                                    <li key={r.reconciliation_id}>
                                        <div className="flex flex-wrap gap-x-6">
                                            <span className="font-mono">
                                                {formatAmount(r.bank_closing_balance, r.currency)} /{' '}
                                                {formatAmount(r.book_balance, r.currency)} /{' '}
                                                {formatAmount(r.difference, r.currency)}
                                            </span>
                                            <span className="text-gray-600">
                                                {t('bank.record.superseded', {
                                                    when: r.superseded_at
                                                        ? formatTimestamp(r.superseded_at, dateLocale)
                                                        : '—',
                                                    reason: r.superseded_reason ?? '—',
                                                })}
                                            </span>
                                        </div>
                                    </li>
                                ))}
                            </ul>
                        </div>
                    )}

                    {/* 导入提示(信息,不是错误)*/}
                    {(overlap > 0 || dups > 0) && (
                        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm space-y-1">
                            {overlap > 0 && <p>{t('bank.warnOverlap', { n: overlap })}</p>}
                            {dups > 0 && <p>{t('bank.warnDuplicates', { n: dups })}</p>}
                        </div>
                    )}
                </>
            }
        >
            {/* ★ 记录抬头 —— 删除钮住 actions 槽(一个动作不是一个值)。 */}
            <RecordHeader
                fields={[
                    { label: t('bank.colCode'), value: stmt.code, mono: true },
                    {
                        label: t('bank.colAccount'),
                        value: (
                            <>
                                <span className="font-mono">{stmt.bank_account_code}</span>{' '}
                                {t('finance.bank.' + stmt.bank_account_code)}
                                <span className="text-gray-500 ml-2">{stmt.currency}</span>
                            </>
                        ),
                    },
                    { label: t('bank.colPeriod'), value: `${stmt.period_start} – ${stmt.period_end}` },
                    { label: t('bank.colOpening'), value: formatAmount(stmt.opening_balance, stmt.currency), mono: true },
                    {
                        label: t('bank.colClosing'),
                        value: <span className="font-medium">{formatAmount(stmt.closing_balance, stmt.currency)}</span>,
                        mono: true,
                    },
                    ...(stmt.file_name
                        ? [{ label: t('bank.fileName'), value: <span className="text-xs">{stmt.file_name}</span>, mono: true }]
                        : []),
                    {
                        label: t('finance.colStatus'),
                        value: (
                            <span
                                className={
                                    'px-2 py-1 rounded text-xs ' +
                                    (stmt.status === 'reconciled'
                                        ? 'bg-green-100 text-green-800'
                                        : 'bg-amber-100 text-amber-800')
                                }
                            >
                                {t('bank.status.' + stmt.status)}
                            </span>
                        ),
                    },
                    ...(stmt.reconciled_at
                        ? [{ label: t('bank.reconciledAt'), value: formatTimestamp(stmt.reconciled_at, dateLocale) }]
                        : []),
                ]}
                actions={stmt.status === 'open' ? <DeleteStatementButton statementId={stmt.id} subject={stmt.code} /> : undefined}
            />

            {stmt.notes && (
                <p className="text-sm text-gray-600 mb-4 whitespace-pre-line">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {stmt.notes}
                </p>
            )}

            <StatementLinesTable rows={tableRows} />

            {/* 期初 + Σ = 期末 校验行 */}
            <p className={'text-sm mt-3 ' + (balanced ? 'text-green-700' : 'text-red-600')}>
                {balanced
                    ? `✓ ${t('bank.balanceOk')}`
                    : `✗ ${t('bank.balanceMismatch', {
                          computed: formatAmount(computed, stmt.currency),
                          entered: formatAmount(stmt.closing_balance, stmt.currency),
                          delta: formatAmount(Math.round((computed - stmt.closing_balance) * 100) / 100, stmt.currency),
                      })}`}
            </p>
        </ListPage>
    )
}

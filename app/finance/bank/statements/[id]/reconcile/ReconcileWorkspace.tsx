'use client'

// 对账工作台:左边报表行(未匹配 → 已忽略 → 已匹配),右边所选行的候选分录。
// 候选按【方向】过滤:报表行为正(入账)只配借方分录,为负(出账)只配贷方分录 ——
// 这一步在客户端做,界面上用 directionNote 说明,DB 的 JL_WRONG_DIRECTION 是兜底。
// 支持多选:银行常把多笔付款合并成一行。Σ 选中必须精确等于目标金额才允许提交,
// DB 的 MATCH_AMOUNT_MISMATCH 仍是权威兜底。
import { useMemo, useState, useTransition } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import {
    matchLine,
    unmatchLine,
    ignoreLine,
    unignoreLine,
    completeReconciliation,
} from './actions'

export type StatementLine = {
    id: string
    line_no: number
    line_date: string
    description: string | null
    reference: string | null
    amount: number
    match_status: 'unmatched' | 'matched' | 'ignored'
    ignore_reason: string | null
    matches: { entry_id: string; entry_code: string; amount: number }[]
}

export type Candidate = {
    journal_line_id: string
    entry_id: string
    entry_code: string
    entry_date: string
    memo: string | null
    source_type: string | null
    amount_ccy: number
    direction: 'debit' | 'credit'
}

type Statement = {
    id: string
    code: string
    bank_account_code: string
    currency: string
    period_start: string
    period_end: string
    opening_balance: number
    closing_balance: number
}

// BANK-REC:银行 vs 账面的比较,由 preview_reconcile_statement 算,页面只显示。
export type BalanceComparison = {
    statement_id: string
    code: string
    currency: string
    as_of: string
    bank_closing_balance: number
    book_balance: number
    difference: number
    outstanding_lines: number
}

// 差额说明的六种类型。**顺序与取值来自
// bank_reconciliation_variance_items 的 CHECK 约束** —— 那张表是源头,
// check-i18n 也从同一处读 bank.varianceKind.* 的后缀集。
const VARIANCE_KINDS = [
    'unpresented_cheque',
    'deposit_in_transit',
    'bank_charge',
    'bank_interest',
    'timing',
    'error_to_correct',
] as const

type VarianceDraft = { id: number; kind: string; amount: string; note: string }

const round2 = (n: number) => Math.round(n * 100) / 100

export default function ReconcileWorkspace({
    statement,
    lines,
    candidates,
    comparison,
}: {
    statement: Statement
    lines: StatementLine[]
    candidates: Candidate[]
    comparison: BalanceComparison
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [selectedLineId, setSelectedLineId] = useState<string | null>(null)
    const [checked, setChecked] = useState<Record<string, boolean>>({})
    const [ignoringId, setIgnoringId] = useState<string | null>(null)
    const [ignoreReason, setIgnoreReason] = useState('')
    const [variance, setVariance] = useState<VarianceDraft[]>([])
    const [nextDraftId, setNextDraftId] = useState(1)

    const ccy = statement.currency

    const groups = useMemo(
        () => ({
            unmatched: lines.filter((l) => l.match_status === 'unmatched'),
            ignored: lines.filter((l) => l.match_status === 'ignored'),
            matched: lines.filter((l) => l.match_status === 'matched'),
        }),
        [lines]
    )
    const handled = groups.matched.length + groups.ignored.length
    const total = lines.length
    const allHandled = total > 0 && handled === total
    const progressPct = total ? Math.round((handled / total) * 100) : 0

    const selectedLine = lines.find((l) => l.id === selectedLineId && l.match_status === 'unmatched') ?? null
    const target = selectedLine ? round2(Math.abs(selectedLine.amount)) : 0

    // 方向过滤 + 按"金额接近目标"排序(精确命中排最前)
    const visibleCandidates = useMemo(() => {
        if (!selectedLine) return []
        const want = selectedLine.amount > 0 ? 'debit' : 'credit'
        return candidates
            .filter((c) => c.direction === want)
            .slice()
            .sort((a, b) => {
                const da = Math.abs(a.amount_ccy - target)
                const db = Math.abs(b.amount_ccy - target)
                if (da !== db) return da - db
                return a.entry_date.localeCompare(b.entry_date)
            })
    }, [candidates, selectedLine, target])

    const selectedTotal = round2(
        visibleCandidates
            .filter((c) => checked[c.journal_line_id])
            .reduce((s, c) => s + c.amount_ccy, 0)
    )
    const selectedIds = visibleCandidates
        .filter((c) => checked[c.journal_line_id])
        .map((c) => c.journal_line_id)
    const amountsAgree = selectedIds.length > 0 && Math.round((selectedTotal - target) * 100) === 0

    function selectLine(line: StatementLine) {
        if (line.match_status !== 'unmatched') return
        setSelectedLineId(line.id)
        setChecked({})
        setIgnoringId(null)
        setIgnoreReason('')
        setError(null)
    }

    function run(fn: () => Promise<{ error?: string } | void>) {
        startTransition(async () => {
            const result = await fn()
            if (result && 'error' in result && result.error) {
                setError(result.error)
            } else {
                setError(null)
                setChecked({})
                setSelectedLineId(null)
                setIgnoringId(null)
                setIgnoreReason('')
            }
        })
    }

    // ── BANK-REC:差额与它的说明 ──────────────────────────────────────────────
    // 【这三个数字一直显示,差额为 0 时也显示】一个只在出事时才出现的面板,
    // 会教人把"它没出现"读成"没查过"。0.00 是一个值得看见的事实。
    const difference = round2(comparison.difference)
    const explained = round2(
        variance.reduce((sum, v) => {
            const n = Number(v.amount)
            return sum + (Number.isFinite(n) ? n : 0)
        }, 0)
    )
    const unexplained = round2(difference - explained)

    function addVarianceItem() {
        setVariance((v) => [...v, { id: nextDraftId, kind: VARIANCE_KINDS[0], amount: '', note: '' }])
        setNextDraftId((n) => n + 1)
    }

    function updateVarianceItem(id: number, patch: Partial<VarianceDraft>) {
        setVariance((v) => v.map((item) => (item.id === id ? { ...item, ...patch } : item)))
    }

    function removeVarianceItem(id: number) {
        setVariance((v) => v.filter((item) => item.id !== id))
    }

    function handleComplete() {
        if (!window.confirm(t('bank.reconcileConfirm', { code: statement.code }))) return
        // 【按钮不因差额而变灰】灰掉的按钮等于把规则在页面上再实现一遍,
        // 而两份实现会漂开;何况一个没有相邻理由的死控件,人会靠猜去绕。
        // 服务端始终是权威 —— 这里只把人填的东西原样递过去。
        run(() =>
            completeReconciliation(
                statement.id,
                variance.map((v) => ({ kind: v.kind, amount: v.amount.trim(), note: v.note }))
            )
        )
    }

    const lineRowClass = (line: StatementLine) =>
        'border border-gray-300 px-3 py-2 ' +
        (line.id === selectedLineId ? 'bg-blue-50' : '') +
        (line.match_status === 'unmatched' ? ' cursor-pointer hover:bg-blue-50' : '')

    const statusPill = (status: StatementLine['match_status']) => (
        <span
            className={
                'px-2 py-0.5 rounded text-xs ' +
                (status === 'matched'
                    ? 'bg-green-100 text-green-800'
                    : status === 'ignored'
                      ? 'bg-gray-200 text-gray-600'
                      : 'bg-amber-100 text-amber-800')
            }
        >
            {t('bank.lineStatus.' + status)}
        </span>
    )

    // 一组报表行(未匹配 / 已忽略 / 已匹配 各一段)
    const renderGroup = (
        titleKey: string,
        rows: StatementLine[],
        opts: { selectable?: boolean } = {}
    ) =>
        rows.length > 0 && (
            <div className="mb-5">
                <h3 className="text-sm font-semibold text-gray-600 mb-2">
                    {t(titleKey)} ({rows.length})
                </h3>
                <div className="border border-gray-300 rounded divide-y">
                    {rows.map((line) => (
                        <div
                            key={line.id}
                            onClick={() => opts.selectable && selectLine(line)}
                            className={
                                'px-3 py-2 text-sm ' +
                                (line.id === selectedLineId ? 'bg-blue-50 ' : '') +
                                (opts.selectable ? 'cursor-pointer hover:bg-blue-50' : '')
                            }
                        >
                            <div className="flex items-center gap-3">
                                <span className="text-gray-400 w-8 shrink-0">{line.line_no}</span>
                                <span className="w-24 shrink-0">{line.line_date}</span>
                                <span className="flex-1 min-w-0 truncate">{line.description ?? '—'}</span>
                                <span className="w-24 shrink-0 font-mono text-xs text-gray-500 truncate">
                                    {line.reference ?? ''}
                                </span>
                                <span
                                    className={
                                        'w-28 shrink-0 text-right font-mono ' +
                                        (line.amount < 0 ? 'text-red-600' : '')
                                    }
                                >
                                    {formatAmount(line.amount, null)}
                                </span>
                                <span className="w-20 shrink-0 text-right">{statusPill(line.match_status)}</span>
                            </div>

                            {/* 已匹配:显示配到的分录 + 取消匹配 */}
                            {line.match_status === 'matched' && (
                                <div className="mt-1 pl-11 flex flex-wrap items-center gap-2 text-xs text-gray-600">
                                    <span>{t('bank.colMatchedTo')}:</span>
                                    {line.matches.map((m) => (
                                        <Link
                                            key={m.entry_id}
                                            href={`/finance/journal/${m.entry_id}`}
                                            className="text-blue-600 hover:underline font-mono"
                                        >
                                            {m.entry_code}
                                        </Link>
                                    ))}
                                    <button
                                        type="button"
                                        disabled={isPending}
                                        onClick={() => run(() => unmatchLine(statement.id, line.id))}
                                        className="text-red-600 hover:underline disabled:text-gray-400"
                                    >
                                        {t('bank.unmatch')}
                                    </button>
                                </div>
                            )}

                            {/* 已忽略:显示理由 + 恢复 */}
                            {line.match_status === 'ignored' && (
                                <div className="mt-1 pl-11 flex flex-wrap items-center gap-2 text-xs text-gray-600">
                                    <span>
                                        {t('bank.ignoreReason')}: {line.ignore_reason ?? '—'}
                                    </span>
                                    <button
                                        type="button"
                                        disabled={isPending}
                                        onClick={() => run(() => unignoreLine(statement.id, line.id))}
                                        className="text-blue-600 hover:underline disabled:text-gray-400"
                                    >
                                        {t('bank.unignore')}
                                    </button>
                                </div>
                            )}
                        </div>
                    ))}
                </div>
            </div>
        )

    return (
        <div>
            {/* 头部:报表信息 + 进度 */}
            <div className="bg-gray-50 rounded p-4 mb-4">
                <div className="flex flex-wrap gap-x-8 gap-y-2 text-sm items-center mb-3">
                    <Link
                        href={`/finance/bank/statements/${statement.id}`}
                        className="text-blue-600 hover:underline font-mono font-medium"
                    >
                        {statement.code}
                    </Link>
                    <span>
                        <span className="font-mono">{statement.bank_account_code}</span>{' '}
                        {t('finance.bank.' + statement.bank_account_code)}
                        <span className="text-gray-500 ml-2">{ccy}</span>
                    </span>
                    <span>
                        {statement.period_start} – {statement.period_end}
                    </span>
                    <span>
                        <span className="text-gray-600 mr-1">{t('bank.colOpening')}:</span>
                        <span className="font-mono">{formatAmount(statement.opening_balance, ccy)}</span>
                    </span>
                    <span>
                        <span className="text-gray-600 mr-1">{t('bank.colClosing')}:</span>
                        <span className="font-mono font-medium">{formatAmount(statement.closing_balance, ccy)}</span>
                    </span>
                </div>
                <div className="flex items-center gap-3">
                    <div className="flex-1 h-2 bg-gray-200 rounded overflow-hidden">
                        <div
                            className={'h-full ' + (allHandled ? 'bg-green-500' : 'bg-blue-500')}
                            style={{ width: `${progressPct}%` }}
                        />
                    </div>
                    <span className="text-sm text-gray-600 whitespace-nowrap">
                        {t('bank.progress', { handled, total })}
                    </span>
                </div>
            </div>

            {/* BANK-REC:银行 vs 账面 —— 【在按下按钮之前】就看得见,不是被拒之后才知道 */}
            <div
                className={
                    'rounded p-4 mb-4 border ' +
                    (difference === 0
                        ? 'bg-green-50 border-green-300'
                        : 'bg-amber-50 border-amber-300')
                }
            >
                <div className="flex flex-wrap items-baseline gap-x-3 mb-2">
                    <h2 className="font-semibold">{t('bank.balancePanel.title')}</h2>
                    <span className="text-xs text-gray-600">
                        {t('bank.balancePanel.asOf', { date: statement.period_end })}
                    </span>
                </div>
                <div className="flex flex-wrap gap-x-8 gap-y-1 text-sm mb-2">
                    <span>
                        <span className="text-gray-600 mr-1">{t('bank.balancePanel.bankClosing')}:</span>
                        <span className="font-mono">{formatAmount(comparison.bank_closing_balance, ccy)}</span>
                    </span>
                    <span>
                        <span className="text-gray-600 mr-1">{t('bank.balancePanel.bookBalance')}:</span>
                        <span className="font-mono">{formatAmount(comparison.book_balance, ccy)}</span>
                    </span>
                    <span>
                        <span className="text-gray-600 mr-1">{t('bank.balancePanel.difference')}:</span>
                        <span
                            className={
                                'font-mono font-semibold ' +
                                (difference === 0 ? 'text-green-800' : 'text-amber-900')
                            }
                        >
                            {formatAmount(difference, ccy)}
                        </span>
                    </span>
                </div>

                {difference === 0 ? (
                    <p className="text-sm text-green-800">{t('bank.balancePanel.agrees')}</p>
                ) : (
                    <div>
                        <p className="text-sm text-amber-900 mb-3">{t('bank.balancePanel.disagrees')}</p>

                        <h3 className="text-sm font-semibold mb-1">{t('bank.balancePanel.explainTitle')}</h3>
                        <p className="text-xs text-gray-600 mb-2">{t('bank.balancePanel.explainHint')}</p>

                        {variance.map((item) => (
                            <div key={item.id} className="flex flex-wrap items-center gap-2 mb-2">
                                <select
                                    value={item.kind}
                                    onChange={(e) => updateVarianceItem(item.id, { kind: e.target.value })}
                                    className="border border-gray-300 rounded px-2 py-1 text-sm"
                                    aria-label={t('bank.balancePanel.kind')}
                                >
                                    {VARIANCE_KINDS.map((k) => (
                                        <option key={k} value={k}>
                                            {t('bank.varianceKind.' + k)}
                                        </option>
                                    ))}
                                </select>
                                <input
                                    type="text"
                                    inputMode="decimal"
                                    value={item.amount}
                                    onChange={(e) => updateVarianceItem(item.id, { amount: e.target.value })}
                                    placeholder={t('bank.balancePanel.amount')}
                                    aria-label={t('bank.balancePanel.amount')}
                                    className="border border-gray-300 rounded px-2 py-1 text-sm font-mono w-32"
                                />
                                <input
                                    type="text"
                                    value={item.note}
                                    onChange={(e) => updateVarianceItem(item.id, { note: e.target.value })}
                                    placeholder={t('bank.balancePanel.notePlaceholder')}
                                    aria-label={t('bank.balancePanel.note')}
                                    className="border border-gray-300 rounded px-2 py-1 text-sm flex-1 min-w-[16rem]"
                                />
                                <button
                                    type="button"
                                    onClick={() => removeVarianceItem(item.id)}
                                    className="text-sm text-red-700 hover:underline"
                                >
                                    {t('bank.balancePanel.removeItem')}
                                </button>
                            </div>
                        ))}

                        <div className="flex flex-wrap items-center gap-4 mt-2">
                            <button
                                type="button"
                                onClick={addVarianceItem}
                                className="bg-white border border-gray-400 px-3 py-1 rounded text-sm hover:bg-gray-100"
                            >
                                {t('bank.balancePanel.addItem')}
                            </button>
                            <span className="text-sm">
                                <span className="text-gray-600 mr-1">{t('bank.balancePanel.explained')}:</span>
                                <span className="font-mono">{formatAmount(explained, ccy)}</span>
                            </span>
                            {unexplained === 0 ? (
                                <span className="text-sm text-green-800">{t('bank.balancePanel.balanced')}</span>
                            ) : (
                                <span className="text-sm text-amber-900">
                                    <span className="mr-1">{t('bank.balancePanel.unexplained')}:</span>
                                    <span className="font-mono font-semibold">{formatAmount(unexplained, ccy)}</span>
                                </span>
                            )}
                        </div>
                    </div>
                )}
            </div>

            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {error}
                </div>
            )}

            <div className="grid gap-6 lg:grid-cols-2">
                {/* 左:报表行 */}
                <div>
                    {renderGroup('bank.groupUnmatched', groups.unmatched, { selectable: true })}
                    {renderGroup('bank.groupIgnored', groups.ignored)}
                    {renderGroup('bank.groupMatched', groups.matched)}
                </div>

                {/* 右:候选分录 */}
                <div>
                    {!selectedLine ? (
                        <p className="text-sm text-gray-500 border border-dashed border-gray-300 rounded p-6 text-center">
                            {allHandled ? t('bank.allHandled') : t('bank.noSelection')}
                        </p>
                    ) : (
                        <div className="border border-gray-300 rounded p-4">
                            <h3 className="font-semibold mb-1">
                                {t('bank.candidatesFor', { code: selectedLine.line_no })}
                            </h3>
                            <p className="text-sm text-gray-600 mb-1">
                                {selectedLine.description ?? '—'} ·{' '}
                                <span
                                    className={
                                        'font-mono ' + (selectedLine.amount < 0 ? 'text-red-600' : '')
                                    }
                                >
                                    {formatAmount(selectedLine.amount, ccy)}
                                </span>
                            </p>
                            <p className="text-xs text-gray-500 mb-3">{t('bank.directionNote')}</p>

                            {visibleCandidates.length === 0 ? (
                                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded text-sm">
                                    <p className="mb-2">{t('bank.noCandidates')}</p>
                                    <div className="flex flex-wrap gap-3">
                                        <a
                                            href="/finance/expenses/new"
                                            target="_blank"
                                            rel="noopener noreferrer"
                                            className="text-blue-600 hover:underline"
                                        >
                                            {t('expense.new')}
                                        </a>
                                        <a
                                            href="/finance/payments/new"
                                            target="_blank"
                                            rel="noopener noreferrer"
                                            className="text-blue-600 hover:underline"
                                        >
                                            {t('finance.recordPayment')}
                                        </a>
                                        <a
                                            href="/finance/journal/new"
                                            target="_blank"
                                            rel="noopener noreferrer"
                                            className="text-blue-600 hover:underline"
                                        >
                                            {t('finance.subnav.newEntry')}
                                        </a>
                                    </div>
                                </div>
                            ) : (
                                <div className="border border-gray-200 rounded divide-y max-h-[28rem] overflow-y-auto">
                                    {visibleCandidates.map((c) => {
                                        const exact = Math.round((c.amount_ccy - target) * 100) === 0
                                        return (
                                            <label
                                                key={c.journal_line_id}
                                                className="flex items-center gap-3 px-3 py-2 text-sm cursor-pointer hover:bg-gray-50"
                                            >
                                                <input
                                                    type="checkbox"
                                                    checked={!!checked[c.journal_line_id]}
                                                    onChange={(e) =>
                                                        setChecked((prev) => ({
                                                            ...prev,
                                                            [c.journal_line_id]: e.target.checked,
                                                        }))
                                                    }
                                                />
                                                <Link
                                                    href={`/finance/journal/${c.entry_id}`}
                                                    target="_blank"
                                                    className="text-blue-600 hover:underline font-mono w-28 shrink-0"
                                                    onClick={(e) => e.stopPropagation()}
                                                >
                                                    {c.entry_code}
                                                </Link>
                                                <span className="w-24 shrink-0">{c.entry_date}</span>
                                                <span className="flex-1 min-w-0 truncate">{c.memo ?? '—'}</span>
                                                <span className="w-24 shrink-0 text-xs text-gray-500">
                                                    {c.source_type ? t('finance.source.' + c.source_type) : '—'}
                                                </span>
                                                <span className="w-24 shrink-0 text-right font-mono">
                                                    {formatAmount(c.amount_ccy, null)}
                                                </span>
                                                <span className="w-16 shrink-0 text-right">
                                                    {exact && (
                                                        <span className="px-2 py-0.5 rounded text-xs bg-green-100 text-green-800">
                                                            {t('bank.exactMatch')}
                                                        </span>
                                                    )}
                                                </span>
                                            </label>
                                        )
                                    })}
                                </div>
                            )}

                            {/* 选中合计 vs 目标金额 */}
                            <div className="mt-3 text-sm">
                                <span className={amountsAgree ? 'text-green-700' : 'text-gray-600'}>
                                    {amountsAgree && '✓ '}
                                    {t('bank.selectedTotal', {
                                        selected: formatAmount(selectedTotal, null),
                                        target: formatAmount(target, null),
                                    })}
                                </span>
                                {selectedIds.length > 0 && !amountsAgree && (
                                    <span className="text-red-600 ml-2 font-mono">
                                        ({formatAmount(round2(selectedTotal - target), null)})
                                    </span>
                                )}
                            </div>

                            <div className="flex flex-wrap items-center gap-3 mt-3">
                                <button
                                    type="button"
                                    disabled={!amountsAgree || isPending}
                                    onClick={() =>
                                        run(() => matchLine(statement.id, selectedLine.id, selectedIds))
                                    }
                                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                                >
                                    {t('bank.match')}
                                </button>
                                <button
                                    type="button"
                                    disabled={isPending}
                                    onClick={() => setIgnoringId(selectedLine.id)}
                                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                                >
                                    {t('bank.ignore')}
                                </button>
                            </div>

                            {/* 忽略:内联理由输入(DB 要求必填)*/}
                            {ignoringId === selectedLine.id && (
                                <div className="mt-3 border-t pt-3">
                                    <p className="text-xs text-gray-500 mb-2">{t('bank.ignoreHint')}</p>
                                    <div className="flex flex-wrap gap-2">
                                        <input
                                            type="text"
                                            value={ignoreReason}
                                            onChange={(e) => setIgnoreReason(e.target.value)}
                                            placeholder={t('bank.ignoreReasonPlaceholder')}
                                            className="flex-1 min-w-[14rem] border border-gray-300 px-3 py-2 rounded text-sm"
                                        />
                                        <button
                                            type="button"
                                            disabled={!ignoreReason.trim() || isPending}
                                            onClick={() =>
                                                run(() =>
                                                    ignoreLine(statement.id, selectedLine.id, ignoreReason.trim())
                                                )
                                            }
                                            className="bg-gray-700 text-white px-4 py-2 rounded hover:bg-gray-800 disabled:bg-gray-400"
                                        >
                                            {t('bank.ignore')}
                                        </button>
                                    </div>
                                </div>
                            )}
                        </div>
                    )}
                </div>
            </div>

            {/* 底栏:完成对账(全部行处理完才可用)*/}
            <div className="mt-6 border-t pt-4 flex flex-wrap items-center gap-4">
                <button
                    type="button"
                    disabled={!allHandled || isPending}
                    onClick={handleComplete}
                    className="bg-green-600 text-white px-4 py-2 rounded hover:bg-green-700 disabled:bg-gray-400"
                >
                    {t('bank.reconcileButton')}
                </button>
                {!allHandled && (
                    <span className="text-sm text-gray-600">
                        {t('bank.outstandingCount', { n: groups.unmatched.length })}
                    </span>
                )}
                {allHandled && <span className="text-sm text-green-700">{t('bank.allHandled')}</span>}
            </div>
        </div>
    )
}

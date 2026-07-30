// app/finance/bank/statements/[id]/reconcile/page.tsx
// 对账工作台(服务端壳):取报表 + 全部行 + 已匹配行配到的分录(展示"配到了什么")
// + 本账户本币的候选分录清单(bank_unmatched_journal_lines)。
// 已对账的报表是只读的 —— 直接跳回详情页。
import { notFound, redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../../../Subnav'
import ReconcileWorkspace, {
    type StatementLine,
    type Candidate,
} from './ReconcileWorkspace'

type MatchRow = {
    statement_line_id: string
    matched_amount: number
    journal_lines: {
        id: string
        journal_entries: { id: string; code: string; entry_date: string; memo: string | null } | null
    } | null
}

export default async function ReconcilePage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: stmt, error } = await supabase
        .from('bank_statements')
        .select('id, code, bank_account_code, currency, period_start, period_end, opening_balance, closing_balance, status')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !stmt) {
        notFound()
    }

    // 已对账 = 只读,工作台没有意义
    if (stmt.status === 'reconciled') {
        redirect(`/finance/bank/statements/${id}`)
    }

    const [linesRes, candidatesRes] = await Promise.all([
        supabase
            .from('bank_statement_lines')
            .select('id, line_no, line_date, description, reference, amount, match_status, ignore_reason')
            .eq('statement_id', id)
            .order('line_no', { ascending: true }),
        supabase
            .from('bank_unmatched_journal_lines')
            .select('journal_line_id, entry_id, entry_code, entry_date, memo, source_type, amount_ccy, direction')
            .eq('account_code', stmt.bank_account_code)
            .eq('currency', stmt.currency)
            .order('entry_date', { ascending: true }),
    ])

    const rawLines = linesRes.data ?? []

    // 已匹配行配到的分录(页级一次 .in;用于在行下方展示 entry code + 链接)
    const matchedLineIds = rawLines.filter((l) => l.match_status === 'matched').map((l) => l.id)
    const { data: matchRows } = matchedLineIds.length
        ? await supabase
              .from('bank_line_matches')
              .select('statement_line_id, matched_amount, journal_lines(id, journal_entries(id, code, entry_date, memo))')
              .in('statement_line_id', matchedLineIds)
        : { data: [] as MatchRow[] }

    const matchesByLine = new Map<string, { entry_id: string; entry_code: string; amount: number }[]>()
    for (const m of (matchRows as unknown as MatchRow[] | null) ?? []) {
        const entry = m.journal_lines?.journal_entries
        if (!entry) continue
        const list = matchesByLine.get(m.statement_line_id) ?? []
        list.push({ entry_id: entry.id, entry_code: entry.code, amount: m.matched_amount })
        matchesByLine.set(m.statement_line_id, list)
    }

    const lines: StatementLine[] = rawLines.map((l) => ({
        id: l.id,
        line_no: l.line_no,
        line_date: l.line_date,
        description: l.description,
        reference: l.reference,
        amount: l.amount,
        match_status: l.match_status as StatementLine['match_status'],
        ignore_reason: l.ignore_reason,
        matches: matchesByLine.get(l.id) ?? [],
    }))

    const candidates: Candidate[] = ((candidatesRes.data ?? []) as unknown as Candidate[]).map((c) => ({
        journal_line_id: c.journal_line_id,
        entry_id: c.entry_id,
        entry_code: c.entry_code,
        entry_date: c.entry_date,
        memo: c.memo,
        source_type: c.source_type,
        amount_ccy: c.amount_ccy,
        direction: c.direction,
    }))

    return (
        <div className="p-8 max-w-[110rem]">
            <h1 className="text-2xl font-bold mb-4">{t('bank.title')}</h1>
            <Subnav />
            <ReconcileWorkspace
                statement={{
                    id: stmt.id,
                    code: stmt.code,
                    bank_account_code: stmt.bank_account_code,
                    currency: stmt.currency,
                    period_start: stmt.period_start,
                    period_end: stmt.period_end,
                    opening_balance: stmt.opening_balance,
                    closing_balance: stmt.closing_balance,
                }}
                lines={lines}
                candidates={candidates}
            />
        </div>
    )
}

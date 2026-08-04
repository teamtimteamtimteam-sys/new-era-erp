// 期末重估(FIN-7 C4):先看【将要重估什么、算出的调整额】,再过账。
// 预览用与 revalue_foreign_balances 同一口径的只读查询;函数本身幂等。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import RevalueButton from './RevalueButton'
import { formatMoney } from '@/lib/format'

export default async function RevaluationPage({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
    const sp = await searchParams
    const d = sp.date ?? new Date().toISOString().slice(0, 10)
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: mid } = await supabase.from('fx_rates').select('currency, rate_sgd_per_unit')
        .eq('rate_date', d).eq('rate_type', 'mid').is('deleted_at', null)
    const midBy = new Map((mid ?? []).map((m) => [m.currency, Number(m.rate_sgd_per_unit)]))

    // 与函数同口径的预览(外币行净额 + 既往重估行)
    const { data: rows } = await supabase.rpc('current_user_permissions').then(async () =>
        supabase.from('journal_lines')
            .select('amount_ccy, currency, debit, credit, journal_entries!inner(entry_date, status, source_type), accounts!inner(code, is_monetary)')
            .neq('currency', 'SGD').lte('journal_entries.entry_date', d)
            .eq('journal_entries.status', 'posted').eq('accounts.is_monetary', true))
    type R = { amount_ccy: number; currency: string; debit: number; credit: number
        accounts: { code: string }; journal_entries: { entry_date: string } }
    const agg = new Map<string, { native: number; carry: number }>()
    for (const l of ((rows ?? []) as unknown as R[])) {
        const k = l.accounts.code + '|' + l.currency
        const a = agg.get(k) ?? { native: 0, carry: 0 }
        a.native += l.debit > 0 ? Number(l.amount_ccy) : -Number(l.amount_ccy)
        a.carry += Number(l.debit) - Number(l.credit)
        agg.set(k, a)
    }
    // 既往重估行并入承载额
    const { data: prev } = await supabase.from('journal_lines')
        .select('debit, credit, accounts!inner(code), journal_entries!inner(entry_date, status, source_type)')
        .eq('currency', 'SGD').eq('journal_entries.source_type', 'revaluation')
        .eq('journal_entries.status', 'posted').lte('journal_entries.entry_date', d)
    for (const l of ((prev ?? []) as unknown as { debit: number; credit: number; accounts: { code: string } }[])) {
        for (const [k, a] of agg) {
            if (k.startsWith(l.accounts.code + '|')) { a.carry += Number(l.debit) - Number(l.credit); break }
        }
    }
    const preview = [...agg.entries()].map(([k, a]) => {
        const [code, ccy] = k.split('|')
        const rate = midBy.get(ccy)
        const target = rate !== undefined ? Math.round(a.native * rate * 100) / 100 : null
        return { code, ccy, native: Math.round(a.native * 100) / 100,
                 carry: Math.round(a.carry * 100) / 100, rate,
                 adj: target !== null ? Math.round((target - a.carry) * 100) / 100 : null }
    }).filter((p) => p.native !== 0 || p.carry !== 0)

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.reval.title')}</h1>
            <Subnav />
            <form method="get" className="mb-4">
                <input type="date" name="date" defaultValue={d} className="border border-gray-300 rounded px-2 py-1 text-sm" />
                <button type="submit" className="ml-2 border border-gray-300 rounded px-3 py-1 text-sm">{t('reviews.filter')}</button>
            </form>
            {(mid ?? []).length === 0 && (
                <div className="mb-4 rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800">
                    {t('finance.reval.noMid', { 0: d })}
                </div>
            )}
            <table className="w-full border-collapse border border-gray-300 text-sm mb-4">
                <thead className="bg-gray-100"><tr>
                    <th className="border border-gray-300 px-3 py-2 text-left">{t('finance.reval.account')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-right">{t('finance.reval.native')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-right">{t('finance.reval.carry')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-right">{t('finance.reval.mid')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-right">{t('finance.reval.adj')}</th>
                </tr></thead>
                <tbody>
                    {preview.map((p) => (
                        <tr key={p.code + p.ccy}>
                            <td className="border border-gray-300 px-3 py-2 font-mono">{p.code} · {p.ccy}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoney(p.native)}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoney(p.carry)}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{p.rate ?? '—'}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono font-medium">
                                {p.adj === null ? '—' : formatMoney(p.adj)}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
            <RevalueButton periodEnd={d} disabled={(mid ?? []).length === 0} />
        </div>
    )
}

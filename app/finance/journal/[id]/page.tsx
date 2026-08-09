// app/finance/journal/[id]/page.tsx
// 分录详情:头部(编号/日期/摘要/来源/状态)+ 行表(科目、借、贷、原币、行摘要)+ Σ。
// posted → 冲销按钮;reversed → "已被 X 冲销"横幅;冲销单自身 → "冲销自 X"横幅
// (通过 reversed_by 反查:谁的 reversed_by 指向本单,本单就是它的冲销单)。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatMoney } from '@/lib/format'
import Subnav from '../../Subnav'
import ReverseButton from './ReverseButton'
import { resolveSourceHrefs, sourceHrefKey } from '../../sourceLinks'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
type LineRow = {
    id: string
    debit: number
    credit: number
    currency: string
    amount_ccy: number
    fx_rate: number
    line_memo: string | null
    accounts: { code: string; name_en: string; name_zh: string } | null
}

export default async function JournalDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()

    const [entryRes, linesRes] = await Promise.all([
        supabase
            .from('journal_entries')
            .select('id, code, entry_date, memo, source_type, source_id, status, reversed_by')
            .eq('id', id)
            .single(),
        supabase
            .from('journal_lines')
            .select('id, debit, credit, currency, amount_ccy, fx_rate, line_memo, accounts ( code, name_en, name_zh )')
            .eq('entry_id', id)
            .order('created_at', { ascending: true })
            .order('id', { ascending: true }),
    ])

    if (entryRes.error || !entryRes.data) {
        notFound()
    }

    const entry = entryRes.data
    const lines = ((linesRes.data as unknown as LineRow[] | null) ?? [])

    // 冲销关系 + 来源链接(单条小查询)
    const [reversedByRes, reversalOfRes, hrefs] = await Promise.all([
        entry.reversed_by
            ? supabase.from('journal_entries').select('id, code').eq('id', entry.reversed_by).single()
            : Promise.resolve({ data: null, error: null }),
        supabase.from('journal_entries').select('id, code').eq('reversed_by', id).maybeSingle(),
        resolveSourceHrefs(supabase, [entry]),
    ])

    const sumDebit = Math.round(lines.reduce((s, l) => s + l.debit, 0) * 100) / 100
    const sumCredit = Math.round(lines.reduce((s, l) => s + l.credit, 0) * 100) / 100
    const accountName = (l: LineRow) =>
        l.accounts ? (locale === 'zh' ? l.accounts.name_zh : l.accounts.name_en) : '—'
    const sourceHref = hrefs.get(sourceHrefKey(entry))

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/journal" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('finance.detailTitle')}</h1>

            <Subnav />

            {/* 冲销关系横幅 */}
            {entry.status === 'reversed' && reversedByRes.data && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    <Link
                        href={`/finance/journal/${reversedByRes.data.id}`}
                        className="text-blue-600 hover:underline"
                    >
                        {t('finance.reversedBanner', { code: reversedByRes.data.code })}
                    </Link>
                </div>
            )}
            {reversalOfRes.data && (
                <div className="bg-gray-50 border border-gray-300 text-gray-700 px-4 py-3 rounded mb-4 text-sm">
                    <Link
                        href={`/finance/journal/${reversalOfRes.data.id}`}
                        className="text-blue-600 hover:underline"
                    >
                        {t('finance.reversalOfBanner', { code: reversalOfRes.data.code })}
                    </Link>
                </div>
            )}

            {/* 头部 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colCode')}:</span>
                    <span className="font-mono font-medium">{entry.code}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.entryDate')}:</span>
                    <span>{entry.entry_date}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colSource')}:</span>
                    {entry.source_type ? (
                        sourceHref ? (
                            <Link href={sourceHref} className="text-blue-600 hover:underline">
                                {t('finance.source.' + entry.source_type)}
                            </Link>
                        ) : (
                            <span>{t('finance.source.' + entry.source_type)}</span>
                        )
                    ) : (
                        <span>—</span>
                    )}
                </div>
                <div>
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (entry.status === 'posted'
                                ? 'bg-green-100 text-green-800'
                                : 'bg-gray-200 text-gray-700')
                        }
                    >
                        {t('finance.status.' + entry.status)}
                    </span>
                </div>
                {entry.status === 'posted' && <ReverseButton entryId={entry.id} />}
            </div>

            {entry.memo && (
                <p className="text-sm text-gray-600 mb-4">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {entry.memo}
                </p>
            )}

            {/* 行表 */}
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colAccount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.debit')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.credit')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colOriginalCcy')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.lineMemo')}</th>
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l) => (
                        <tr key={l.id}>
                            <td className="border border-gray-300 px-4 py-2">
                                <span className="font-mono text-sm mr-2">{l.accounts?.code ?? '—'}</span>
                                {accountName(l)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {l.debit > 0 ? formatMoney(l.debit) : ''}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {l.credit > 0 ? formatMoney(l.credit) : ''}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm text-gray-600">
                                {l.currency !== baseCurrency
                                    ? `${l.currency} ${formatMoney(l.amount_ccy)} @ ${l.fx_rate}`
                                    : '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">{l.line_memo ?? '—'}</td>
                        </tr>
                    ))}
                </tbody>
                <tfoot>
                    <tr className="bg-gray-100 font-bold">
                        <td className="border border-gray-300 px-4 py-2">{t('finance.totalsLabel')}</td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatMoney(sumDebit)}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatMoney(sumCredit)}
                        </td>
                        <td className="border border-gray-300 px-4 py-2" colSpan={2} />
                    </tr>
                </tfoot>
            </table>
        </div>
    )
}

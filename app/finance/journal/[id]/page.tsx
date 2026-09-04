// app/finance/journal/[id]/page.tsx
// 分录详情:头部(编号/日期/摘要/来源/状态)+ 行表(科目、借、贷、原币、行摘要)+ Σ。
// posted → 冲销按钮;reversed → "已被 X 冲销"横幅;冲销单自身 → "冲销自 X"横幅
// (通过 reversed_by 反查:谁的 reversed_by 指向本单,本单就是它的冲销单)。
//
// ★ CONV-8(2026-09-04):转成 ListPage + RecordHeader + DataTable。
//   模板与三条判据见 docs/detail-page-template.md。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import ReverseButton from './ReverseButton'
import { resolveSourceHrefs, sourceHrefKey } from '../../sourceLinks'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import JournalLinesTable, { type JournalLineRow } from './JournalLinesTable'

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

    // ★【行数据在服务端压平成纯字符串】★ locale(科目名取 zh 还是 en)与
    // baseCurrency(金额格式)都是只有服务端知道的东西;一个函数、一个 Map 都不
    // 过客户端边界 —— CONV-1 §① 的通则,与 /inbound 的来源列逐字同形。
    const tableRows: JournalLineRow[] = lines.map((l) => ({
        id: l.id,
        accountCode: l.accounts?.code ?? '—',
        accountName: accountName(l),
        debitText: l.debit > 0 ? formatAmount(l.debit, baseCurrency) : '',
        creditText: l.credit > 0 ? formatAmount(l.credit, baseCurrency) : '',
        // 借/贷是本位币,自己带币种;同表「原币」列写的是【另一个】币种,
        // 不能拿它当"这屏已经写了币种"的凭据(CCY-1 RULE 3)。
        ccyText:
            l.currency !== baseCurrency
                ? `${l.currency} ${formatMoneyBare(l.amount_ccy, '同格内紧邻的 l.currency 前缀')} @ ${l.fx_rate}`
                : '—',
        memo: l.line_memo ?? '—',
    }))

    // ★ 合计行是【数据】,不是 <tfoot> —— CONV-4 §⑨-3 定的型,见表组件抬头。
    if (tableRows.length > 0) {
        tableRows.push({
            id: '__total__',
            accountCode: '',
            accountName: t('finance.totalsLabel'),
            debitText: formatAmount(sumDebit, baseCurrency),
            creditText: formatAmount(sumCredit, baseCurrency),
            ccyText: '',
            memo: '',
            isTotal: true,
        })
    }

    return (
        <ListPage
            maxWidth="max-w-4xl"
            // ★ CONV-8 加的槽:返回链接画在标题【之上】,与转换前同位置。
            breadcrumb={
                <Link href="/finance/journal" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            }
            title={t('finance.detailTitle')}
            // ★★【详情页恒为 ok,而这【不是】一个权宜之计】★★
            // 一条记录存在与否由上面的 notFound() 回答,不由空态回答:页面画得出来
            // 就说明这张分录在。空的只可能是它下面那张行表,而那句空态归表自己说
            // (DataTable 的 empty prop)。于是「出口被空态吃掉」这一类
            // 在详情页上【构造上不可能发生】—— 详见 docs/detail-page-template.md。
            state={{ kind: 'ok' }}
            // 冲销关系横幅:无条件渲染,与 CONV-1 的 notices 槽同一条理由。
            notices={
                <>
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
                </>
            }
        >
            {/* ★ 记录抬头 —— 动作(冲销)住在它自己的槽里,不混进 fields:
                一个动作不是一个值。见 record-header.tsx 抬头。 */}
            <RecordHeader
                fields={[
                    { label: t('finance.colCode'), value: entry.code, mono: true },
                    { label: t('finance.entryDate'), value: entry.entry_date },
                    {
                        label: t('finance.colSource'),
                        value: entry.source_type ? (
                            sourceHref ? (
                                <Link href={sourceHref} className="text-blue-600 hover:underline">
                                    {t('finance.source.' + entry.source_type)}
                                </Link>
                            ) : (
                                t('finance.source.' + entry.source_type)
                            )
                        ) : (
                            '—'
                        ),
                    },
                    {
                        label: t('finance.colStatus'),
                        value: (
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
                        ),
                    },
                ]}
                actions={entry.status === 'posted' ? <ReverseButton entryId={entry.id} /> : undefined}
            />

            {entry.memo && (
                <p className="text-sm text-gray-600 mb-4">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {entry.memo}
                </p>
            )}

            <JournalLinesTable rows={tableRows} />
        </ListPage>
    )
}

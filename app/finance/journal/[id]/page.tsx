// app/finance/journal/[id]/page.tsx
// 分录详情:头部(编号/日期/摘要/来源/状态)+ 行表(科目、借、贷、原币、行摘要)+ Σ。
// posted → 冲销按钮(APR-6 起:提一张冲销申请,CFO 批准才冲);reversed → "已被 X 冲销"横幅;冲销单自身 → "冲销自 X"横幅
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
import { can } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { mustOne, mustRows } from '@/lib/db-helpers'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import EndedBanner, { ReversalOfBanner } from '@/app/components/trail/EndedBanner'
import { reversalReasonText } from '@/lib/trail/render'

// FK 嵌入运行时是对象;显式类型 + cast 锁住。
// ★ U1-A(Tim 的 UNBLOCK-1 Q1–Q3,2026-10-05):行从 journal_lines_masked 读 —— 工资分录的三个金额对不持 data.view_pay 的人是 null,
//   amounts_restricted = true;side 说这一行记在哪一边。基表上那条 restrictive 策略让这几行对他们在 API 上不在,
//   所以这一页若照旧读基表,工资分录的行表会是空的 —— 一张"没有行"的分录,比一个「受限」更坏。
type LineRow = {
    id: string
    debit: number | null
    credit: number | null
    currency: string
    amount_ccy: number | null
    fx_rate: number
    line_memo: string | null
    side: 'debit' | 'credit'
    amounts_restricted: boolean
    accounts: { code: string; name_en: string; name_zh: string } | null
}

export default async function JournalDetailPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const canEditGate = await can('module.finance.edit')

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
            .from('journal_lines_masked')
            .select('id, account_id, debit, credit, currency, amount_ccy, fx_rate, line_memo, side, amounts_restricted')
            .eq('entry_id', id)
            .order('created_at', { ascending: true })
            .order('id', { ascending: true }),
    ])

    if (entryRes.error || !entryRes.data) {
        notFound()
    }

    const entry = entryRes.data
    // 读不出来就抛 —— 一次失败不许被读成"这张分录没有行"(mustRows)
    const rawLines = mustRows(linesRes, 'journal_lines_masked') as unknown as (Omit<LineRow, 'accounts'> & { account_id: string })[]
    // 科目名单独取(accounts 对每一个登录用户可读)—— 不靠 PostgREST 从一张连表视图推出外键去内嵌
    const accountIds = [...new Set(rawLines.map((l) => l.account_id))]
    const accountRows = accountIds.length
        ? mustRows(await supabase.from('accounts').select('id, code, name_en, name_zh').in('id', accountIds), 'accounts')
        : []
    const accountById = new Map(accountRows.map((a) => [a.id, { code: a.code, name_en: a.name_en, name_zh: a.name_zh }]))
    const lines: LineRow[] = rawLines.map((l) => ({ ...l, accounts: accountById.get(l.account_id) ?? null }))
    const anyRestricted = lines.some((l) => l.amounts_restricted)

    // ★ APR-6:冲销钮问库的同一份判据(journal_entry_reversal_route),再看这张分录上有没有一张在等的冲销申请。
    //   判据读不出来(error)就抛 —— 一次失败不许被读成"可以冲"。
    const [routeRes, openRevRes] = await Promise.all([
        supabase.rpc('journal_entry_reversal_route', { p_entry_id: id }),
        supabase.from('journal_requests').select('label')
            .eq('target_entry_id', id).eq('kind', 'reversal').eq('status', 'submitted').maybeSingle(),
    ])
    const route = mustOne(routeRes, 'journal_entry_reversal_route') as string | null
    const openReversalLabel = mustOne(openRevRes, 'journal_requests')?.label ?? null

    // 冲销关系 + 来源链接(单条小查询)
    const [reversedByRes, reversalOfRes, hrefs] = await Promise.all([
        // AUDIT-TRAIL-1c-1(Q8):横幅说【谁、何时】冲销的 —— 取自冲销那一张分录的建立(原分录上没有冲销戳)
        entry.reversed_by
            ? supabase.from('journal_entries').select('id, code, created_at, created_by, memo').eq('id', entry.reversed_by).single()
            : Promise.resolve({ data: null, error: null }),
        supabase.from('journal_entries').select('id, code').eq('reversed_by', id).maybeSingle(),
        resolveSourceHrefs(supabase, [entry]),
    ])

    const sumDebit = Math.round(lines.reduce((s, l) => s + (l.debit ?? 0), 0) * 100) / 100
    const sumCredit = Math.round(lines.reduce((s, l) => s + (l.credit ?? 0), 0) * 100) / 100
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
        debitText: l.debit !== null && l.debit > 0 ? formatAmount(l.debit, baseCurrency) : '',
        creditText: l.credit !== null && l.credit > 0 ? formatAmount(l.credit, baseCurrency) : '',
        debitRestricted: l.amounts_restricted && l.side === 'debit',
        creditRestricted: l.amounts_restricted && l.side === 'credit',
        // 借/贷是本位币,自己带币种;同表「原币」列写的是【另一个】币种,
        // 不能拿它当"这屏已经写了币种"的凭据(CCY-1 RULE 3)。
        ccyText:
            l.currency !== baseCurrency
                ? l.amount_ccy === null
                    ? `${l.currency} · ${t('common.restricted')}`
                    : `${l.currency} ${formatMoneyBare(l.amount_ccy, '同格内紧邻的 l.currency 前缀')} @ ${l.fx_rate}`
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
            // 一行受限,合计就是那几行的和 —— 两格一起受限,不印一个"少了几行"的数
            debitRestricted: anyRestricted,
            creditRestricted: anyRestricted,
        })
    }

    return (
        <ListPage
            maxWidth="max-w-4xl"
            // ★ CONV-8 加的槽:返回链接画在标题【之上】,与转换前同位置。
            breadcrumb={
                <Link href="/finance/journal" className="hover:underline text-sm app-link">
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
            // AUDIT-TRAIL-1c-1(Q8):冲销了的分录 → "Reversed on DD/MM/YYYY by <name>" + 链到冲销分录;冲销分录 → "Reversal of …"
            //   (英文,与审计记录同一份目录;以前是两条各自的中英文链接)
            notices={
                <>
                    {entry.status === 'reversed' && reversedByRes.data && (
                        <EndedBanner kind="reversed" at={reversedByRes.data.created_at} by={reversedByRes.data.created_by}
                            reason={reversalReasonText(reversedByRes.data.memo)}
                            link={{ code: reversedByRes.data.code, href: `/finance/journal/${reversedByRes.data.id}` }} />
                    )}
                    {reversalOfRes.data && (
                        <ReversalOfBanner code={reversalOfRes.data.code} href={`/finance/journal/${reversalOfRes.data.id}`} />
                    )}
                </>
            }
        >
            {/* ★ 记录抬头 —— 动作(冲销)住在它自己的槽里,不混进 fields:
                一个动作不是一个值。见 record-header.tsx 抬头。 */}
            <RecordHeader
                fields={[
                    { label: t('finance.colCode'), value: entry.code, mono: true },
                    { label: t('finance.entryDate'), value: formatDate(entry.entry_date, locale) },
                    {
                        label: t('finance.colSource'),
                        value: entry.source_type ? (
                            sourceHref ? (
                                <Link href={sourceHref} className="hover:underline app-link app-link-inline">
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
                actions={entry.status === 'posted' && (route === 'request' || route === 'source_path')
                    ? <ReverseButton canEdit={canEditGate} entryId={entry.id} subject={entry.code}
                        route={route} sourceType={entry.source_type} openRequestLabel={openReversalLabel} />
                    : undefined}
            />

            {entry.memo && (
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
                    <span className="text-[color:var(--brand-muted-text)] mr-1">{t('finance.memo')}:</span>
                    {entry.memo}
                </p>
            )}

            <JournalLinesTable rows={tableRows} />

            <AuditTrail subject="journal_entry" id={entry.id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}

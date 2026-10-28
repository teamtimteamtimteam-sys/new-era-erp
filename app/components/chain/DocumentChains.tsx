// app/components/chain/DocumentChains.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-3 · 单据详情页上那条上下游链条(Tim 2026-10-26 裁定 2.4 (12);2026-10-27 SYSTEM-MAP-3 Q1–Q5)
// ════════════════════════════════════════════════════════════════════════════
//
// 【它是什么】一张单据页顶上,这张单据所在的每一条链各一条:整条链的每一步都在,读者站的那一步标出来;
//   别的每一步画那一步的单据(链接)、「还没有」,或「受限」带上要的码 —— 从不藏起来、从不留空。
//   下面再有一个「全部关联记录」,落在 /related/<种类>/<id>(Tim Q2)。
//
// 【数据】一条链的步骤与边在 lib/chains.ts(唯一出处);哪两张单据有关系由关联图回答 ——
//   document_chain_walk() 经 search_related_rows() 走(外键推出来的边 + document_relation_arms 声明的边),
//   与关联页同一份定义。取数是 INVOKER:读者看不见的,它就找不到。
//
// ★★【「受限」「只经过 X 才到得了」「还没有」—— 三句话,不许混】★★
//   ① 读者打不开这一步(没有那一步的读码)→「受限 —— 需要 <码>」,**不论那一步有没有单据**(Tim Q5)。
//      码:单据步骤读 document_types.view_permission(ANY 语义,交给 allows());宿主步骤读 lib/chains.ts 的 permission。
//   ② 读者打得开这一步,但取数只能经过一个【打不开】的步骤才走得到它 →「受限 —— 只经过「X」才到得了」。
//      判据与 document_chain_walk() 的走法逐字同形:一步的来源是它【不比它离读者更远】的相邻步骤;
//      它的每一个来源都打不开(或者自己也是只经过别处才到得了)⇒ 它找不到东西,不是因为没有,是因为走不到。
//      ☞ 没有这一格,一个仓库读者会在进料批页上读到「应付:还没有」—— 那是一句关于数据的断言,而事实是关于权限的。
//   ③ 打得开、也走得到、而一张都没有 →「还没有」。
//
// ★ 一步最多画 3 个链接,其余是「另外 N 个」:直接相关的那一步(离这一张一步)链到它自己的关联页,
//   隔着几步的链到这一张的「全部关联记录」(Tim 接受的 grilling 第 6 条)。
// ★ 版式(Tim Q1):≥ 640px 一行会换行的小块;< 640px 收成一行「<链> · 第 n 步,共 N 步 · 展开链条」,
//   点开是竖着的清单 —— 每一步、每一个「受限」点开之后都在。两种画法在同一份 DOM 里(sm:hidden / hidden sm:block),
//   版式勘察在 390 与桌面两个宽度各量一次(AGENTS.md:响应式显隐的导航元素要在人真用的那个宽度上看)。
// ★ 构建检查:scripts/check-chain-bar.mjs —— 每一种链上单据的详情页都要画 <DocumentChains>。
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { getMyPermissions } from '@/lib/permissions'
import { allows } from '@/lib/modules'
import { chainById, chainWalkDefinition, type Chain, type ChainId, type ChainStep } from '@/lib/chains'

/** 一步最多画几个链接(Tim 接受的 grilling 第 6 条) */
const LINKS_PER_STEP = 3

type DbError = { message: string; code?: string } | null
type DocTypeRow = { key: string; table_name: string; prefix: string; view_permission: string[] }
type WalkRow = { step: number; key: string; id: string; code: string; label: string | null; href: string | null }
type Shown = { code: string; href: string | null }
type StepView =
    | { state: 'current'; docs: Shown[] }
    | { state: 'restricted'; code: string }
    | { state: 'blocked'; through: string }
    | { state: 'found'; docs: Shown[]; more: number; moreHref: string }
    | { state: 'none' }

type Tr = (k: string, p?: Record<string, string | number>) => string

type Props = {
    /** 这张单据住的表(document_types.table_name) */
    table: string
    id: string
    /** 单据号 —— 一张表挂着几种单据时(付款 PMT / RCPT、产出批 13 个前缀)按前缀认出这一张是哪一种 */
    code: string
    /** 这一页在哪几条链上、站在哪一步。一种单据不在某一步的 keys 里时(收款页上的采购链),那一条不画。 */
    chains: readonly { chain: ChainId; step: string }[]
}

/**
 * ★ SYSTEM-MAP-3(Tim 2026-10-27 23:45 裁定 2):链条【在页面画完之后】流进来 —— 一次慢的或失败的取数,
 *   既不拖慢、也不拖垮那张单据页。占位是一块与收起的链条同高的空位(不跳版;不用骨架类 —— 那一组类名归 check-base-isolation 管)。
 */
export default function DocumentChains(props: Props) {
    return (
        <Suspense fallback={<div className="mb-6 h-9" data-document-chains-loading="" aria-busy="true" />}>
            <ChainsBody {...props} />
        </Suspense>
    )
}

async function ChainsBody(props: Props) {
    const t: Tr = await getTranslations()
    try {
        return await chainsBody(t, props)
    } catch (e) {
        // ★ 链条这一格【说出来】它没画出来 —— 不吞掉(不是一条空链),也不让它冒到页面的错误边界去拖垮整页
        return (
            <p data-document-chains="" data-chain-failed=""
               className="mb-6 rounded-md border border-[color:var(--brand-border)] px-3 py-2 text-[13px] text-[color:var(--brand-muted-text)]">
                {t('chain.failedAll', { reason: e instanceof Error ? e.message : String(e) })}
            </p>
        )
    }
}

async function chainsBody(t: Tr, { table, id, code, chains }: Props) {
    const supabase = await createClient()
    const perms = await getMyPermissions()

    const types = mustRows(
        await supabase.from('document_types').select('key, table_name, prefix, view_permission') as { data: DocTypeRow[] | null; error: DbError },
        'document_types')
    const mine = types.filter((d) => d.table_name === table)
    const me = mine.length === 1 ? mine[0] : mine.find((d) => code.startsWith(d.prefix + '-'))
    if (!me) {
        throw new Error(`DOCUMENT_CHAIN_UNKNOWN_DOCUMENT|${table} ${code} —— document_types 里认不出这一张是哪一种单据`)
    }
    const byKey = new Map(types.map((d) => [d.key, d]))

    const bars: React.ReactNode[] = []
    for (const spec of chains) {
        const chain = chainById(spec.chain)
        const at = chain.steps.findIndex((s) => s.id === spec.step)
        if (at < 0) throw new Error(`DOCUMENT_CHAIN_UNKNOWN_STEP|${spec.chain}.${spec.step} —— lib/chains.ts 里没有这一步`)
        if (!chain.steps[at].keys.includes(me.key)) continue

        // ★ 取数失败【说出来】,不吞掉、也不拖垮整张单据页:链条那一格写明它没画出来、为什么(一次失败不是一条空链 ——
        //   mustRows 照旧把失败抛出来,这里接住它只为把它画在链条自己的位置上,而不是让整页 500)。
        //   live proof 实测过这一格的来由:七个读者并行时取数撞上 authenticated 的 8 秒语句上限(57014),整张进料批页跟着 500。
        let rows: WalkRow[]
        let lines: Map<string, string>
        try {
            rows = mustRows(
                await supabase.rpc('document_chain_walk', {
                    p_chain: chainWalkDefinition(chain), p_step: at, p_key: me.key, p_id: id,
                }) as { data: WalkRow[] | null; error: DbError },
                'document_chain_walk')
            lines = rows.length === 0 ? new Map() : await bankLines(supabase, chain, rows)
        } catch (e) {
            bars.push(
                <p key={chain.id} data-chain={chain.id} data-chain-failed=""
                   className="rounded-md border border-[color:var(--brand-border)] px-3 py-2 text-[13px] text-[color:var(--brand-muted-text)]">
                    {t('chain.failed', { chain: t(`chain.name.${chain.id}`), reason: e instanceof Error ? e.message : String(e) })}
                </p>)
            continue
        }
        // 一行都没有 = 这一张不在这条链的这一步上(一张不是付薪分录的分录)—— 这一条不画
        if (rows.length === 0) continue

        const views = stepViews(t, chain, at, rows, perms, byKey, me.key, id, lines)
        bars.push(<ChainBar key={chain.id} t={t} chain={chain} at={at} views={views} />)
    }

    return (
        <div className="mb-6 flex flex-col gap-2" data-document-chains="">
            {bars}
            <p className="text-sm">
                <Link href={`/related/${me.key}/${id}`} className="app-link hover:underline" data-related-all="">
                    {t('chain.allRelated')}
                </Link>
            </p>
        </div>
    )
}

/** 「银行对账」那一步链到匹配上的那一行:对账单 id → 行 id(只为这一条链上找到的付款问一次) */
async function bankLines(
    supabase: Awaited<ReturnType<typeof createClient>>, chain: Chain, rows: WalkRow[],
): Promise<Map<string, string>> {
    const out = new Map<string, string>()
    if (!chain.steps.some((s) => s.anchor === 'line')) return out
    const paymentStep = chain.steps.findIndex((s) => s.keys.includes('payment_out'))
    const payments = rows.filter((r) => r.step === paymentStep).map((r) => r.id)
    if (payments.length === 0) return out
    const got = mustRows(
        await supabase.rpc('bank_match_lines', { p_payment_ids: payments }) as {
            data: { payment_id: string; statement_id: string; line_id: string }[] | null; error: DbError },
        'bank_match_lines')
    for (const g of got) if (!out.has(g.statement_id)) out.set(g.statement_id, g.line_id)
    return out
}

function stepViews(
    t: Tr, chain: Chain, at: number, rows: WalkRow[], perms: readonly string[],
    byKey: Map<string, DocTypeRow>, myKey: string, myId: string, lines: Map<string, string>,
): StepView[] {
    const n = chain.steps.length
    const codeFor = (s: ChainStep): string[] =>
        s.permission ? [s.permission] : [...new Set(s.keys.flatMap((k) => byKey.get(k)?.view_permission ?? []))]
    const open = chain.steps.map((s) => allows({ all: [], any: codeFor(s) }, perms))

    // 步骤图上的距离 —— 与 document_chain_walk() 同一个 BFS
    const dist = Array<number>(n).fill(-1)
    dist[at] = 0
    for (let changed = true; changed;) {
        changed = false
        for (const [a, b] of chain.edges) {
            if (dist[a] >= 0 && dist[b] < 0) { dist[b] = dist[a] + 1; changed = true }
            else if (dist[b] >= 0 && dist[a] < 0) { dist[a] = dist[b] + 1; changed = true }
        }
    }
    const sources = (j: number) => chain.edges
        .flatMap(([a, b]) => (a === j ? [b] : b === j ? [a] : []))
        .filter((s) => dist[s] >= 0 && dist[s] <= dist[j])

    // ② 走不到:它的每一个来源都打不开,或者自己也走不到 —— 到不再变为止(同一圈的互为来源)
    const blockedBy: (number | null)[] = Array(n).fill(null)
    const reach = chain.steps.map((_, j) => j === at)
    for (let changed = true; changed;) {
        changed = false
        for (let j = 0; j < n; j++) {
            if (reach[j] || !open[j]) continue
            if (sources(j).some((s) => reach[s] && (s === at || open[s]))) { reach[j] = true; changed = true }
        }
    }
    // 点名离读者最近的那一个打不开的来源;它的来源都打得开(只是自己也走不到)时,沿最近的那个来源借它的名字。按距离排,近的先算
    const byDist = chain.steps.map((_, j) => j).filter((j) => dist[j] > 0).sort((x, y) => dist[x] - dist[y] || x - y)
    for (const j of byDist) {
        if (reach[j] || !open[j]) continue
        const ss = sources(j).sort((x, y) => dist[x] - dist[y] || x - y)
        const closed = ss.find((s) => s !== at && !open[s])
        blockedBy[j] = closed ?? ss.map((s) => blockedBy[s]).find((x) => x !== null) ?? null
    }

    return chain.steps.map((s, j): StepView => {
        const mine = rows.filter((r) => r.step === j)
        const shown = (r: WalkRow): Shown => ({ code: r.code, href: hrefFor(s, r, lines) })
        if (j === at) return { state: 'current', docs: mine.map(shown) }
        if (!open[j]) return { state: 'restricted', code: codeFor(s).join(' / ') }
        if (mine.length === 0) {
            if (!reach[j]) {
                const x = blockedBy[j]
                return { state: 'blocked', through: x === null ? t(`chain.step.${s.id}`) : t(`chain.step.${chain.steps[x].id}`) }
            }
            return { state: 'none' }
        }
        // 「另外 N 个」:离这一张一步的那一步链到它自己的关联页;隔着几步的链到这一张的「全部关联记录」
        const moreHref = dist[j] === 1 && s.keys.length === 1 && s.keys[0] !== myKey
            ? `/related/${myKey}/${myId}/${s.keys[0]}`
            : `/related/${myKey}/${myId}`
        return { state: 'found', docs: mine.slice(0, LINKS_PER_STEP).map(shown), more: Math.max(0, mine.length - LINKS_PER_STEP), moreHref }
    })
}

/** 一步上一张单据链到哪里:那张单据自己的页(document_detail_href)、宿主页的锚点,或应付页 */
function hrefFor(s: ChainStep, r: WalkRow, lines: Map<string, string>): string | null {
    if (s.page === 'payable') return `/finance/payables/${r.id}`
    if (!r.href) return null
    if (s.anchor === 'line') {
        const line = lines.get(r.id)
        return line ? `${r.href}#line-${line}` : r.href
    }
    return s.anchor ? `${r.href}${s.anchor}` : r.href
}

function ChainBar({ t, chain, at, views }: { t: Tr; chain: Chain; at: number; views: StepView[] }) {
    const name = t(`chain.name.${chain.id}`)
    const step = (j: number) => t(`chain.step.${chain.steps[j].id}`)
    return (
        <nav aria-label={name} data-chain={chain.id} data-chain-at={chain.steps[at].id}
             className="rounded-md border border-[color:var(--brand-border)] px-3 py-2 text-[13px]">
            {/* ≥ 640px:一行会换行的小块 */}
            <div className="hidden flex-wrap items-center gap-x-1 gap-y-1.5 sm:flex" data-chain-layout="chips">
                <span className="mr-1 font-medium text-[color:var(--brand-muted-text)]">{name}</span>
                {views.map((v, j) => (
                    <span key={chain.steps[j].id} className="inline-flex items-center gap-1">
                        {j > 0 && <span aria-hidden="true" className="text-[color:var(--brand-muted-text)]">→</span>}
                        <span
                            data-chain-step={chain.steps[j].id}
                            data-chain-state={v.state}
                            aria-current={v.state === 'current' ? 'step' : undefined}
                            className={`inline-flex flex-wrap items-baseline gap-x-1 rounded-full border px-2 py-0.5 ${
                                v.state === 'current'
                                    ? 'border-[color:var(--brand-accent)] font-semibold'
                                    : 'border-[color:var(--brand-border)]'}`}
                        >
                            <span>{step(j)}</span>
                            <StepContent t={t} v={v} />
                        </span>
                    </span>
                ))}
            </div>
            {/* < 640px:收起的一行,点开是竖着的清单(Tim Q1) */}
            <details className="sm:hidden" data-chain-layout="list">
                <summary className="cursor-pointer select-none">
                    {name} · {t('chain.stepOf', { n: at + 1, total: chain.steps.length })} · {t('chain.showChain')}
                </summary>
                <ol className="mt-2 flex flex-col gap-1.5">
                    {views.map((v, j) => (
                        <li key={chain.steps[j].id}
                            data-chain-step={chain.steps[j].id}
                            data-chain-state={v.state}
                            aria-current={v.state === 'current' ? 'step' : undefined}
                            className={`grid grid-cols-[minmax(0,8.5rem)_minmax(0,1fr)] gap-x-2 ${v.state === 'current' ? 'font-semibold' : ''}`}>
                            <span className="break-words">{j + 1}. {step(j)}</span>
                            <span className="flex min-w-0 flex-wrap gap-x-1.5"><StepContent t={t} v={v} /></span>
                        </li>
                    ))}
                </ol>
            </details>
        </nav>
    )
}

function StepContent({ t, v }: { t: Tr; v: StepView }) {
    const docs = (list: Shown[]) => list.map((d) => d.href
        ? <Link key={d.code} href={d.href} className="app-link font-mono text-[12px] hover:underline" data-chain-doc={d.code}>{d.code}</Link>
        : <span key={d.code} className="font-mono text-[12px]" data-chain-doc={d.code}>{d.code}</span>)
    switch (v.state) {
        case 'current':
            return <span className="font-mono text-[12px]" title={t('chain.thisDocument')}>{v.docs.map((d) => d.code).join(' · ')}</span>
        case 'restricted':
            return <span className="text-[color:var(--brand-muted-text)]" data-chain-restricted="">{t('chain.restricted', { code: v.code })}</span>
        case 'blocked':
            return <span className="text-[color:var(--brand-muted-text)]" data-chain-restricted="">{t('chain.reachedOnlyThrough', { step: v.through })}</span>
        case 'none':
            return <span className="text-[color:var(--brand-muted-text)]">{t('chain.noneYet')}</span>
        case 'found':
            return (
                <>
                    {docs(v.docs)}
                    {v.more > 0 && (
                        <Link href={v.moreHref} className="app-link hover:underline" data-chain-more="">{t('chain.more', { n: v.more })}</Link>
                    )}
                </>
            )
    }
}

// app/finance/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-7 ②(2026-09-04)· 财务 Overview —— 【替掉】那张子页面卡片墙
// ════════════════════════════════════════════════════════════════════════════
//
// 【它此前是什么,以及为什么那是错的】NAV-CLEANUP-1 ③ 把这一页做成了
//   <ModuleLanding> —— 把财务名下 31 条二级条目【原样画成一排卡片】。
//   Tim 的裁定(2026-09-04):**绝对不能是模块内子页面的卡片排列。**
//   理由他说得很准,原样抄在这里,因为它是这一页全部形状的来源:
//     /pricing 是卡片排列,而那是【对的】—— 它是一张二级页,它的全部职责就是
//     把三个孩子递出来。**一级模块不同:它的二级菜单已经把每一页都列了一遍。**
//     Overview 再用卡片复述一次,就是同一份清单的第三遍,不添一个字。
//   **所以 /pricing 可以看,但它不是先例;这一页从前的样子也不是。**
//
// ★【那 Overview 到底给什么 —— 一句话,完整论证见 docs/module-overview-basis.md】★
//   **它给那些【横跨若干张子页面、任何一张自己都说不出来】的事实。**
//   菜单答「这里有什么」;账簿答「某一种单据有哪些行」;提醒答「什么在等我」;
//   而"这个模块此刻是什么状态"没有任何一处在答 —— 那就是这一页。
//   这个答案不是本刀发明的:docs/dashboard-arm-inventory.md 早就裁过
//   「**一个仅仅是【有意思】的数,属于那个模块自己的页面**」,
//   而那一页从来没有存在过。CONV-7 ① 把【在等的事】搬去 /tools/reminders 之后,
//   剩下的正是这一类,它们需要一个家。
//
// 【本页选了三条,不是三十条 —— 数量本身是判断的一部分】
//   每一条都必须填得出 <Figure> 的 spans 那一格(它跨了哪几页)。
//   填不出来 = 某一张子页面自己就答得了 = 它不属于这里。这条判据把
//   「未过账分录数」「本月发票张数」这一类【一页就能答】的数全部挡在门外 ——
//   而它们正是一张 Overview 退化成 KPI 墙时会先长出来的东西。
//
// ★【为什么财务是本刀选的两个之一 —— 它是最容易过拟合的那一个】★
//   Tim 的话:「只对财务成立的形状不是那个形状。」所以它必须【和它的反面
//   一起】被建出来(另一个是人力),否则没人知道这个形状是不是财务形的。
//   它同时是最难的一个:31 条二级、六个第三级分组、而且【已经有一个枢纽】
//   在旁边(/finance/month-end)。所以本页与月结的分界必须写死:
//     · 月结答【这个月还差哪几步】—— 它是一张【进度表】,七个信号按依赖序;
//     · 本页答【账本此刻处在什么状态】—— 它不列步骤,也不复制那七个信号。
//   两页都不复制对方,而本页给它一条链接。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { mustOne } from '@/lib/db-helpers'
import { formatAmount, businessToday } from '@/lib/format'
import Figure from '@/app/components/overview/Figure'

// gl_control_reconciliation 的形状。**四条腿,每条自带一个 refusal** ——
// 那一格不是错误,是「这一条腿此刻答不上来」,而答不上来 ≠ 对不上(见该函数抬头:
// 「照答会返回一个自信的 0.00」)。所以它在屏幕上走 Figure 的 unanswerable 那一支。
type ReconSide = {
    side: string
    control_account: string
    ledger_base: number | null
    subledger_base: number | null
    difference_base: number | null
    unexplained_base: number | null
    reconciled: boolean | null
    refusal: string | null
    subledger_basis: string
    variances: { code: string; amount_base: number }[]
}
type Recon = { as_of: string; base_currency: string; sides: ReconSide[] }

export default async function FinanceOverviewPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireFunction(FN.financeHome)
    if (denied) return denied

    const t = await getTranslations()
    const supabase = await createClient()

    // 【屏幕上那个日期由【勾稽自己回显】,不由这里再取一次当天】——
    // gl_control_reconciliation 把 as_of 原样放回结果里,所以 asOfLabel 读的是
    // 它实际算的那一天,而不是"我们打算让它算的那一天"。两者万一不一致,
    // 屏幕会说出真的那一个。
    // 【而传进去的那一天由 businessToday() 给】—— 见下面那段:它必须是业务时区的
    // 今天。提醒页的 days_waiting 走的是另一条路(视图里的 CURRENT_DATE),
    // 两条路都绕开了"渲染进程所在时区的今天"这个陷阱,只是绕法不同。
    const [settingsRes, reconRes] = await Promise.all([
        supabase.from('finance_settings').select('locked_before, system_start_date').maybeSingle(),
        // ★【实测 508ms(2026-09-04,live)】★ 这不是一笔便宜的读数,而它落在
        //   一张【专程打开的】模块页上,不是所有人都会落地的首页 ——
        //   operations_now 那条「一次无界扫描由每个用户每次访问买单」的界限,
        //   正是因为它长在首页上。本页不是。这个数写在这里,因为
        //   AGENTS.md 的规矩是:写下来的成本必须是量出来的成本。
        // ★【as_of 必须是【业务时区】的今天】★ 第一版写的是 toISOString().slice(0,10),
        //   那是 UTC 的今天 —— 在 SGT 早上八点之前它【早一天】,而这支函数对早于今天的
        //   存货腿按名拒绝回答。实测:库里问 CURRENT_DATE 四条腿全平,而浏览器里
        //   渲染出来的同一页 reconRefusals = 2。理由整段写在 lib/format.ts。
        supabase.rpc('gl_control_reconciliation', { p_as_of: businessToday() }),
    ])

    const settings = mustOne(settingsRes, 'finance_settings') as
        | { locked_before: string | null; system_start_date: string | null }
        | null
    // 【RPC 也要过 mustOne】—— 一次失败的勾稽必须是失败,不能悄悄变成"没有腿"。
    const recon = mustOne(reconRes as never, 'gl_control_reconciliation') as unknown as Recon | null
    const sides = recon?.sides ?? []
    const ccy = recon?.base_currency ?? null

    const ar = sides.find((s) => s.side === 'ar')
    const ap = sides.find((s) => s.side === 'ap')

    // 净头寸 = 单据侧的应收 − 单据侧的应付。**两边取【同一侧】** ——
    // 一边取总账、一边取单据,得出的差额说的是勾稽,不是头寸。
    const netKnown = ar?.subledger_base != null && ap?.subledger_base != null
    const net = netKnown ? Number(ar!.subledger_base) - Number(ap!.subledger_base) : null

    // 【值里【不再】自带「截至」二字】<Figure> 的标签已经说了「时点 / As at」——
    // 两边都说,屏幕上读出来是「As at:as at 2026-09-04」(实测截图抓到的)。
    const asOfLabel = recon?.as_of ?? '—'

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <h1 className="text-2xl font-bold mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('nav.finance')}
            </h1>
            {/* 【一页要说出自己是什么】—— 尤其这一页,因为它替掉的那一版
                看起来像一个目录,而它不是目录。 */}
            <p className="text-sm mb-6 max-w-2xl" style={{ color: 'var(--brand-muted-text)' }}>
                {t('overview.intro')}
            </p>

            {/* ── ① 期间:它是下面每一个数的框 ───────────────────────────── */}
            <Figure
                title={t('financeOverview.periodTitle')}
                basis={{
                    asOf: asOfLabel,
                    source: t('financeOverview.periodSource'),
                    spans: t('financeOverview.periodSpans'),
                }}
                state={{ kind: 'ok' }}
                action={
                    <Link href="/finance/close" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('financeOverview.periodAction')}
                    </Link>
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {settings?.locked_before
                        ? t('financeOverview.lockedBefore', { date: settings.locked_before })
                        : /* 【没有封账日不是"封到了 0 年"】—— 说出来,别印一个空 */
                          t('financeOverview.lockedNone')}
                </p>
                {settings?.system_start_date && (
                    <p className="text-sm mt-1" style={{ color: 'var(--brand-muted-text)' }}>
                        {t('financeOverview.systemStart', { date: settings.system_start_date })}
                    </p>
                )}
            </Figure>

            {/* ── ② 总账 ↔ 明细账:本模块唯一一条【真】勾稽 ─────────────── */}
            {/* 【为什么是这一条,而不是"损益对得上资产负债"】gl_control_reconciliation
                的抬头写着理由:损益与资产负债【读同一份推导】,拿它们互相印证是
                OPS-17 抓到的那个病(两边一起错,旗子永远绿)。这一条的两侧
                【来自两套完全不同的表】:总账 vs 单据。它是这个模块里唯一一处
                "对不上就真的会红"的地方 —— 而没有任何一张子页面在说它。 */}
            <Figure
                title={t('financeOverview.reconTitle')}
                basis={{
                    asOf: asOfLabel,
                    source: t('financeOverview.reconSource'),
                    spans: t('financeOverview.reconSpans'),
                }}
                state={
                    sides.length === 0
                        ? { kind: 'unanswerable', why: t('financeOverview.reconNoSides') }
                        : { kind: 'ok' }
                }
            >
                <ul className="space-y-2">
                    {sides.map((s) => (
                        <li key={s.side} data-recon-side={s.side} className="text-sm">
                            <div className="flex flex-wrap items-baseline gap-x-2">
                                <span className="font-medium" style={{ color: 'var(--brand-text)' }}>
                                    {t('financeOverview.side.' + s.side)}
                                </span>
                                <span className="font-mono text-xs" style={{ color: 'var(--brand-muted-text)' }}>
                                    {s.control_account}
                                </span>
                            </div>
                            {/* ★【这一条腿答不上来时,不画 0】★ 函数自己回一个 refusal 码;
                                照答会返回一个自信的 0.00,而那正是它拒绝的东西。 */}
                            {s.refusal ? (
                                <p
                                    data-recon-refusal={s.refusal}
                                    className="mt-0.5 rounded px-2 py-1 text-xs"
                                    style={{ background: 'var(--brand-muted)', color: 'var(--brand-text)' }}
                                >
                                    {t('overview.unanswerable')} — {t('financeOverview.reconRefused')}
                                    <span className="ml-1 font-mono">({s.refusal})</span>
                                </p>
                            ) : (
                                <p className="mt-0.5" style={{ color: 'var(--brand-muted-text)' }}>
                                    {t('financeOverview.reconLine', {
                                        ledger: formatAmount(s.ledger_base, ccy),
                                        subledger: formatAmount(s.subledger_base, ccy),
                                    })}
                                    <br />
                                    {/* ★【未解释差额是这一条的判词,不是那三个分项】★
                                        分项是【穷举式声明】的,没有兜底桶 —— 所以任何
                                        没被分类的来源(一笔打进控制科目的手工分录)
                                        会原样留在这里,而它【动得开】。 */}
                                    <span
                                        className="font-mono"
                                        style={{
                                            color:
                                                Number(s.unexplained_base) === 0
                                                    ? 'var(--brand-muted-text)'
                                                    : 'var(--brand-destructive)',
                                        }}
                                    >
                                        {t('financeOverview.unexplained', {
                                            amount: formatAmount(s.unexplained_base, ccy),
                                        })}
                                    </span>
                                </p>
                            )}
                        </li>
                    ))}
                </ul>
            </Figure>

            {/* ── ③ 净头寸:两张页面各说一半的那个数 ───────────────────── */}
            <Figure
                title={t('financeOverview.netTitle')}
                basis={{
                    asOf: asOfLabel,
                    source: t('financeOverview.netSource'),
                    spans: t('financeOverview.netSpans'),
                }}
                state={
                    netKnown
                        ? { kind: 'ok' }
                        : { kind: 'unanswerable', why: t('financeOverview.netUnanswerable') }
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {t('financeOverview.netLine', {
                        ar: formatAmount(ar?.subledger_base ?? null, ccy),
                        ap: formatAmount(ap?.subledger_base ?? null, ccy),
                        net: formatAmount(net, ccy),
                    })}
                </p>
            </Figure>

            {/* 【月结在旁边,不在这一页上】—— 分界写在文件抬头。给一条路,不复制信号。 */}
            <p className="text-sm mt-6">
                <Link href="/finance/month-end" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                    {t('dashboard.monthEnd')}
                </Link>
                <span className="ml-2" style={{ color: 'var(--brand-muted-text)' }}>
                    {t('financeOverview.monthEndBoundary')}
                </span>
            </p>
        </div>
    )
}

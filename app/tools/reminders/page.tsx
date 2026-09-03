// app/tools/reminders/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-7 ①(2026-09-04)· 提醒 —— 工具的第五条,从首页整块搬来【并重画】
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么它离开首页 —— Tim 的裁定,不要重开】信号天生跨模块,拆回各模块就丢掉了
// "一眼看完所有该操心的事"这件事本身。给它一个自己的去处,人就是【想看的时候去看】,
// 而不是一登录就被推一脸 —— 那正是安静的首页得以成立的前提。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【界面是重画的,不是搬过来的 —— 这一段是它的全部理由】★★
// ════════════════════════════════════════════════════════════════════════════
// 【旧的样子,实测(2026-09-04)】34 支 + HR 一块 = 35 块【一样大】的牌子,
// 每块一个 3xl 的大数字。而线上 **34 支里只有 12 支有行**(42 件事),
// 另外 22 支是零。也就是说屏幕上三分之二的面积、以及三分之二的大号数字,
// 说的都是「没有事」。Tim 指的就是这个:**零不该和要动手的事一样重。**
//
// 【改法一:零不再是一块牌子。】只有【真的在等】的支画成一块;为零的支收进底下
//   一行,把名字全列出来。**零没有被藏掉,它被降了重量** —— 这两件事不一样,
//   而它们的差别就是"这一页有没有在骗人"。
//
// 【改法二:排序是【等了多久】,不是清单顺序。】最久的在最上面。
//   `days_waiting` 是视图自己算的(`CURRENT_DATE - item_date`),
//   **首页从来没有 select 过它** —— 于是这个数的基准是数据库的当天,
//   不是渲染进程所在时区的今天。
//
// 【改法三:块的大小跟着它的分量走。】一支等着 8 件事的块比等着 1 件的块高 ——
//   这正是"一样大"要治的病。
//
// ★【改法四:那个 3xl 的灰色「受限」没有了 —— CONV-0 ① 点名留给这一刀的活】★
//   app/components/ui/refusal.tsx 的抬头写着:实测有一处
//   `text-3xl font-bold text-gray-300` 的拒绝,「一个 text-xs 的药丸放进 3xl 的
//   位置读起来像一枚走丢的标签」,并注明「★ 本刀【不动它】★ …… 记在这里,
//   给转换到那一页的那一刀。」**那一处就是首页的 tileBox,而这一刀就是那一刀。**
//   处置:大号数字位整个不存在了,受限因此回到它该有的尺度 —— 一枚 <Refusal> 药丸,
//   与全站其余 40 处同一种画法。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【权限:三种状态,永远分得开】★★
// ════════════════════════════════════════════════════════════════════════════
// 【实测结论,写在这里因为它推翻了本刀立项时的怀疑】首页那些牌子【并没有】
// 不分权限地画给所有人。每一支被查两道:视图末尾那个 WHERE(无权 → 整支缺席)、
// 与本页的 allows()(无权 → 画「受限」)。逐角色实测见 docs/reminders-tool.md,
// 结论是十一个角色看见的支数从 0(employee)到 34(admin)各不相同。
// **所以本刀不是去补一个洞,是去【守住】一个已经对了的东西不在搬家途中弄丢。**
//
// 【一支一扇门,受限的支根本不开门】—— 首页那三条规矩原样继承:
//   ① 0 绝不冒充"你看不见":零画在「此刻没有在等」里,受限画在「需要权限」里,
//      两处【分开列、各自具名】,永远不合并。
//   ② 一块一扇门:受限的支不查、不给链接 —— 指向一扇必然拒绝的门的链接是一句谎话。
//   ③ 每个信号都过 mustRows:失败必须是失败,不能 `?? []` 成"已完成"。
//
// 【本页自己的判据【刻意】是恒真的】与 /tools/calendar 逐字同理:它没有自己的
//   权限模型,每一支按它【自己家】那个模块的可见性出现或不出现。本页不挡人,
//   挡人的是每一支。一个进得来却一支都看不见的人,会拿到一句【具名的话】,
//   不是一张白页(见下面 nothingVisible 那一支)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getMyPermissions } from '@/lib/permissions'
import { allows } from '@/lib/modules'
import { mustRows } from '@/lib/db-helpers'
import { REMINDERS, specFor, type OpsRow } from '@/lib/reminders'
import { metalLabelKey } from '@/app/pricing/metal-prices/options'
import { Refusal, RefusalBlock } from '@/app/components/ui/refusal'

// 一块里最多列几件;其余交给那一支自己的列表。
// 【8 而不是首页的 5】首页是路过,这一页是【专程来看的地方】—— 同一个数在两种
// 处境下不是同一个判断。上限仍然存在,因为一支【无界】的支会让这一页跟着它长。
const MAX_ITEMS_PER_ARM = 8

// HR 提醒按严重度分三档 —— 这个顺序【就是】它的分量,不要按字母排。
const SEVERITY_ORDER = ['expired', 'critical', 'warning'] as const

type HrAlertRow = {
    alert_type: string
    severity: string
    employee_id: string | null
    employee_code: string
    employee_name: string
    subject: string
    due_date: string | null
    days_remaining: number | null
}

export default async function RemindersPage() {
    const t = await getTranslations()
    const supabase = await createClient()
    const perms = await getMyPermissions()

    // ── 一支支先判权限,再决定要不要查 ────────────────────────────────────
    // 【顺序要紧】判据在查询【之前】。从空结果倒推"你没权限"正是 OPS-14/OPS-15
    // 反复在治的那个病:缺席与零在结果集里长得一模一样。
    const armAllowed = new Map(REMINDERS.map((r) => [r.itemType, allows(specFor(r), perms)]))
    const anyArmAllowed = [...armAllowed.values()].some(Boolean)
    const canHr = allows('module.hr.view', perms)

    // 【一次读回全部可见支】无权的支在视图那一侧就缺席了,所以读回来的行
    // 【一定】属于看得见的支;零由上面的 armAllowed 单独裁决。
    // 【days_waiting 现在取了】—— 见文件抬头改法二。
    const rows = anyArmAllowed
        ? (mustRows(
              await supabase
                  .from('operations_now')
                  .select('item_type, item_id, doc_kind, item_code, subject, item_date, days_waiting'),
              'operations_now'
          ) as OpsRow[])
        : []

    // ── ap_over_90 那一行的脸(PAYEE-1b,原样搬来)───────────────────────────
    // 视图那一支取的是 ap_open_items.supplier_name,而应付的往来对象可以是【员工】,
    // 员工行的 supplier_name 诚实地为 NULL —— 于是这一行连名字都没有。
    // 这里读同一个权威列(counterparty_name):同一个真源,晚一跳而已。
    // 【搬家没有改写它的返回条件】那条待办仍然挂在"下一支动 ap_over_90 本身的刀"上,
    // 原文在 lib/reminders.ts 那一支的注释里。
    const apIds = rows
        .filter((r) => r.item_type === 'ap_over_90')
        .map((r) => r.item_id)
        .filter(Boolean) as string[]
    const apPartyById = new Map<string, string>()
    if (apIds.length > 0) {
        const apRes = await supabase
            .from('ap_open_items')
            .select('doc_id, counterparty_name')
            .in('doc_id', apIds)
        for (const r of mustRows(apRes, 'ap_open_items counterparty') as {
            doc_id: string
            counterparty_name: string
        }[]) {
            apPartyById.set(r.doc_id, r.counterparty_name)
        }
    }

    // ── HR 提醒(hr_alerts 是它唯一的门)───────────────────────────────────
    // 【为什么它也在这一页上】它是【提醒】—— 准证到期、试用期届满、工资没录,
    // 一件都不是"库里的一个数",而全部是"有人得去办"。首页原本只给它一个【计数】
    // 牌子,而明细住在 /hr;CONV-7 ② 把 /hr 改成了 Overview(那一页答的是
    // "此刻是什么状态"),于是这份明细跟着它的性质走,搬到这里来。
    // 【受限时不开门】与每一支同一条规矩。
    const hrAlerts = canHr
        ? (mustRows(
              await supabase
                  .from('hr_alerts')
                  .select(
                      'alert_type, severity, employee_id, employee_code, employee_name, subject, due_date, days_remaining'
                  )
                  .order('due_date', { ascending: true }),
              'hr_alerts'
          ) as HrAlertRow[])
        : []

    // ── 一行的「脸」(ASY-P2 / PAYEE-1b,原样搬来)────────────────────────
    function subjectText(row: OpsRow): string | null {
        if (row.item_type === 'ap_over_90') {
            return (row.item_id ? apPartyById.get(row.item_id) : null) ?? row.subject
        }
        if (row.item_type !== 'awaiting_assay') return row.subject
        if (!row.subject) return null
        const names = row.subject
            .split(',')
            .map((c) => c.trim())
            .filter(Boolean)
            .map((c) => (metalLabelKey(c) ? t('metals.' + c) : c))
        if (names.length === 0) return null
        return t('dashboard.awaitingMetals', { metals: names.join(', ') })
    }

    const byType = new Map<string, OpsRow[]>()
    for (const r of rows) {
        const list = byType.get(r.item_type)
        if (list) list.push(r)
        else byType.set(r.item_type, [r])
    }

    // ── 三堆:在等 / 为零 / 受限 ───────────────────────────────────────────
    // 【为零与受限【分成两堆】,而不是一堆加一个小标记】这是 D5 在这一页上的样子:
    // 「我看得见,它此刻没有事」与「我看不见」是两句不同的话,合成一堆就等于
    // 让读者自己去分辨 —— 而这一页存在的意义之一就是不要求他分辨。
    const waiting = REMINDERS.filter((r) => armAllowed.get(r.itemType) && (byType.get(r.itemType)?.length ?? 0) > 0)
        .map((r) => {
            const mine = [...(byType.get(r.itemType) ?? [])].sort((a, b) => b.days_waiting - a.days_waiting)
            return { reminder: r, items: mine, oldest: mine[0].days_waiting }
        })
        // 【等得最久的支排最前】—— 这一页的顺序【就是】它的判断
        .sort((a, b) => b.oldest - a.oldest || b.items.length - a.items.length)

    const quiet = REMINDERS.filter((r) => armAllowed.get(r.itemType) && (byType.get(r.itemType)?.length ?? 0) === 0)
    const restricted = REMINDERS.filter((r) => !armAllowed.get(r.itemType))

    const waitingItems = waiting.reduce((n, w) => n + w.items.length, 0)

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <h1 className="text-2xl font-bold mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('reminders.title')}
            </h1>
            {/* 【这一页在说自己是什么】—— 一页不解释自己的清单会被当成"还没加载完"。 */}
            <p className="text-sm mb-1 max-w-2xl" style={{ color: 'var(--brand-muted-text)' }}>
                {t('reminders.intro')}
            </p>
            {/* 【出处:一个数要说得出它的基准】与 ChartCard 的 basis 同一条规矩。
                「等了几天」由数据库按【它的】当天算,不是浏览器所在时区的今天。 */}
            <p className="text-xs mb-6" style={{ color: 'var(--brand-muted-text)' }}>
                {t('reminders.basis')}
            </p>

            {/* ★【一支都看不见的人拿到一句具名的话,不是一张白页】★(OPS-15 同形)
                本页判据恒真,所以零权限的读者【进得来】。进得来而什么都没有,
                与"系统坏了"在屏幕上必须分得开。 */}
            {!anyArmAllowed && !canHr && (
                <RefusalBlock
                    data-reminders-nothing-visible="1"
                    statement={t('reminders.nothingVisible')}
                    hint={t('reminders.nothingVisibleHint')}
                    className="max-w-2xl mb-6"
                />
            )}

            {/* ══ 正在等 ═══════════════════════════════════════════════════ */}
            {waiting.length > 0 && (
                <section className="mb-8">
                    <h2 className="text-lg font-semibold mb-1" style={{ color: 'var(--brand-text)' }}>
                        {t('reminders.sectionWaiting')}
                    </h2>
                    <p className="text-xs mb-4" style={{ color: 'var(--brand-muted-text)' }}>
                        {t('reminders.waitingSummary', { items: String(waitingItems), arms: String(waiting.length) })}
                    </p>

                    <ul className="space-y-3">
                        {waiting.map(({ reminder, items, oldest }) => {
                            const shown = items.slice(0, MAX_ITEMS_PER_ARM)
                            const rest = items.length - shown.length
                            return (
                                <li
                                    key={reminder.itemType}
                                    data-reminder-arm={reminder.itemType}
                                    className="rounded-[var(--brand-radius)] border p-3 sm:p-4"
                                    style={{
                                        borderColor: 'var(--brand-border)',
                                        background: 'var(--brand-surface)',
                                    }}
                                >
                                    {/* 【标题行:名字 · 件数 · 等了多久】三样都不是装饰 ——
                                        件数说"有多少",天数说"有多急",而名字说"是什么"。
                                        手机上它是两行(flex-wrap),不横向滚。 */}
                                    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1 mb-2">
                                        <Link
                                            href={reminder.href}
                                            className="font-semibold hover:underline"
                                            style={{ color: 'var(--brand-text)' }}
                                        >
                                            {t('dashboard.item.' + reminder.itemType)}
                                        </Link>
                                        <span className="font-mono text-sm" style={{ color: 'var(--brand-text)' }}>
                                            {t('reminders.count', { n: String(items.length) })}
                                        </span>
                                        <span className="text-xs" style={{ color: 'var(--brand-muted-text)' }}>
                                            {t('reminders.oldest', { n: String(oldest) })}
                                        </span>
                                    </div>

                                    <ul className="space-y-1">
                                        {shown.map((row, i) => {
                                            const href = reminder.itemHref(row)
                                            const subject = subjectText(row)
                                            return (
                                                <li
                                                    key={`${reminder.itemType}-${i}`}
                                                    /* 【手机:两列会挤,所以是两行】编号与天数一行,
                                                       说明另起一行 —— 390px 上不需要横向滚动。 */
                                                    className="flex flex-wrap items-baseline gap-x-2 text-sm"
                                                >
                                                    {/* 认不出门牌的行【不给链接】,而不是猜一个:
                                                        一个合法的 uuid 指错了表,打开的是别人的单据,
                                                        而且不会报错。 */}
                                                    {href ? (
                                                        <Link
                                                            href={href}
                                                            className="font-mono hover:underline"
                                                            style={{ color: 'var(--brand-ocean-fill)' }}
                                                        >
                                                            {row.item_code}
                                                        </Link>
                                                    ) : (
                                                        <span
                                                            className="font-mono"
                                                            style={{ color: 'var(--brand-text)' }}
                                                        >
                                                            {row.item_code}
                                                        </span>
                                                    )}
                                                    <span
                                                        className="text-xs font-mono"
                                                        style={{ color: 'var(--brand-muted-text)' }}
                                                    >
                                                        {t('reminders.days', { n: String(row.days_waiting) })}
                                                    </span>
                                                    {subject && (
                                                        <span
                                                            className="basis-full sm:basis-auto text-xs"
                                                            style={{ color: 'var(--brand-muted-text)' }}
                                                        >
                                                            {subject}
                                                        </span>
                                                    )}
                                                </li>
                                            )
                                        })}
                                        {rest > 0 && (
                                            <li className="text-xs pt-1">
                                                <Link
                                                    href={reminder.href}
                                                    className="hover:underline"
                                                    style={{ color: 'var(--brand-muted-text)' }}
                                                >
                                                    {t('dashboard.andMore', { n: String(rest) })}
                                                </Link>
                                            </li>
                                        )}
                                    </ul>
                                </li>
                            )
                        })}
                    </ul>
                </section>
            )}

            {/* ══ HR 提醒 ══════════════════════════════════════════════════ */}
            {/* 【它自成一节,因为它有一个别的支都没有的维度:严重度】
                硬把它塞进上面那份按天数排的清单,就要把 expired / critical / warning
                压成一个天数 —— 而"准证已经过期"与"证书 60 天后到期"不是同一件事的
                两个刻度。EQP-2c 那句「两支而不是一支带等级」讲的是同一条道理,
                方向相反:hr_alerts 的等级【在库里】就是一列,不该在这里被抹平。 */}
            {canHr && hrAlerts.length > 0 && (
                <section className="mb-8">
                    <h2 className="text-lg font-semibold mb-1" style={{ color: 'var(--brand-text)' }}>
                        {t('reminders.hrSection')}
                    </h2>
                    <p className="text-xs mb-4" style={{ color: 'var(--brand-muted-text)' }}>
                        {t('reminders.hrBasis')}
                    </p>
                    <ul className="space-y-3">
                        {SEVERITY_ORDER.map((sev) => {
                            const group = hrAlerts.filter((a) => a.severity === sev)
                            if (group.length === 0) return null
                            return (
                                <li
                                    key={sev}
                                    data-reminder-hr-severity={sev}
                                    className="rounded-[var(--brand-radius)] border p-3 sm:p-4"
                                    style={{
                                        borderColor:
                                            sev === 'expired'
                                                ? 'var(--brand-destructive)'
                                                : 'var(--brand-border)',
                                        background: 'var(--brand-surface)',
                                    }}
                                >
                                    <div className="flex flex-wrap items-baseline gap-x-3 mb-2">
                                        <span className="font-semibold" style={{ color: 'var(--brand-text)' }}>
                                            {t('hr.severity.' + sev)}
                                        </span>
                                        <span className="font-mono text-sm" style={{ color: 'var(--brand-text)' }}>
                                            {t('reminders.count', { n: String(group.length) })}
                                        </span>
                                    </div>
                                    <ul className="space-y-1">
                                        {group.map((a, i) => (
                                            <li
                                                key={`${sev}-${i}`}
                                                className="flex flex-wrap items-baseline gap-x-2 text-sm"
                                            >
                                                {a.employee_id ? (
                                                    <Link
                                                        href={`/hr/employees/${a.employee_id}`}
                                                        className="font-mono hover:underline"
                                                        style={{ color: 'var(--brand-ocean-fill)' }}
                                                    >
                                                        {a.employee_code}
                                                    </Link>
                                                ) : (
                                                    <span className="font-mono" style={{ color: 'var(--brand-text)' }}>
                                                        {a.employee_code}
                                                    </span>
                                                )}
                                                <span style={{ color: 'var(--brand-text)' }}>{a.employee_name}</span>
                                                <span
                                                    className="basis-full sm:basis-auto text-xs"
                                                    style={{ color: 'var(--brand-muted-text)' }}
                                                >
                                                    {t('hr.alertType.' + a.alert_type)}
                                                    {/* 【days_remaining 可以为 null 而那不是零】
                                                        salary_not_set 没有期限 —— 印一个 0 天
                                                        就是把"没有期限"说成"今天到期"。 */}
                                                    {a.days_remaining !== null && (
                                                        <>
                                                            {' · '}
                                                            {a.days_remaining < 0
                                                                ? t('hr.overdueDays', { n: String(-a.days_remaining) })
                                                                : t('hr.daysRemaining', { n: String(a.days_remaining) })}
                                                        </>
                                                    )}
                                                </span>
                                            </li>
                                        ))}
                                    </ul>
                                </li>
                            )
                        })}
                    </ul>
                </section>
            )}

            {/* ══ 此刻没有在等(零)═══════════════════════════════════════ */}
            {/* ★【零【没有】被藏起来 —— 它被降了重量,而这两件事不一样】★
                名字全列出来,所以"这一支我看得见、而它此刻是零"仍然是一句
                读得到的话。它只是不再占一块牌子的面积和一个 3xl 的数字。 */}
            {quiet.length > 0 && (
                <section className="mb-8" data-reminders-quiet={quiet.length}>
                    <h2 className="text-sm font-semibold mb-1" style={{ color: 'var(--brand-text)' }}>
                        {t('reminders.sectionQuiet')}
                        <span className="ml-2 font-mono font-normal">
                            {t('reminders.count', { n: String(quiet.length) })}
                        </span>
                    </h2>
                    <p className="text-xs mb-2" style={{ color: 'var(--brand-muted-text)' }}>
                        {t('reminders.quietHint')}
                    </p>
                    <p className="text-xs leading-6" style={{ color: 'var(--brand-muted-text)' }}>
                        {quiet.map((r, i) => (
                            <span key={r.itemType}>
                                {i > 0 && <span aria-hidden> · </span>}
                                <Link href={r.href} className="hover:underline">
                                    {t('dashboard.item.' + r.itemType)}
                                </Link>
                            </span>
                        ))}
                    </p>
                </section>
            )}

            {/* ══ 需要其它模块的权限(受限)══════════════════════════════ */}
            {/* ★【它与上面那一节【永远分开】】★ 零与受限合成一堆,就是把
                "你看得见、此刻没事"与"你看不见"说成同一句话 —— 那正是 OPS-14
                与 D5 反复在治的那个病。这里连标题、连措辞、连颜色都不一样。
                【不给链接】指向一扇必然拒绝的门的链接是一句谎话。 */}
            {restricted.length > 0 && (
                <section className="mb-8" data-reminders-restricted={restricted.length}>
                    <h2 className="text-sm font-semibold mb-1" style={{ color: 'var(--brand-text)' }}>
                        {t('reminders.sectionRestricted')}
                        <span className="ml-2 font-mono font-normal">
                            {t('reminders.count', { n: String(restricted.length) })}
                        </span>
                    </h2>
                    <p className="text-xs mb-2" style={{ color: 'var(--brand-muted-text)' }}>
                        {t('reminders.restrictedHint')}
                    </p>
                    <div className="flex flex-wrap gap-1.5">
                        {restricted.map((r) => (
                            // 【药丸里带着【具名的权限码】】—— 「受限」告诉人有东西看不见,
                            // 权限码告诉他【去要什么】。ChartCard 的 restricted 分支同形。
                            <Refusal key={r.itemType} why={`${t('dashboard.restrictedHint')}(${r.permission})`}>
                                {t('dashboard.item.' + r.itemType)}
                            </Refusal>
                        ))}
                        {!canHr && (
                            <Refusal why={`${t('dashboard.restrictedHint')}(module.hr.view)`}>
                                {t('reminders.hrSection')}
                            </Refusal>
                        )}
                    </div>
                </section>
            )}

            {/* ★【全都安静的时候要【说出来】】★ 一张只有标题的页面读起来像没加载完。 */}
            {waiting.length === 0 && hrAlerts.length === 0 && (anyArmAllowed || canHr) && (
                <p
                    data-reminders-all-quiet="1"
                    className="rounded-[var(--brand-radius)] border px-3 py-2 text-sm"
                    style={{
                        borderColor: 'var(--brand-border)',
                        background: 'var(--brand-muted)',
                        color: 'var(--brand-muted-text)',
                    }}
                >
                    {t('reminders.allQuiet')}
                </p>
            )}
        </div>
    )
}

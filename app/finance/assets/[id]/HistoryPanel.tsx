// app/finance/assets/[id]/HistoryPanel.tsx
// FA-HIST-1:这台机器【被谁、在什么时候、把什么改成了什么】。
//
// 【为什么这一块必须存在】Tim 的裁定 R3:**一份只活在数据库里的留痕不算做到。**
// 影子表 `fixed_asset_history` 自 FA-HIST-1 起记住了每一次写入,而一个操作员
// 要能读到它 —— 否则它与 B3 交回时那个「没有任何地方记得」的状态,
// 在屏幕上是一模一样的。
//
// ★【这一块【不硬编码】任何一个列名,而那是设计,不是省事】★
//   一行留痕带着 `changed_columns`(这一次动了哪几列),屏幕照着它去取
//   `old_<列>` / `new_<列>` 两格。于是:
//     · 触发器那侧【不提列名】(fixtures/120 F5(d) 的硬约束,见迁移抬头);
//     · 屏幕这侧【也不提】—— 明天给 fixed_assets 加第 24 列,影子表配上一对,
//       i18n 配上一条文案,这一块**一个字都不用改**就会把它画出来。
//   ☞ 两侧都由【数据】决定画什么,不由【代码里的一份清单】决定。
//
// 【文案的真源在数据库】`assets.history.type.*` 由 change_type 的 CHECK 现读,
// `assets.history.field.*` 由影子表的 old_* 列现读 —— 两条都登记在
// scripts/check-i18n.mjs 里。少配一条不会静默:i18n 体检当场点名。
//
// 【每一处"没有值"都要说清是哪一种】(本页抬头那条的推广)
//   · 一格的旧值/新值为 NULL → 印【未填】,不印空白;
//   · 没有任何留痕 → 印一句【具名的空状态】,并说清留痕是从哪一天起算的 ——
//     「这台机器没被改过」与「那一天之前没有人在记」是两件完全不同的事,
//     而线上那两张卡正好属于后者(FA-HIST-1 不回填,也不发明历史)。
//   · 谁改的 → 走 ActorName 那一份取名器(本仓库只有一份),
//     而「没有登录会话」那一种**自己有名字**,不借用它的「未记录」。
import { getTranslations } from '@/lib/i18n/server'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { formatAmount } from '@/lib/format'
import ActorName, { type ActorNameMap } from '@/app/components/ActorName'

/** ★ 本页只画最近 50 条 —— 超出的部分要【说出来】,不许沉默地截断。 */
export const HISTORY_LIMIT = 50

/**
 * ★★【留痕从哪一天起算 —— 这个日子是【量】出来的,不是写在计划里的】★★
 * 取自 db/migration-windows.tsv 里本刀那一行的 applied_at(迁移真正落到线上的时刻),
 * 而不是提前写死的一个日期。Tim 在 Round 1 的回复里点名了这一条:
 * **一个写在迁移之前的日期,是在替一件还没发生的事签字。**
 */
export const HISTORY_SINCE = '2026-09-20'

/** 这几列是【钱】,按本位币印;其余按类型印(日期走 formatDate,其余原样)。 */
const MONEY_COLUMNS = new Set([
    'cost_base', 'cost_ccy', 'residual_base', 'disposal_proceeds_base',
])

export type HistoryRow = {
    id: string
    change_type: string
    changed_columns: string[]
    changed_at: string
    changed_by: string | null
    changed_by_kind: string
} & Record<string, unknown>

export default async function HistoryPanel({
    rows,
    total,
    names,
    baseCurrency,
    locale,
}: {
    rows: HistoryRow[]
    /** 这台机器一共有多少条 —— 用来说出被截掉了多少,而不是沉默。 */
    total: number
    names: ActorNameMap
    baseCurrency: string
    locale: string
}) {
    const t = await getTranslations()

    // 一格值怎么印。**不认列名,只认值的形状** —— 除了那一小撮钱。
    const show = (column: string, value: unknown): string => {
        if (value === null || value === undefined || value === '') return t('assets.history.emptyValue')
        if (MONEY_COLUMNS.has(column)) return formatAmount(Number(value), baseCurrency)
        if (typeof value === 'number') return String(value)
        const s = String(value)
        // 日期列(…_date)印成本地格式;时间戳(…_at)走审计时刻那一份。
        if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return formatDate(s, locale)
        return s
    }

    return (
        <div className="border border-gray-200 rounded p-4 mb-4">
            <h2 className="mb-2">{t('assets.history.title')}</h2>

            {rows.length === 0 ? (
                // ★ 具名空状态 —— 「没改过」与「那时候没人在记」不是一件事。
                <>
                    <p className="text-sm">{t('assets.history.empty')}</p>
                    <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">
                        {t('assets.history.emptySince', { date: formatDate(HISTORY_SINCE, locale) })}
                    </p>
                </>
            ) : (
                <>
                    <ul className="text-sm space-y-2">
                        {rows.map((h) => (
                            <li key={h.id} className="flex flex-col gap-0.5">
                                <span className="flex flex-wrap items-baseline gap-2">
                                    <span className="text-[color:var(--brand-muted-text)] text-xs">
                                        {formatAuditStamp(h.changed_at)}
                                    </span>
                                    <span>{t('assets.history.type.' + h.change_type)}</span>
                                    <span className="text-[color:var(--brand-muted-text)] text-xs">
                                        {/* 没有登录会话的那一种【自己有名字】,不借 ActorName 的「未记录」——
                                            那句话的意思是"没人填过",而这一行记下来的是一件真事。 */}
                                        {h.changed_by_kind === 'no_session' ? (
                                            <span>{t('assets.history.noSession')}</span>
                                        ) : (
                                            <ActorName userId={h.changed_by} names={names} />
                                        )}
                                    </span>
                                </span>

                                {/* 'created':画一句【出生摘要】,不画 23 行 diff ——
                                    整行都是新的,逐列列出来读起来像"一次性改了 23 个地方"。 */}
                                {h.change_type === 'created' ? (
                                    <span className="text-xs text-[color:var(--brand-muted-text)] pl-1">
                                        {show('code', h.new_code)} · {show('description', h.new_description)}
                                    </span>
                                ) : (
                                    <ul className="pl-1 text-xs space-y-0.5">
                                        {h.changed_columns.map((c) => (
                                            <li key={c} className="text-[color:var(--brand-muted-text)]">
                                                <span className="mr-1">{t('assets.history.field.' + c)}:</span>
                                                <span>{show(c, h['old_' + c])}</span>
                                                <span className="mx-1">→</span>
                                                <span className="text-[color:var(--brand-text)]">{show(c, h['new_' + c])}</span>
                                            </li>
                                        ))}
                                    </ul>
                                )}
                            </li>
                        ))}
                    </ul>

                    {/* ★ 截断要【说出来】—— 一份沉默地只给 50 条的清单,读起来像"总共就这些"。 */}
                    {total > rows.length && (
                        <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">
                            {t('assets.history.truncated', { shown: rows.length, total })}
                        </p>
                    )}
                    <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">
                        {t('assets.history.sinceNote', { date: formatDate(HISTORY_SINCE, locale) })}
                    </p>
                </>
            )}
        </div>
    )
}

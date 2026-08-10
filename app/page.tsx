import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getMyPermissions } from '@/lib/permissions'
import { getVisibleModules } from '@/lib/moduleAccess'
import { mustCount, mustRows } from '@/lib/db-helpers'

// OPS-18(Phase 6):首页从【链接目录】换成【运营看板】—— 正在等人处理的事,
// 一事一牌。目录的职责由导航条独自承担;两个首页并存的话,人落地的是目录那个,
// 而它已经是错的。
//
// 【本页不算业务账】每块牌子的数字来自 db 的 operations_now(一个 UNION,一种等待
// 状态一支,hr_alerts 的形状);本页只数行、取最早日期 —— 那是呈现,不是口径。
//
// 【规矩一:0 绝不冒充"你看不见"】operations_now 对无权读者【整支缺席】,于是
// "没有行"有两种含义。本页先查权限再渲染每块牌子:无权 → 「受限」(common.restricted,
// 与 MaskedValue 同一词),绝不显示 0。这是仪表盘最容易犯、且 gate 查不出的错。
//
// 【规矩二:一块牌子一扇门】每块牌子恰好读一个来源;受限的牌子【根本不开门】。
// 绝不"先试 A,空了再试 B,谁有行画谁"—— 在这里空集是权限答复,回退等于把数字
// 从另一扇门里递出去。
//
// 【规矩三:每个信号都过 mustRows/mustCount】/finance/month-end 的先例:七个信号
// 原本全是 `?? []`,任何一次查询失败都渲染成"已完成"。仪表盘是同一风险乘以牌数。
//
// 【支的清单是规格,不是这里的实现细节】docs/dashboard-arm-inventory.md 写着每一支
// 是什么意思、挂哪个权限码、界在哪里,以及【哪些支被考虑过又被排除、为什么】。
// 加一块牌子 = 同时改那份清单、db/views/operations_now.sql 与下面的 TILES —— 三处
// 的 permission 必须同码(视图按它裁决缺席,本页按它裁决「受限」,fixture 30 钉住)。
// 【批次毛利在这里了】(MAR-1)。它跨两个模块,而支的权限一直只有一个码 ——
// 现在多了 permissionAny(任意持有其一),与视图的 arm_permission_any 同义,
// fixture 45 钉住两侧对同一个人给出同一个答案。合成一个新权限码那条路被否掉了:
// 那会成为"谁能看毛利"的第二份定义,与 batch_margin 自己的谓词必然漂开。

// 牌子清单:itemType 对应 operations_now 的支;permission 与视图里那一支声明的
// 权限码【同码】(视图按它裁决缺席,本页按它裁决「受限」—— 两边必须一致)。
const TILES = [
    { itemType: 'awaiting_assay', permission: 'module.inbound.view', href: '/inbound' },
    { itemType: 'assay_unapplied', permission: 'module.inbound.view', href: '/inbound' },
    { itemType: 'batch_unpriced', permission: 'module.inbound.view', href: '/inbound' },
    { itemType: 'allocation_stale', permission: 'module.processing.view', href: '/processing' },
    { itemType: 'qualification_expiring', permission: 'module.suppliers.view', href: '/suppliers' },
    { itemType: 'qualification_missing', permission: 'module.suppliers.view', href: '/suppliers' },
    { itemType: 'po_awaiting_receipt', permission: 'module.purchasing.view', href: '/purchasing/orders' },
    { itemType: 'stocktake_open', permission: 'module.stocktakes.view', href: '/stocktakes' },
    { itemType: 'credit_over_limit', permission: 'module.customers.view', href: '/customers' },
    // 跨两个模块的那一支:必须有 data.view_prices,且 finance / processing 之一。
    // 只收 no_unit_cost(分摊一次就清掉);no_run 事后无从补救,放上来就是关不掉的灯。
    { itemType: 'margin_cost_not_allocated', permission: 'data.view_prices',
      permissionAny: ['module.finance.view', 'module.processing.view'], href: '/margin' },
    { itemType: 'output_unsold_aging', permission: 'module.output.view', href: '/output' },
    { itemType: 'leave_pending', permission: 'module.hr.view', href: '/hr/leave' },
    { itemType: 'claim_pending', permission: 'module.hr.view', href: '/hr/claims' },
    { itemType: 'review_submitted', permission: 'module.hr.view', href: '/hr/reviews' },
    { itemType: 'invoice_overdue', permission: 'module.finance.view', href: '/finance/invoices' },
    { itemType: 'ar_over_90', permission: 'module.finance.view', href: '/finance/receivables' },
    { itemType: 'ap_over_90', permission: 'module.finance.view', href: '/finance/payables' },
    { itemType: 'fx_rate_gap', permission: 'module.finance.view', href: '/finance/fx' },
    { itemType: 'bank_unmatched', permission: 'module.finance.view', href: '/finance/bank' },
] as const

// 「我的」两张卡片:不受模块把关,人人可见 —— 理由与顺序同 NavLinks 的 SELF_ITEMS
// (OPS-15:employee 角色的全部产品恰恰是这两页,首页必须给入口)。
const SELF_CARDS = [
    { href: '/my-reviews', titleKey: 'home.myReviewsTitle', descKey: 'home.myReviewsDesc' },
    { href: '/me', titleKey: 'home.meTitle', descKey: 'home.meDesc' },
]

type OpsRow = { item_type: string; item_code: string; item_date: string }

export default async function Home() {
    const t = await getTranslations()
    const supabase = await createClient()
    const perms = await getMyPermissions()
    const visible = await getVisibleModules()

    // 一次读回全部可见支;无权的支缺席,可见支的零是真的零(权限已单独查过)
    const rows = mustRows(
        await supabase.from('operations_now').select('item_type, item_code, item_date'),
        'operations_now'
    ) as OpsRow[]

    // HR 待办牌(hr_alerts 是它唯一的门)—— 受限时【不开门】,不是"查了当没查"
    const canHr = perms.includes('module.hr.view')
    let hrAlertCount: number | null = null
    if (canHr) {
        hrAlertCount = mustCount(
            await supabase.from('hr_alerts').select('alert_type', { count: 'exact', head: true }),
            'hr_alerts'
        )
    }

    const byType = new Map<string, OpsRow[]>()
    for (const r of rows) {
        const list = byType.get(r.item_type)
        if (list) list.push(r)
        else byType.set(r.item_type, [r])
    }

    const tileBox = (opts: {
        key: string
        title: string
        href: string
        allowed: boolean
        count: number | null
        oldest?: string | null
    }) => {
        const inner = (
            <>
                <p className="text-sm text-gray-600 mb-1">{opts.title}</p>
                {opts.allowed ? (
                    <>
                        <p
                            className={
                                'text-3xl font-bold font-mono ' +
                                ((opts.count ?? 0) > 0 ? 'text-amber-600' : 'text-gray-400')
                            }
                        >
                            {opts.count}
                        </p>
                        <p className="text-xs text-gray-500 mt-1 h-4">
                            {(opts.count ?? 0) > 0 && opts.oldest
                                ? t('dashboard.oldestSince', { date: opts.oldest })
                                : ' '}
                        </p>
                    </>
                ) : (
                    <>
                        {/* 受限,不是零 —— 与 MaskedValue 的「受限」同一个词。不给链接:
                            指向一扇必然拒绝的门的链接是一句谎话。 */}
                        <p className="text-3xl font-bold text-gray-300">{t('common.restricted')}</p>
                        <p className="text-xs text-gray-400 mt-1 h-4">{t('dashboard.restrictedHint')}</p>
                    </>
                )}
            </>
        )
        const cls = 'border rounded-lg p-4 block ' +
            (opts.allowed
                ? 'border-gray-300 hover:bg-gray-50 hover:border-gray-400 transition'
                : 'border-gray-200 bg-gray-50')
        return opts.allowed ? (
            <Link key={opts.key} href={opts.href} className={cls}>
                {inner}
            </Link>
        ) : (
            <div key={opts.key} className={cls}>
                {inner}
            </div>
        )
    }

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-2">Evoltrya OS</h1>
            <p className="text-gray-600 mb-8">{t('home.subtitle')}</p>

            {/* 零模块权限时说出来(OPS-15)—— 否则满屏「受限」与"系统坏了"分不开 */}
            {visible.length === 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded max-w-2xl mb-8">
                    <p className="font-medium">{t('home.noModules')}</p>
                    <p className="text-sm mt-1">{t('home.noModulesHint')}</p>
                </div>
            )}

            <h2 className="text-lg font-semibold mb-4">{t('dashboard.sectionNow')}</h2>
            <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 mb-8">
                {TILES.map((tile) => {
                    // MAR-1:支级谓词 —— permission 必须全有,permissionAny 任意其一。
                    // 与视图的 arm_permission_any 同义(fixture 45 钉两侧一致)。
                    const anyCodes = 'permissionAny' in tile ? (tile.permissionAny as readonly string[]) : null
                    const allowed = perms.includes(tile.permission)
                        && (anyCodes === null || anyCodes.some((c) => perms.includes(c)))
                    const mine = byType.get(tile.itemType) ?? []
                    const oldest = mine.length
                        ? mine.reduce((a, r) => (r.item_date < a ? r.item_date : a), mine[0].item_date)
                        : null
                    return tileBox({
                        key: tile.itemType,
                        title: t('dashboard.item.' + tile.itemType),
                        href: tile.href,
                        allowed,
                        count: allowed ? mine.length : null,
                        oldest,
                    })
                })}
                {tileBox({
                    key: 'hr_alerts',
                    title: t('dashboard.hrAlerts'),
                    href: '/hr',
                    allowed: canHr,
                    count: hrAlertCount,
                })}
            </div>

            {/* 月结枢纽入口:纯链接、不复制信号(信号归 /finance/month-end 自己)。
                没有数字可遮,所以无权时按 OPS-15 的方式【不渲染】而不是画「受限」。 */}
            {perms.includes('module.finance.view') && (
                <div className="mb-8">
                    <Link
                        href="/finance/month-end"
                        className="inline-block border border-gray-300 rounded-lg px-4 py-3 hover:bg-gray-50 hover:border-gray-400 transition"
                    >
                        <span className="font-semibold">{t('dashboard.monthEnd')}</span>
                        <span className="text-sm text-gray-600 ml-2">{t('dashboard.monthEndDesc')}</span>
                    </Link>
                </div>
            )}

            {/* 「我的」—— 无条件渲染,见 SELF_CARDS 的注释 */}
            <div className="mb-8">
                <h2 className="text-lg font-semibold mb-4">{t('home.sectionSelf')}</h2>
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                    {SELF_CARDS.map((card) => (
                        <Link
                            key={card.href}
                            href={card.href}
                            className="border border-gray-300 rounded-lg p-6 hover:bg-gray-50 hover:border-gray-400 transition block"
                        >
                            <h3 className="font-semibold text-lg mb-1">{t(card.titleKey)}</h3>
                            <p className="text-sm text-gray-600">{t(card.descKey)}</p>
                        </Link>
                    ))}
                </div>
            </div>
        </div>
    )
}

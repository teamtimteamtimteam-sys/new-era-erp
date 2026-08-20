import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getMyPermissions } from '@/lib/permissions'
import { getVisibleModules } from '@/lib/moduleAccess'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { metalLabelKey } from '@/app/metal-prices/options'

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
//
// 【LINKS-1:itemHref —— 一件事一扇门】href 是那一支的列表(牌子标题指向它),
// itemHref 是【这一件事自己】的门牌。判据只有一条,写在
// docs/dashboard-arm-inventory.md:【补救动作在不在那张页面上】。URL 里有没有
// /edit 不是信号 —— /inbound/[id]/edit 与 /output/[id]/edit 是单据主页(化验、
// 计价、台账、销售面板都在上面),/suppliers/[id]/edit 才接近一张纯表单,而它
// 恰好载着 CompliancePanel(续证就是补救),所以它也成立。
//
// 【用 item_id,不用按码搜索】按码搜今天能用只因为码唯一、数据少;那是一次搜索,
// 不是一条链接。fx_rate_gap 是唯一没有 item_id 的支 —— 它的主体是一条【不存在的】
// 牌价行,所以它指向按币种过滤的列表(诚实过滤的列表,不是按码搜索)。
const TILES = [
    { itemType: 'awaiting_assay', permission: 'module.inbound.view', href: '/inbound',
      itemHref: (r: OpsRow) => `/inbound/${r.item_id}/edit` },
    { itemType: 'assay_unapplied', permission: 'module.inbound.view', href: '/inbound',
      itemHref: (r: OpsRow) => `/inbound/${r.item_id}/edit` },
    { itemType: 'batch_unpriced', permission: 'module.inbound.view', href: '/inbound',
      itemHref: (r: OpsRow) => `/inbound/${r.item_id}/edit` },
    { itemType: 'allocation_stale', permission: 'module.processing.view', href: '/processing',
      itemHref: (r: OpsRow) => `/processing/${r.item_id}` },
    { itemType: 'qualification_expiring', permission: 'module.suppliers.view', href: '/suppliers',
      itemHref: (r: OpsRow) => `/suppliers/${r.item_id}/edit` },
    { itemType: 'qualification_missing', permission: 'module.suppliers.view', href: '/suppliers',
      itemHref: (r: OpsRow) => `/suppliers/${r.item_id}/edit` },
    { itemType: 'po_awaiting_receipt', permission: 'module.purchasing.view', href: '/purchasing/orders',
      itemHref: (r: OpsRow) => `/purchasing/orders/${r.item_id}` },
    { itemType: 'stocktake_open', permission: 'module.stocktakes.view', href: '/stocktakes',
      itemHref: (r: OpsRow) => `/stocktakes/${r.item_id}` },
    // 信用支指向【只读的信用仓位页】,不是客户编辑表单 —— 改限额会让告警安静,
    // 而敞口一分未动(SAL-B6 分界的理由)。
    { itemType: 'credit_over_limit', permission: 'module.customers.view', href: '/customers',
      itemHref: (r: OpsRow) => `/customers/${r.item_id}` },
    // 跨两个模块的那一支:必须有 data.view_prices,且 finance / processing 之一。
    // 只收 no_unit_cost(分摊一次就清掉);no_run 事后无从补救,放上来就是关不掉的灯。
    // 【item_id 是加工单,不是批次】支报的是批次,而补救是给【加工单】分摊成本,
    // 分摊按钮在加工单页上 —— 门牌跟着补救走。
    { itemType: 'margin_cost_not_allocated', permission: 'data.view_prices',
      permissionAny: ['module.finance.view', 'module.processing.view'], href: '/margin',
      itemHref: (r: OpsRow) => `/processing/${r.item_id}` },
    // 滞销支指向批次主页:SalePanel 恰在 remaining_qty > 0 时渲染,而那正是本支的
    // 谓词 —— 补救(登记销售)对本支发出的每一行都保证在场。
    // 【同一张页面上也能改 output_date,那一下会让牌子安静而一公斤都没动】——
    // 那是要点名的隐患,不是不给链接的理由(两条判据,见清单文件)。
    { itemType: 'output_unsold_aging', permission: 'module.output.view', href: '/output',
      itemHref: (r: OpsRow) => `/output/${r.item_id}/edit` },
    // SS-1:补救在物料自己那张页面上 —— 阈值就在那里改,补货也从那里出发。
    // 【与 output_unsold_aging 同一个隐患,同样点名】:在这张页面上把阈值调高
    // 或清空,牌子会安静而一公斤货都没动。那是判据之外的事,不是不给链接的理由。
    { itemType: 'safety_stock_below', permission: 'module.inventory.view', href: '/materials',
      itemHref: (r: OpsRow) => `/materials/${r.item_id}/edit` },
    // EXEC-3a/3b:工单逾期。【门牌指工单详情】—— 补救在那张页面上:
    // 改排产日(改计划)、收工、或者取消,三条路都在那里。
    // 【与 output_unsold_aging / safety_stock_below 同一个隐患,同样点名】:
    // 在那张页面上把排产日往后推,这盏灯会安静,而一天的活都没有做 ——
    // 那是判据之外的事,不是不给链接的理由(两条判据见清单文件)。
    { itemType: 'work_order_overdue', permission: 'module.processing.view', href: '/processing/orders',
      itemHref: (r: OpsRow) => `/processing/orders/${r.item_id}` },
    // EXEC-3a/3b:工单差异超阈。同样指工单详情 —— 差异的两侧就画在那张页面上,
    // 而改计划(投入那一侧的补救)也在那里。
    // 【阈值在同一张列表页上改得动】那同样会让灯安静而一克料都没动,
    // 与上面一条同一个道理;所以面板上写着这两个数是【判据】不是【目标】。
    { itemType: 'work_order_variance_beyond', permission: 'module.processing.view', href: '/processing/orders',
      itemHref: (r: OpsRow) => `/processing/orders/${r.item_id}` },
    // EXEC-1a/1b:行情陈旧。【补救在 /metal-prices 上】—— 那里既看得见整条序列,
    // 也是录下一条报价的地方,而这一支说的正是"该录了"。
    // item_id 指向【最近那一条报价】(这个金属本身没有 id),而那一行恰好就是
    // 人要接着往下看的那一行。
    { itemType: 'metal_quote_stale', permission: 'module.pricing.view', href: '/metal-prices',
      itemHref: () => '/metal-prices' },
    // EXEC-1a/1b:未履约订单。门牌指订单详情 —— 发货从那里出发,
    // 而"还欠多少"也只有那一页答得出来(逐单完成度归
    // sales_order_fulfilment_status,看板这一支只回答"哪些单还欠着")。
    { itemType: 'orders_unfulfilled', permission: 'module.sales.view', href: '/sales/orders',
      itemHref: (r: OpsRow) => `/sales/orders/${r.item_id}` },
    { itemType: 'leave_pending', permission: 'module.hr.view', href: '/hr/leave',
      itemHref: (r: OpsRow) => `/hr/leave/${r.item_id}` },
    { itemType: 'claim_pending', permission: 'module.hr.view', href: '/hr/claims',
      itemHref: (r: OpsRow) => `/hr/claims/${r.item_id}` },
    // item_code 是【员工编号】(评估表没有 code 列),item_id 是评估本身 —— 两者
    // 不同源正是 fixture 47 要钉的那类错。
    { itemType: 'review_submitted', permission: 'module.hr.view', href: '/hr/reviews',
      itemHref: (r: OpsRow) => `/hr/reviews/${r.item_id}` },
    { itemType: 'invoice_overdue', permission: 'module.finance.view', href: '/finance/invoices',
      itemHref: (r: OpsRow) => `/finance/invoices/${r.item_id}` },
    // SO-3a:应收也成了两种单据(doc_kind 'sale' / 'invoice');认不出的不给链接。
    { itemType: 'ar_over_90', permission: 'module.finance.view', href: '/finance/receivables',
      itemHref: (r: OpsRow) =>
          r.doc_kind === 'invoice' ? `/finance/invoices/${r.item_id}`
        : r.doc_kind === 'sale' ? `/finance/receivables/${r.item_id}`
        : null },
    // 【应付有三种单据】doc_kind 来自 ap_open_items 自己(应付列表页一直照它分支);
    // 认不出的种类【不给链接】,绝不猜一个 —— 猜错就是拿一个合法 uuid 开错人的单据。
    // PAY-FRT:第三支 'freight' 一直落在那个"认不出"的 null 里 —— 那条兜底本身是
    // 对的,而结果是一张逾期 90 天的运费应付【有行、无门】,尽管 /finance/freight/[id]
    // 这个页面一直存在。补的是映射,不是兜底。
    { itemType: 'ap_over_90', permission: 'module.finance.view', href: '/finance/payables',
      itemHref: (r: OpsRow) =>
          r.doc_kind === 'inbound' ? `/finance/payables/${r.item_id}`
        : r.doc_kind === 'expense' ? `/finance/expenses/${r.item_id}`
        : r.doc_kind === 'freight' ? `/finance/freight/${r.item_id}`
        : null },
    { itemType: 'fx_rate_gap', permission: 'module.finance.view', href: '/finance/fx',
      itemHref: (r: OpsRow) => `/finance/fx?currency=${encodeURIComponent(r.item_code)}` },
    // 等待的是一条对账单行,而行没有页面 —— 匹配动作在对账工作台上,所以 item_id
    // 是对账单。同一张单上的两条未匹配行共用一个门牌,这是对的,不是重复。
    { itemType: 'bank_unmatched', permission: 'module.finance.view', href: '/finance/bank',
      itemHref: (r: OpsRow) => `/finance/bank/statements/${r.item_id}/reconcile` },
    // ── LOG-5b:物流四支(第 23–26)。【补救都在箱子那一页上】——
    // 录到港、填 ETA、实例化清单、收单据,四件事全在集装箱详情做,
    // 所以四支的门牌都指向同一处。这一条写进 docs/dashboard-arm-inventory.md。
    // 【权限跟着视图里那一支声明的码走】,这里不再声明第二遍 ——
    // 免柜期那一支在库里由 arm_permission_widen 额外放给财务,而首页读的是
    // operations_now 已经筛过的行,所以这里写它的【主】码就够了。
    { itemType: 'free_time_expiring', permission: 'module.purchasing.view', href: '/logistics/containers',
      itemHref: (r: OpsRow) => `/logistics/containers/${r.item_id}` },
    { itemType: 'container_no_arrival', permission: 'module.purchasing.view', href: '/logistics/containers',
      itemHref: (r: OpsRow) => `/logistics/containers/${r.item_id}` },
    { itemType: 'container_eta_overdue', permission: 'module.purchasing.view', href: '/logistics/containers',
      itemHref: (r: OpsRow) => `/logistics/containers/${r.item_id}` },
    { itemType: 'container_documents_late', permission: 'module.purchasing.view', href: '/logistics/containers',
      itemHref: (r: OpsRow) => `/logistics/containers/${r.item_id}` },
] as const

// 一块牌子里最多列几件;其余交给那一支自己的列表(首页不是列表页)
const MAX_ITEMS_PER_TILE = 5

// 「我的」两张卡片:不受模块把关,人人可见 —— 理由与顺序同 NavLinks 的 SELF_ITEMS
// (OPS-15:employee 角色的全部产品恰恰是这两页,首页必须给入口)。
const SELF_CARDS = [
    { href: '/my-reviews', titleKey: 'home.myReviewsTitle', descKey: 'home.myReviewsDesc' },
    { href: '/me', titleKey: 'home.meTitle', descKey: 'home.meDesc' },
]

// LINKS-1:item_id 是【承载补救动作的那张页面所对应的行】—— 十七支里就是等待中的
// 那一行,bank_unmatched 与 margin_cost_not_allocated 两支里是它的父(对账单 / 加工单)。
// fx_rate_gap 恒为 null:缺的那条牌价行没有 id。doc_kind 只有应付一支非空。
type OpsRow = {
    item_type: string
    item_id: string | null
    doc_kind: string | null
    item_code: string
    subject: string | null
    item_date: string
}

export default async function Home() {
    const t = await getTranslations()
    const supabase = await createClient()
    const perms = await getMyPermissions()
    const visible = await getVisibleModules()

    // 一次读回全部可见支;无权的支缺席,可见支的零是真的零(权限已单独查过)
    const rows = mustRows(
        await supabase
            .from('operations_now')
            .select('item_type, item_id, doc_kind, item_code, subject, item_date'),
        'operations_now'
    ) as OpsRow[]

    // ── PAYEE-1b:ap_over_90 那一行的脸 ─────────────────────────────────────
    // 【问题】operations_now 的这一支取的是 ap_open_items.supplier_name,
    // 而 PAYEE-1a 之后应付的往来对象可以是【员工】—— 员工行的 supplier_name
    // 诚实地为 NULL,于是这一行在看板上【连名字都不显示】(subjectText 为空即隐藏)。
    // 一条只有单号、说不出欠谁的逾期应付,是这块看板最没用的一种行。
    //
    // 【为什么在这里补,而不是改视图】改 operations_now 那一行(supplier_name →
    // counterparty_name)是【一行】的事,也是它长久该待的地方 —— 但那是一支迁移,
    // 而本刀是纯渲染。所以这里【读同一个权威列】(ap_open_items.counterparty_name),
    // 不是另算一份名字:同一个真源,晚一跳而已。
    // **下一支动数据库的刀请把这一行搬回视图里,并删掉这一段。**
    const apOver90Ids = rows.filter((r) => r.item_type === 'ap_over_90')
                            .map((r) => r.item_id).filter(Boolean) as string[]
    const apPartyById = new Map<string, string>()
    if (apOver90Ids.length > 0) {
        const apRes = await supabase
            .from('ap_open_items')
            .select('doc_id, counterparty_name')
            .in('doc_id', apOver90Ids)
        for (const r of mustRows(apRes, 'ap_open_items counterparty') as
                 { doc_id: string; counterparty_name: string }[]) {
            apPartyById.set(r.doc_id, r.counterparty_name)
        }
    }

    // ── ASY-P2:awaiting_assay 那一行的脸 ────────────────────────────────────
    // 视图给的 subject 是【缺的那几种金属的 code】,逗号分隔("li" / "cu, li")。
    // 一个光秃秃的 "li" 挂在批次号旁边,读的人没有办法知道那是一种金属、还是一个
    // 状态码、还是别的什么 —— 所以这里把它翻成金属名,并加上"待化验:"这个前缀。
    // 【需要翻 subject 的支现在有两个】本支(金属 code → 金属名)与 ap_over_90
    // (见上:视图那一列对员工行为空)。其余各支放的是名字、单号、科目,本来就是人话。
    // 【认不出的 code 原样显示,不丢掉】少显示一种缺的金属,比显示一个 code 更坏。
    function subjectText(row: OpsRow): string | null {
        // PAYEE-1b:逾期应付一律显示【往来对象】的名字(供应商或员工)。
        // 视图那一列对员工行是 NULL —— 兜底回 row.subject 只是保守,
        // 正常情况下 apPartyById 一定命中(两者读的是同一张 ap_open_items)。
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

    // LINKS-1:牌子不再整块是一条链接 —— 标题与数字指向那一支的【列表】,下面每一件
    // 事各自指向【它自己】。两层链接不能嵌套(<a> 里不能再有 <a>),所以外壳是 div。
    const tileBox = (opts: {
        key: string
        title: string
        href: string
        allowed: boolean
        count: number | null
        oldest?: string | null
        items?: { row: OpsRow; href: string | null }[]
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
        const cls = 'border rounded-lg p-4 ' +
            (opts.allowed ? 'border-gray-300' : 'border-gray-200 bg-gray-50')
        const shown = (opts.items ?? []).slice(0, MAX_ITEMS_PER_TILE)
        const rest = (opts.items ?? []).length - shown.length
        return (
            <div key={opts.key} className={cls}>
                {opts.allowed ? (
                    <Link href={opts.href} className="block hover:opacity-75 transition">
                        {inner}
                    </Link>
                ) : (
                    inner
                )}
                {shown.length > 0 && (
                    <ul className="mt-3 pt-2 border-t border-gray-200 space-y-1">
                        {shown.map((it, i) => (
                            <li key={`${opts.key}-${i}`} className="text-xs truncate">
                                {/* 认不出门牌的行【不给链接】,而不是猜一个:一个合法的
                                    uuid 指错了表,打开的是别人的单据,而且不会报错。 */}
                                {it.href ? (
                                    <Link href={it.href} className="font-mono text-blue-600 hover:underline">
                                        {it.row.item_code}
                                    </Link>
                                ) : (
                                    <span className="font-mono text-gray-700">{it.row.item_code}</span>
                                )}
                                {subjectText(it.row) && (
                                    <span className="text-gray-500 ml-2">{subjectText(it.row)}</span>
                                )}
                            </li>
                        ))}
                        {rest > 0 && (
                            <li className="text-xs">
                                <Link href={opts.href} className="text-gray-500 hover:underline">
                                    {t('dashboard.andMore', { n: rest })}
                                </Link>
                            </li>
                        )}
                    </ul>
                )}
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
                    // 等得最久的排在前面 —— 牌子只列前几件,截断必须截在【新的】那头
                    const items = allowed
                        ? [...mine]
                              .sort((a, b) => (a.item_date < b.item_date ? -1 : a.item_date > b.item_date ? 1 : 0))
                              .map((row) => ({ row, href: tile.itemHref(row) }))
                        : undefined
                    return tileBox({
                        key: tile.itemType,
                        title: t('dashboard.item.' + tile.itemType),
                        href: tile.href,
                        allowed,
                        count: allowed ? mine.length : null,
                        oldest,
                        items,
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

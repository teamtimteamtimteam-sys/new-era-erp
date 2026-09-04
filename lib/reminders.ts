// lib/reminders.ts
// ════════════════════════════════════════════════════════════════════════════
// CONV-7 ①(2026-09-04)· 提醒的【清单】—— 从 app/page.tsx 搬来,并补上两支
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么它离开了首页】Tim 的裁定:这些信号【天生跨模块】,把它们拆回各自的
// 模块就丢掉了"一眼看完所有该操心的事"这件事本身。给它们自己一个去处,人就是
// 【想看的时候去看】,而不是一登录就被推一脸 —— 那正是安静的首页得以成立的前提。
//
// ★★【本文件存在的第二个理由:两支【在库里活着、在屏幕上不存在】】★★
//   实测(CONV-7,2026-09-04):`db/views/operations_now.sql` 有 **34 支**,
//   而 app/page.tsx 的 TILES 只有 **32 块牌子** —— `promise_overdue` 与
//   `wht_due` 【一块牌子都没有】。两支都不是半成品:
//     · 谓词在视图里、i18n 键在 messages 里(check-i18n 的后缀集合逼出来的)、
//     · 门牌规格白纸黑字写在 docs/dashboard-arm-inventory.md 第 273/274 行、
//     · fixture 111 的 v_expected 数着它们、fixture 138 正面验 promise_overdue、
//     · app/finance/wht/actions.ts:28 甚至写着「首页那一支 wht_due 的谓词刚刚变了」
//       并为它 revalidatePath('/') —— **代码相信那块牌子存在。它不存在。**
//   也就是说:库、文档、i18n、fixture、失效重算【五处都对齐了】,唯独渲染那一处
//   漏了,而【没有任何一样东西看着渲染那一侧】。fixture 111 钉的是视图的支列表,
//   它管不到 TypeScript。
//
// ★【所以修的不是那两支,是"漏得掉"这件事本身】★
//   本文件是【唯一一份】牌子清单,而 scripts/check-reminder-arms.mjs 在
//   `npm run build` 里把它与 db/views/operations_now.sql 的 item_type 字面量
//   逐字对齐 —— 多一支、少一支都当场红,并点名是哪一支。
//   判法与 check-i18n 的 sqlLiteralAs 同源(它早就这么盯着 dashboard.item.* 了),
//   所以这不是一套新机制,是把已经在用的那一套【接到第二根线上】。
//
// 【下面这一整段清单,连同它的每一条注释,是从 app/page.tsx 原样搬过来的】
// 一个字都没有改写 —— 它们记的是每一支的门牌为什么指那里,而那些理由与它住在
// 哪个文件无关。**只有两处新增**:文件末尾的 promise_overdue 与 wht_due。
// ════════════════════════════════════════════════════════════════════════════
import type { PermissionSpec } from '@/lib/modules'

// LINKS-1:item_id 是【承载补救动作的那张页面所对应的行】—— 十七支里就是等待中的
// 那一行,bank_unmatched 与 margin_cost_not_allocated 两支里是它的父(对账单 / 加工单)。
// fx_rate_gap 恒为 null:缺的那条牌价行没有 id。doc_kind 只有应付一支非空。
//
// 【CONV-7 多取一列:days_waiting】视图一直算着 `CURRENT_DATE - item_date`,
// 而首页【从来没有 select 过它】,自己拿 item_date 去比最小值。现在直接读它 ——
// 于是"等了几天"这个数的基准是【数据库的 CURRENT_DATE】,不是浏览器所在时区的今天。
export type OpsRow = {
    item_type: string
    item_id: string | null
    doc_kind: string | null
    item_code: string
    subject: string | null
    item_date: string
    days_waiting: number
}

/** 一支提醒:它是什么、谁看得见、它的列表在哪、它的每一件事各自在哪。 */
export type Reminder = {
    itemType: string
    permission: string
    permissionAny?: readonly string[]
    permissionWiden?: readonly string[]
    href: string
    itemHref: (r: OpsRow) => string | null
}

export const REMINDERS = [
    { itemType: 'awaiting_assay', permission: 'module.inbound.view', href: '/inbound',
      itemHref: (r: OpsRow) => `/inbound/${r.item_id}/edit` },
    { itemType: 'assay_unapplied', permission: 'module.inbound.view', href: '/inbound',
      itemHref: (r: OpsRow) => `/inbound/${r.item_id}/edit` },
    { itemType: 'batch_unpriced', permission: 'module.inbound.view', href: '/inbound',
      itemHref: (r: OpsRow) => `/inbound/${r.item_id}/edit` },
    { itemType: 'allocation_stale', permission: 'module.processing.view', href: '/operation/processing',
      itemHref: (r: OpsRow) => `/operation/processing/${r.item_id}` },
    { itemType: 'qualification_expiring', permission: 'module.suppliers.view', href: '/suppliers',
      itemHref: (r: OpsRow) => `/suppliers/${r.item_id}/edit` },
    { itemType: 'qualification_missing', permission: 'module.suppliers.view', href: '/suppliers',
      itemHref: (r: OpsRow) => `/suppliers/${r.item_id}/edit` },
    // CMPL-1:公司【自家】执照将到期 —— 与上面两支供应商资质臂同形、同权限码,
    // 读的也是同一份 certificate_types.warn_lead_days。界在 /finance/company,
    // 因为那一页才是能【续期】的地方(与 qualification_* 界在供应商页同一条理由)。
    { itemType: 'company_licence_expiring', permission: 'module.suppliers.view', href: '/finance/company',
      itemHref: () => '/finance/company' },
    // CMPL-1:是进口货、而进口准证还没有人核过。**它不拦任何东西** ——
    // 拦的那一半由 nea_import 的 block 处置在收货上做;这一支说的是"还欠一次人工核对"。
    { itemType: 'import_permit_unverified', permission: 'module.inbound.view', href: '/inbound',
      itemHref: (r: OpsRow) => `/inbound/${r.item_id}/edit` },
    { itemType: 'po_awaiting_receipt', permission: 'module.purchasing.view', href: '/purchasing/orders',
      itemHref: (r: OpsRow) => `/purchasing/orders/${r.item_id}` },
    { itemType: 'stocktake_open', permission: 'module.stocktakes.view', href: '/stocktakes',
      itemHref: (r: OpsRow) => `/stocktakes/${r.item_id}` },
    // 信用支指向【只读的信用仓位页】,不是客户编辑表单 —— 改限额会让告警安静,
    // 而敞口一分未动(SAL-B6 分界的理由)。
    { itemType: 'credit_over_limit', permission: 'module.customers.view', href: '/sales/customers',
      itemHref: (r: OpsRow) => `/sales/customers/${r.item_id}` },
    // 跨两个模块的那一支:必须有 data.view_prices,且 finance / processing 之一。
    // 只收 no_unit_cost(分摊一次就清掉);no_run 事后无从补救,放上来就是关不掉的灯。
    // 【item_id 是加工单,不是批次】支报的是批次,而补救是给【加工单】分摊成本,
    // 分摊按钮在加工单页上 —— 门牌跟着补救走。
    { itemType: 'margin_cost_not_allocated', permission: 'data.view_prices',
      permissionAny: ['module.finance.view', 'module.processing.view'], href: '/margin',
      itemHref: (r: OpsRow) => `/operation/processing/${r.item_id}` },
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
    { itemType: 'work_order_overdue', permission: 'module.processing.view', href: '/operation/orders',
      itemHref: (r: OpsRow) => `/operation/orders/${r.item_id}` },
    // EXEC-3a/3b:工单差异超阈。同样指工单详情 —— 差异的两侧就画在那张页面上,
    // 而改计划(投入那一侧的补救)也在那里。
    // 【阈值在同一张列表页上改得动】那同样会让灯安静而一克料都没动,
    // 与上面一条同一个道理;所以面板上写着这两个数是【判据】不是【目标】。
    { itemType: 'work_order_variance_beyond', permission: 'module.processing.view', href: '/operation/orders',
      itemHref: (r: OpsRow) => `/operation/orders/${r.item_id}` },
    // EXEC-1a/1b:行情陈旧。【补救在 /tools/pricing/metal-prices 上】—— 那里既看得见整条序列,
    // 也是录下一条报价的地方,而这一支说的正是"该录了"。
    // item_id 指向【最近那一条报价】(这个金属本身没有 id),而那一行恰好就是
    // 人要接着往下看的那一行。
    { itemType: 'metal_quote_stale', permission: 'module.pricing.view', href: '/tools/pricing/metal-prices',
      itemHref: () => '/tools/pricing/metal-prices' },
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
    // 【放宽:免柜期这一支库里就放给了财务(LOG-5a 的 arm_permission_widen)】——
    // 见下面 permissionWiden 那一段:此前这里只写主码,于是一个只持财务的读者
    // 【拿得到行、屏幕上却写着「受限」】。EQP-2d 补上。
    // 【NAV-REG-1:四支的码从采购换成物流】与视图、与八张表的 RLS 同码。
    // 只换表不换支的话,一个持 module.logistics.view 的读者读得到那几张表,
    // 而这四块牌子对他写着「受限」—— 正是 EQP-2d 实测到的那个方向的谎。
    { itemType: 'free_time_expiring', permission: 'module.logistics.view',
      permissionWiden: ['module.logistics.view', 'module.finance.view'], href: '/logistics/containers',
      itemHref: (r: OpsRow) => `/logistics/containers/${r.item_id}` },
    { itemType: 'container_no_arrival', permission: 'module.logistics.view', href: '/logistics/containers',
      itemHref: (r: OpsRow) => `/logistics/containers/${r.item_id}` },
    { itemType: 'container_eta_overdue', permission: 'module.logistics.view', href: '/logistics/containers',
      itemHref: (r: OpsRow) => `/logistics/containers/${r.item_id}` },
    { itemType: 'container_documents_late', permission: 'module.logistics.view', href: '/logistics/containers',
      itemHref: (r: OpsRow) => `/logistics/containers/${r.item_id}` },
    // ── EQP-2d:保养那两支(第 27–28)。【门牌指机器那一页】—— 补救是"给这台
    // 机器记一次保养",而那张表单 EQP-2d 就建在 /finance/assets/[id] 上。
    // item_id 是 fixed_assets 的行(间隔行没有自己的页面),与 bank_unmatched /
    // margin_cost_not_allocated 取父行同一条规矩。
    // 【两支分开画,永远不合并】到期与将到期是两件事:一个已经欠着,一个还来得及。
    // 合成一块牌子就是把"该停机检修了"和"下周安排一下"说成同一句话。
    // 【与 safety_stock_below / work_order_overdue 同一个隐患,同样点名】:
    // 在那张页面上把间隔调大、或者把那一行删掉,这盏灯会安静,而一次保养都没做 ——
    // 那是判据之外的事,不是不给链接的理由(两条判据见清单文件)。
    { itemType: 'equipment_service_due', permission: 'module.processing.view',
      permissionWiden: ['module.processing.view', 'module.finance.view'], href: '/finance/assets',
      itemHref: (r: OpsRow) => `/finance/assets/${r.item_id}` },
    { itemType: 'equipment_service_approaching', permission: 'module.processing.view',
      permissionWiden: ['module.processing.view', 'module.finance.view'], href: '/finance/assets',
      itemHref: (r: OpsRow) => `/finance/assets/${r.item_id}` },

    // ══ CONV-7 ①:补上【一直缺席的两支】 ═════════════════════════════════════
    // 两支都不是新造的:视图、i18n、fixture、门牌规格全都早就在了,少的只有
    // 这两行。为什么会少,以及为什么这次修的是"漏得掉"这件事本身,见本文件抬头。
    //
    // 【付款承诺逾期】门牌指【客户】,不指承诺 —— docs/dashboard-arm-inventory.md
    // 第 273 行写着理由,原样引在这里,因为它是一个会被"顺手改成指催收记录"的地方:
    //   承诺没有自己的页面,而它也不该有;了结一个承诺要看的是这个客户的整个仓位
    //   (欠多少、催过几次、这次答应之后到底核销了多少),而那一屏就是客户档案页。
    // item_code 是那条催收的编号,不是客户编号 —— 与 review_submitted 的
    // 「item_code 是员工编号、item_id 是评估本身」同一种不同源,fixture 47 的那一类。
    { itemType: 'promise_overdue', permission: 'module.finance.view', href: '/finance/receivables',
      itemHref: (r: OpsRow) => (r.item_id ? `/sales/customers/${r.item_id}` : null) },
    // 【预提税待汇缴】主体是一个【月份】,而月份没有自己的页面 —— 所以门牌就是
    //   /finance/wht 那一页本身(负债表 + 汇缴表单都在上面)。item_id 恒为 NULL,
    //   item_code 是那个代扣月(YYYY-MM)—— 与 fx_rate_gap 同形。
    // 【它今天在线上恒为空】一家非居民服务商都没有(实测 2026-08-28,
    //   docs/known-issues.md 的 WHT-1)。**那不是不画它的理由** —— 恰恰相反:
    //   一支永远为空的提醒与一支【根本没有渲染】的提醒,在屏幕上一模一样,
    //   而这正是它躺了这么久没人发现的原因。
    { itemType: 'wht_due', permission: 'module.finance.view', href: '/finance/wht',
      itemHref: () => '/finance/wht' },
] as const satisfies readonly Reminder[]

/**
 * 【清单里有几支】—— 给检查脚本与报告用的一个数,不给渲染用。
 * 它必须等于 db/views/operations_now.sql 的 item_type 支数,
 * 而 scripts/check-reminder-arms.mjs 在构建期逐支比对(不是比数字 —— 比名字)。
 */
export const REMINDER_COUNT = REMINDERS.length

/** 一支提醒的权限谓词。与视图末尾那个 WHERE 逐字同形 —— 见 app/tools/reminders/page.tsx。 */
export function specFor(r: Reminder): PermissionSpec {
    return {
        all: [r.permission],
        any: r.permissionAny,
        widen: r.permissionWiden,
    }
}

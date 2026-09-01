// lib/modules.ts
// 【模块清单、功能清单,以及全站唯一的权限谓词求值器】
//
// 本文件回答两个不同的问题:
//   MODULES   —— 有哪些模块,进每一个要什么权限(导航条按它渲染);
//   FUNCTIONS —— 有哪些功能【同属几个模块】,以及进它要什么权限。
//
// 【NAV-REG-1:permission 从"一个字符串"变成"一个谓词"】
// 在这之前 ModuleEntry.permission 是一行一个码,表达不了 AND/OR,于是跨模块的功能
// (/margin、/deleted)只能靠【在每个属主模块的页面里手写一个链接】存在 —— 而手写的
// 链接与权限之间没有任何东西保证同步,那正是 OPS-15 要杀掉的那种漂移。
//
// 【求值只有一处:本文件的 allows()】。lib/moduleAccess.ts(服务端过滤)、
// app/components/moduleGuard.tsx(页面守卫)、app/page.tsx(看板牌子)三处
// 【全部调用它】,谁都不再自己比对权限码。
// 【为什么这一条是硬规矩】EQP-2d 实测过两份实现漂开的后果:库里的视图已经放宽了
// (arm_permission_widen),而首页那一份还没有,于是一个【拿得到行】的读者在屏幕上
// 看见「受限」—— 把"你看得见"说成"你看不见"。一条规则两个实现,迟早各错一次。
//
// 【这个谓词的形状不是新发明的】它与库里那三个函数逐字同形(arm_permission /
// arm_permission_any / arm_permission_widen,见 db/views/operations_now.sql 末尾的
// WHERE):
//     (all 全有  OR  widen 任一)  AND  (any 未声明 OR any 任一)
// 换一种拼法就是第四份方言,而这个仓库为方言付过账。
//
// 【为什么这个文件里没有任何服务端 import】NavLinks 是 'use client'。纯数据 + 类型
// + 纯函数才能被两侧同时 import;取权限码在服务端做(lib/permissions.ts),
// 结果作为 prop 传下来。
//
// 【NAV-REG-1 删掉了什么,以及为什么】SECTIONS / section / titleKey / descKey 与
// moduleForPath / alsoCovers 全部删除 —— 它们【一个消费者都没有】。旧抬头写着
// "导航条与首页卡片从此读同一份数据",那句话在 OPS-18 之后就不成立了:首页早就
// 不渲染模块卡片,改成了运营看板。IA-0 的字段盘点表把 moduleForPath 记成【活】,
// 而它一次都没有被调用过 —— 一张表说某样东西在用,不是它被调用的证据。
// 【有读者的字段才留下】一个没有读者的字段,是下一个人据以断定"这里已经接好了"的东西。

/**
 * 权限谓词。单个字符串 = 只要这一个码(绝大多数模块就是这样)。
 *
 * 对象形式的三个算子与库里同名同义:
 *   all   —— 必须【全部】持有;
 *   any   —— 还必须【任一持有】,与 all 相与 → 方向是【收窄】;
 *   widen —— 持有其一即可【替代】all,与 all 相或 → 方向是【放宽】。
 * 两个方向都要有,而且不能互相顶替:LOG-5a 需要放宽、MAR-1 需要收窄。
 */
export type PermissionSpec =
    | string
    | {
          /** 空数组 = 没有"人人必须持有"的那一半;此时由 any 单独决定。 */
          all: readonly string[]
          any?: readonly string[]
          widen?: readonly string[]
      }

/**
 * 【全站唯一的权限谓词求值器】。
 * 除本函数外,任何地方都【不得】自己拿权限码去比对一份清单来决定可见性。
 * 单码判断走 lib/permissions.ts 的 can(),它是本函数字符串分支的同义写法。
 */
export function allows(spec: PermissionSpec, perms: readonly string[]): boolean {
    if (typeof spec === 'string') return perms.includes(spec)
    const base =
        spec.all.every((c) => perms.includes(c)) ||
        (spec.widen?.some((c) => perms.includes(c)) ?? false)
    return base && (spec.any === undefined || spec.any.some((c) => perms.includes(c)))
}

export type ModuleEntry = {
    /** 模块入口路由;模块下所有子路由都按同一个 permission 把关 */
    href: string
    /** 导航条标签 */
    navKey: string
    /** 进入本模块所需的权限 —— 与 db/tables/permissions.sql 的码对应 */
    permission: PermissionSpec
}

export const MODULES: readonly ModuleEntry[] = [
    // CONTRACT-1:/contracts 归在供应商模块之下,而这是一个【判断】不是一次偷懒。
    //   一份合同跨买卖两侧,而本仓库的权限是按模块分的 —— 没有"合同"这个模块,
    //   新造一个就要新造一个权限码,那超出本刀。
    //   **行一级的可见性已经由 RLS 管对了**:买方合同要 suppliers.view,
    //   卖方合同要 customers.view —— 所以一个只有客户权限的人在这一页上
    //   看得到他该看的那些行。挂在 suppliers 之下,是因为**第一批真合同是供货协议**,
    //   而 suppliers.view 正是它们的那道门。
    //   COMM-1:/commissions 同一条判断,同一个理由 —— 一份佣金协议的【主语是代理人】,
    //   而代理人是一个 supplier(counterparty_type = service_vendor)。每一行都有代理人,
    //   无论它挂采购侧、销售侧还是独立,所以 suppliers.view 是那道对的门;
    //   按 side 分会让 free_standing 那一档无家可归。
    //   【NAV-REG-1:这两条从前记在 alsoCovers 字段里,而那个字段唯一的读者
    //   (moduleForPath)一次都没有被调用过。信息是真的,字段是死的 —— 所以信息
    //   留在这里,字段删掉。】
    { href: '/suppliers', navKey: 'nav.suppliers', permission: 'module.suppliers.view' },
    // 采购在收货之前 —— 流程顺序:下单 → 收货 → 加工
    { href: '/purchasing', navKey: 'nav.purchasing', permission: 'module.purchasing.view' },
    { href: '/customers', navKey: 'nav.customers', permission: 'module.customers.view' },
    { href: '/materials', navKey: 'nav.materials', permission: 'module.materials.view' },
    // 【/metal-prices 不在这里,而且不是漏了 —— 它不归模块目录管,理由在数据自己身上】
    //
    // 【规矩:守卫跟着数据自己的 RLS 走,不跟模块目录走。】
    // 而一张表的 RLS 本来就有【读】和【写】两个答案,它们可以不一样 —— metal_prices
    // 的这两个答案恰恰不一样(db/tables/metal_prices.sql):
    //
    //   SELECT               USING (true)                                → 公开
    //   INSERT/UPDATE/DELETE has_permission('module.pricing.edit')       → 受管
    //
    // 所以 app/metal-prices/ 底下四页带着【两种守卫】,那是同一条规则的两半,不是
    // 四页里有一页例外:
    //
    //   /metal-prices(列表,只读)           不设守卫 —— 读策略放行任何人
    //   /metal-prices/{new,bulk,[id]/edit}   requireEditPermission('module.pricing.edit', …)
    //
    // 【读的那一半】行情是市场报价,不是本公司的秘密,数据自己声明它公开。页面守卫的
    // 职责是把"进不去"说出来,而不是发明一道数据库没有的门:给列表页挂上
    // module.pricing.view,屏幕上就会对一个数据库愿意完整回答的人显示"你没有权限",
    // 那是【UI 比数据严】,而且严得没有任何东西背书。
    //
    // 【写的那一半】反过来,数据库确实有那道门,只是它叫 module.pricing.edit。用
    // module.pricing.view 去把关会同时错两头:挡下有 edit 而无 view 的人,又放进有
    // view 而无 edit 的人 —— 后者填完整张表单再被 42501 拒收(AGENTS.md §"永远不要
    // 为服务端必然拒绝的动作渲染提交控件")。
    //
    // 权限目录里 module.pricing.view 那一条的描述("公式、计价器与行情")是【目录的
    // 措辞】,不是策略;两者冲突时以策略为准。要把 /metal-prices 收回模块目录,
    // 先改 metal_prices 的策略,再改代码,顺序不能反。
    //
    // 【/pricing 本身仍然整个受管】:公式(pricing_formulas)与计价器不是公开数据 ——
    // 它的 SELECT 策略就是 has_permission('module.pricing.view'),而 payable_pct /
    // treatment_charge_usd_per_tonne / flat_discount_pct 是谈出来的商务条款,本来就是
    // perm2b 撤销、藏在 data.view_prices 后面的列。区别就在这一句上。
    { href: '/pricing', navKey: 'nav.pricing', permission: 'module.pricing.view' },
    { href: '/inbound', navKey: 'nav.inbound', permission: 'module.inbound.view' },
    { href: '/output', navKey: 'nav.output', permission: 'module.output.view' },
    { href: '/processing', navKey: 'nav.processing', permission: 'module.processing.view' },
    { href: '/inventory', navKey: 'nav.inventory', permission: 'module.inventory.view' },
    { href: '/stocktakes', navKey: 'nav.stocktakes', permission: 'module.stocktakes.view' },
    // SO-1-fu:销售是一个【真模块】—— 自己的单据、自己的角色、自己的操作面。
    { href: '/sales/orders', navKey: 'nav.sales', permission: 'module.sales.view' },
    { href: '/finance', navKey: 'nav.finance', permission: 'module.finance.view' },
    { href: '/tasks', navKey: 'nav.tasks', permission: 'module.tasks.view' },
    { href: '/hr', navKey: 'nav.hr', permission: 'module.hr.view' },
    // NAV-REG-1 / R2:物流【终于有了自己的码】。
    // 在这之前它借 module.purchasing.view,而 LOG-1c 把"将来铸这个码"写成了待办。
    // 借码有一个实测的受害者:operations / warehouse / sales 三个角色【都不持有
    // 采购权限】—— 也就是说,搬货的人看不见物流模块。
    // 【铸码不是改这一行就完了】ports / lanes / forwarder_rate_quotes /
    // forwarder_details / lane_document_requirements / containers 六张表的 SELECT
    // 策略同时换成了本码(见 db/migrations/2026-09-01-navreg1-…),否则这一行只会
    // 得到一个"打得开、但零行"的页面 —— 旧注释早就把这个陷阱写在这里了。
    // 【写的那一半没有动】六张表的 INSERT/UPDATE/DELETE 仍然是 module.purchasing.edit:
    // 持有它的四个角色(admin/finance/gm/procurement)全都在本码的授予名单里,
    // 所以不存在"改得动、读不回"的倒挂;而铸一个没有消费者的 .edit 码只会是死码。
    { href: '/logistics/forwarders', navKey: 'nav.logistics', permission: 'module.logistics.view' },
]

/**
 * 【一个功能可以同属几个模块】—— NAV-REG-1 的核心,Tim 的裁定 R1。
 *
 * 一个产出批次既是加工的结果、也是可售的库存;一个数字可以正当地出现在两个模块
 * 底下,只要【数据不重复】。在这之前这件事只能靠在每个属主模块的页面里手写链接
 * 表达 —— 而手写的链接与权限之间没有任何东西保证同步。
 *
 * modules 列出属主(module href),permission 是【唯一的一份】判据。
 * 每个属主模块的界面从 functionsForModule() 取自己名下的功能,过滤用 allows() ——
 * 于是"谁能看见这个入口"与"谁能进这一页"来自同一个表达式,不可能各错一次。
 */
export type FunctionEntry = {
    href: string
    navKey: string
    /** 本功能同属的模块(MODULES 的 href);长度可以大于 1 —— 那正是本清单存在的理由 */
    modules: readonly string[]
    permission: PermissionSpec
}

export const FUNCTIONS: readonly FunctionEntry[] = [
    // MAR-1:批次毛利。收入在财务,分摊成本在加工,而【没有任何 live 角色同时持有
    // 两者】(admin / auditor / gm 除外)—— 挂进任一模块的路由树就会挡掉另一半读者。
    // 谓词与 db/views/batch_margin.sql 逐字同形:
    //     data.view_prices AND (module.finance.view OR module.processing.view)
    // 【收窄的那一半(any)是模块,相与的那一半(all)是数据类】—— 这个结构本身
    // 就是拒绝措辞的依据:缺模块说"你没有进入该模块的权限",缺价格可见性说
    // "这个数字属于价格信息"。两句话来自同一个谓词的两半,不是两份定义。
    {
        href: '/margin',
        navKey: 'margin.title',
        modules: ['/finance', '/processing'],
        permission: {
            all: ['data.view_prices'],
            any: ['module.finance.view', 'module.processing.view'],
        },
    },
    // AUDEL-3:被删记录。它跨【七支、六个码】,而这六个码正是视图 deleted_records
    // 每一行自带的那个 permission 列(db/views/deleted_records.sql)——
    // 这里不新造码,只把那份并集写成一个谓词。
    // 【all 是空的】:没有哪个码是人人必须持有的,由 any 单独决定。
    // 【行一级的过滤仍然在视图里】本谓词只回答"这一页对你有没有意义";
    // 进来之后看得见哪几类,仍然由每一行自己的 has_permission 决定。
    {
        href: '/deleted',
        navKey: 'nav.deleted',
        modules: [
            '/inbound',
            '/output',
            '/processing',
            '/stocktakes',
            '/purchasing',
            '/sales/orders',
        ],
        permission: {
            all: [],
            any: [
                'module.inbound.view',
                'module.output.view',
                'module.processing.view',
                'module.stocktakes.view',
                'module.purchasing.view',
                'module.sales.view',
            ],
        },
    },
]

/** 某个模块名下的功能(一个功能会在它每个属主模块下各出现一次 —— 那是要点)。 */
export function functionsForModule(moduleHref: string): FunctionEntry[] {
    return FUNCTIONS.filter((f) => f.modules.includes(moduleHref))
}

/**
 * 按名字取模块 / 功能:`requireModule(MOD.finance)`、`requireFunction(FN.margin)`。
 * 显式列出而不是从 href 派生 —— 拼错一个名字是编译期错误,派生出来的只是 undefined。
 */
const byHref = (href: string): ModuleEntry => {
    const m = MODULES.find((x) => x.href === href)
    if (!m) throw new Error(`lib/modules.ts: no module for ${href}`)
    return m
}
const fnByHref = (href: string): FunctionEntry => {
    const f = FUNCTIONS.find((x) => x.href === href)
    if (!f) throw new Error(`lib/modules.ts: no function for ${href}`)
    return f
}

export const MOD = {
    sales: byHref('/sales/orders'),
    suppliers: byHref('/suppliers'),
    purchasing: byHref('/purchasing'),
    customers: byHref('/customers'),
    materials: byHref('/materials'),
    pricing: byHref('/pricing'),
    inbound: byHref('/inbound'),
    output: byHref('/output'),
    processing: byHref('/processing'),
    inventory: byHref('/inventory'),
    stocktakes: byHref('/stocktakes'),
    finance: byHref('/finance'),
    tasks: byHref('/tasks'),
    hr: byHref('/hr'),
    logistics: byHref('/logistics/forwarders'),
} as const

export const FN = {
    margin: fnByHref('/margin'),
    deleted: fnByHref('/deleted'),
} as const

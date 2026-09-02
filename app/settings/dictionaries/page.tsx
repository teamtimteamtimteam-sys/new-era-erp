// DICT-ADMIN:五张字典的那扇门。
//
// 【它为什么在 /settings 底下,而导航里是【自己的一条】条目】
// 设置那个模块的治理半边由 action.manage_permissions 把门,而这五张字典
// 把门的是 module.materials.edit / module.inbound.edit。**共用那个码会造出一个
// 物料编辑员永远看不见的页** —— 本仓库为"没有入口的页"付过四次账。
// 所以它在注册表里是【自己的一条】,判据是这五张字典的权限任持其一。
//
// ★★【NAV-CLEANUP-1 ④ 更正:这里原本写的是「所以 NavLinks 里另加一项」】★★
//   **`NavLinks` 这个组件在 IA-BUILD-1 就已经不存在了**(`find app -name 'NavLinks*'` → 0),
//   导航从那时起是 lib/modules.ts 的 FUNCTIONS + app/components/nav/ModuleBar.tsx。
//   **一条描述【两代之前的机制】的注释,与一条断言不可能发生的事的注释,代价一样** ——
//   下一个照它去找 NavLinks 的人会找不到,然后以为这一条压根没接上导航。
//   【Tim 报的「Dictionaries 点了没反应」】本刀逐条排除了三种候选原因:
//   路由在、注册表条目在、谓词 live 上有 6 个角色持有 —— **所以它不是一条死条目**。
//   究竟是"条目看不见 / 点了不跳 / 跳过去是空页",报告里没说,本刀不猜:
//   它进了 docs/information-architecture.md §17.7 那份「只有人走一遍才能确认」的清单。
// 另外两个 picker(化验机构、化学体系)下面也直接链过来 —— 人撞到墙的那一刻就在那儿。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
import { pMap, DEFAULT_QUERY_CONCURRENCY } from '@/lib/pMap'
import { DICTIONARIES } from './registry'
import DictSection, { type DictRow } from './DictSection'

export default async function DictionariesPage() {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    // 【逐小节判权限】五张字典不是同一个权限把门的(实验室是 inbound.edit,
    // 其余四张是 materials.edit),所以这里不是一个整页的守卫,而是每一节各判各的。
    const allowed = await Promise.all(DICTIONARIES.map((d) => can(d.permission)))

    // 【D7:一个都不能编辑时,说"你不能",而不是画一张空页】
    // 受限【不是】零 —— 这是 lib/permissions.ts 存在的全部理由。
    if (!allowed.some(Boolean)) {
        return (
            <div className="p-6 max-w-2xl">
                <h1 className="text-2xl font-semibold mb-2">{t('dict.title')}</h1>
                <p className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                    {t('dict.noPermission')}
                </p>
            </div>
        )
    }

    // ★★【CHART-1 ②:这一段原本是【85 次串行往返】,实测 24,905 ms】★★
    //
    // 【原来的形状】六张字典串行取行,再对【每一行 × 每一张引用表】串行发一次
    // count —— substances 一张就是 7 行 × 8 张引用表 = 56 次,全库合计 79 次
    // count + 6 次取行 = 85 次,每一次都 `await` 在上一次回来之后。
    //
    // 【量出来的因果,记在这里免得下一个人再猜一遍】
    //   · 整页服务端渲染          24,905 ms(冒烟计时;下一名 6,767 ms,中位数 1,738 ms)
    //   · 每次往返摊到            ~293 ms
    //   · 数据库【真正干的活】    2.444 ms(EXPLAIN ANALYZE,inbound_batch_metals 上的 count)
    //   · 最大的一张引用表        24 行
    // 也就是说 **99% 以上是路上的时间**。**它不是一个缺索引的问题** ——
    // 在一张只有一页的表上建索引,规划器也不会去用它(实测计划就是 Seq Scan)。
    // 要减的是【串行的长度】,不是每一次查询的成本。
    //
    // 【改法】把那 85 次的依赖关系摊平:六张字典的取行一起发;拿到行之后,
    // 全部 (字典 × 行 × 引用表) 的 count 一次性排成一张平表,交给有上限的并发。
    // **一次查询都没有少发,少的是等待的层数** —— 而这一点是刻意的:
    // count 走 HEAD,永远只传一个数;换成"把行取回来自己数"能把 79 压到 12,
    // 却会在 inbound_batches 长起来的那天变成一个更难查的问题(见 lib/pMap.ts)。
    //
    // 【语义一个字没变】仍然逐小节判权限、仍然 `mustRows`、
    // 仍然「查不到不是零」当场 throw,小节顺序仍是 DICTIONARIES 的声明顺序。
    // 【说准一点】这是【构造上】等价:同一批查询、同一套值、同一个顺序 ——
    // **没有去 diff 渲染出来的 HTML 字节**(那要一个真会话,本刀没做)。
    // 屏幕上"看起来一样"由人走一遍确认,记在 docs/manual-walk-list.md §19.7。
    const visible = DICTIONARIES.filter((_, i) => allowed[i])

    const rowsPerDict = await pMap(visible, DEFAULT_QUERY_CONCURRENCY, async (d) => {
        const cols = ['code', 'name_en', 'name_zh', 'is_active', 'sort_order', 'notes',
                      ...d.extras.map((e) => e.column)].join(', ')
        return mustRows(
            await supabase.from(d.table).select(cols).order('sort_order'), d.table
        ) as unknown as DictRow[]
    })

    // 【D4:停用之前先说清楚有多少行带着这个值】
    // PROC-3 的 N40 实测过今天是零 —— **正因为是零,现在建它便宜,以后建它尴尬**。
    // 一个要停用某个值的人,几乎从来没有在想那些已经带着它的行。
    //
    // 【为什么先摊平成一张平表,而不是嵌套三层并发】嵌套的并发上限乘不起来:
    // 外层 6 × 内层 8 会一次放出 48 个,上限就不再是上限了。摊平之后
    // 整页【只有一个】并发闸,79 次请求按 12 个一批走,批数是算得出来的。
    const probes = visible.flatMap((d, di) =>
        rowsPerDict[di].flatMap((r) => d.referencedBy.map((ref) => ({ di, code: r.code, ref }))))

    const counts = await pMap(probes, DEFAULT_QUERY_CONCURRENCY, async (p) => {
        const c = await supabase.from(p.ref.table)
            .select(p.ref.column, { count: 'exact', head: true }).eq(p.ref.column, p.code)
        // 【查不到不是零】—— 数错了会让人以为"没人用",然后放心停用。
        if (c.error) throw new Error(`用量查询失败(${p.ref.table}): ${c.error.message}`)
        return c.count ?? 0
    })

    const sections = visible.map((d, di) => {
        const usage: Record<string, number> = {}
        for (const r of rowsPerDict[di]) usage[r.code] = 0
        return { spec: d, rows: rowsPerDict[di], usage }
    })
    // 计数按【下标】归位,不靠完成顺序 —— pMap 保证返回顺序与输入顺序一致。
    probes.forEach((p, i) => { sections[p.di].usage[p.code] += counts[i] })

    return (
        <div className="p-6 max-w-4xl">
            <h1 className="text-2xl font-semibold mb-1">{t('dict.title')}</h1>
            <p className="text-sm text-gray-600 mb-4">{t('dict.intro')}</p>
            {/* 【D2:停用 ≠ 删除 —— 整页最上面说一次,每一行旁边再说一次】
                两处用的是同一句话,因为它是这块屏幕最容易被误读的东西。 */}
            <p className="mb-6 rounded border border-blue-200 bg-blue-50 px-3 py-2 text-sm text-blue-900">
                {t('dict.deactivateNotDelete')}
            </p>
            {sections.map((s) => (
                <DictSection key={s.spec.table} spec={s.spec} rows={s.rows}
                             usage={s.usage} locale={locale} />
            ))}
        </div>
    )
}

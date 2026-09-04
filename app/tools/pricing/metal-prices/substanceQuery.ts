// PROC-4:那张字典的读取 —— 一份实现,所有读它的页面共用。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这一支必须存在:此前 app 自己【也】拿着一份清单】
//
// PROC-4 之前,`app/tools/pricing/metal-prices/options.ts` 里有一个写死的 METAL_OPTIONS ——
// **那是第五份命名权**(八张表的 CHECK 是前四类,加上它),而且它同时定着
// 三件事:哪些值合法、它们怎么排、它们叫什么。16 个文件引用它。
//
// 【这正是 materials.category 那次的形状】F7 的老问题:一份清单散在几处,
// 写下的那天一致,之后各自漂开。而这一次连"漂开"都不必等 ——
// **实测:两个顺序【今天就是矛盾的】**。app 侧数组序是 ni, co, li, mn, cu, al, fe
// (重要的排前面);DB 侧视图与函数里一律 `ORDER BY metal`,那是【字母序】。
// 同一批金属,下拉里镍第一,报表里铝第一。
//
// 【所以字典落地之后,清单与顺序都从库里来】加一种物质 = 加一行,
// 不必改 app、不必发版 —— 那是 D1 全部的意义。名字也一样从库里来
// (name_en / name_zh),所以【不再有 metals.* 那组 i18n 键】:
// 一个新行如果还要配两条翻译才显示得出来,那它就不只值一行。
// ════════════════════════════════════════════════════════════════════════════
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'

export type Substance = {
    code: string
    name_en: string
    name_zh: string
    symbol: string | null
    is_active: boolean
}

/** 可【新选】的那些 —— 下拉、复选框用这一份。顺序由字典的 sort_order 决定(D4)。 */
export async function loadSubstances(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>
): Promise<Substance[]> {
    return mustRows(
        await supabase.from('substances')
            .select('code, name_en, name_zh, symbol, is_active')
            .eq('is_active', true)
            .order('sort_order'),
        'substances'
    ) as unknown as Substance[]
}

/**
 * 【显示用:停用的也要读得出来】—— D5 的那一半。
 *
 * 停用一种物质【不会】让已经记下来的数字失效,所以任何"把码翻成名字"的地方
 * 必须连停用的行一起读。只读 is_active 的实现会让一条历史化验结果
 * 突然显示成一个光秃秃的 code —— 那不是"这个值不再可选",那是【数据看起来坏了】。
 */
export async function loadSubstanceLabels(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>
): Promise<Substance[]> {
    return mustRows(
        await supabase.from('substances')
            .select('code, name_en, name_zh, symbol, is_active')
            .order('sort_order'),
        'substances'
    ) as unknown as Substance[]
}

/** code → 读者语言的名字。查不到就把 code 原样还回去(比空白诚实)。 */
export function substanceLabeller(rows: Substance[], locale: string) {
    const m = new Map(rows.map((r) => [r.code, locale === 'zh' ? r.name_zh : r.name_en]))
    return (code: string | null | undefined) => (code ? m.get(code) ?? code : '')
}

/**
 * 字典行 → 下拉选项。label 已经是【读者语言的那一份】。
 *
 * 【停用的行也在里面,带着 isActive=false】—— D5 的两个动词:
 * 选单要过滤 isActive,而把码翻成名字【不能】过滤它,否则一条历史数据会突然
 * 显示成一个光秃秃的 code。两件事用同一份数据,判断留给用它的地方。
 */
export function toOptions(rows: Substance[]) {
    return rows.map((r) => ({
        value: r.code,
        labelKey: 'metals.' + r.code,
        isActive: r.is_active,
    }))
}

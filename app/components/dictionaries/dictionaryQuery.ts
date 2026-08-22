// PROC-5:两张新字典的读取 —— 一份实现,所有读它们的页面共用。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么名字也从库里来,而 PROC-4 的金属没有】
// PROC-4 把金属的【清单与顺序】搬进字典,但名字仍留在 i18n 里 ——
// 理由是那边有 11 处嵌在客户端组件深处的显示点,把 label 一路传下去
// 风险大于收益,所以用"check-i18n 现读字典"把那份 i18n 变成【被检查的镜像】。
//
// **这一刀不一样:化学体系只有 3 处、实验室只有 2 处**,全部能直接喂。
// 所以名字回到字典自己身上(name_en / name_zh),与 material_kinds、
// inbound_safety_states 一致 —— **加一种 = 加一行,连翻译都不用配**。
// 两种做法不是随手选的,是按"要动多少处"决定的;差别写在这里,
// 免得下一个人看见不一致以为是漏了。
// ════════════════════════════════════════════════════════════════════════════
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'

export type DictRow = {
    code: string
    name_en: string
    name_zh: string
    is_active: boolean
}

/** 下拉选项:label 已经是【读者语言的那一份】。 */
export type DictOption = { value: string; label: string; isActive: boolean }

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Sb = SupabaseClient<any, any, any>

async function load(sb: Sb, table: string): Promise<DictRow[]> {
    return mustRows(
        await sb.from(table).select('code, name_en, name_zh, is_active').order('sort_order'),
        table
    ) as unknown as DictRow[]
}

/**
 * 【连停用的一起读 —— D1 的两个动词】
 * 选单要过滤 isActive;而把码翻成名字【不能】过滤它,否则一条记着已停用取值的
 * 历史数据会突然显示成一个光秃秃的 code —— 那看起来像数据坏了,
 * 而不是像"这个值不再可选"。判断留给用它的地方,不在这里替它做。
 */
export async function loadBatteryChemistries(sb: Sb) { return load(sb, 'battery_chemistries') }
export async function loadLaboratories(sb: Sb) { return load(sb, 'laboratories') }

export function toDictOptions(rows: DictRow[], locale: string): DictOption[] {
    return rows.map((r) => ({
        value: r.code,
        label: locale === 'zh' ? r.name_zh : r.name_en,
        isActive: r.is_active,
    }))
}

/** code → 读者语言的名字。查不到就把 code 原样还回去(比空白诚实)。 */
export function dictLabeller(rows: DictOption[]) {
    const m = new Map(rows.map((r) => [r.value, r.label]))
    return (code: string | null | undefined) => (code ? m.get(code) ?? code : '')
}

// DICT-ADMIN:五张字典的那扇门。
//
// 【它为什么在 /settings 底下,而导航是【另加】的一项】
// 导航里原有的「设置」只对持 action.manage_permissions 的人显示,而这五张字典
// 把门的是 module.materials.edit / module.inbound.edit。**沿用那一项会造出一个
// 物料编辑员永远看不见的页** —— 本仓库为"没有入口的页"付过四次账。
// 所以 NavLinks 里另加一项,判据是【这五张字典的权限任持其一】。
// 另外两个 picker(化验机构、化学体系)下面也直接链过来 —— 人撞到墙的那一刻就在那儿。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
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

    const sections = []
    for (let i = 0; i < DICTIONARIES.length; i++) {
        const d = DICTIONARIES[i]
        if (!allowed[i]) continue
        const cols = ['code', 'name_en', 'name_zh', 'is_active', 'sort_order', 'notes',
                      ...d.extras.map((e) => e.column)].join(', ')
        const rows = mustRows(
            await supabase.from(d.table).select(cols).order('sort_order'), d.table
        ) as unknown as DictRow[]

        // 【D4:停用之前先说清楚有多少行带着这个值】
        // PROC-3 的 N40 实测过今天是零 —— **正因为是零,现在建它便宜,以后建它尴尬**。
        // 一个要停用某个值的人,几乎从来没有在想那些已经带着它的行。
        const usage: Record<string, number> = {}
        for (const r of rows) {
            let n = 0
            for (const ref of d.referencedBy) {
                const c = await supabase.from(ref.table)
                    .select(ref.column, { count: 'exact', head: true }).eq(ref.column, r.code)
                // 【查不到不是零】—— 数错了会让人以为"没人用",然后放心停用。
                if (c.error) throw new Error(`用量查询失败(${ref.table}): ${c.error.message}`)
                n += c.count ?? 0
            }
            usage[r.code] = n
        }
        sections.push({ spec: d, rows, usage })
    }

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

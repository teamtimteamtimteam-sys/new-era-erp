'use client'

// MES-3a(2026-10-06,MES-0 Q32 · V29;MES-3a Step 0 Q4 · Q12,Tim):这个物料属于 NEA 执照上的哪一类废物 ——
//   库存上限按"执照 × 类别"判。【没有类别是一个要选的选项】("not set"),它的意思是"没人分过",
//   收货照收并记 category_not_set;不是 waste_classification_code(那一项决定货架收什么)。
//   类别列表从 /settings/dictionaries 来;一类都没有时这里只有"not set"那一项,下面一句话说出来。
import { useTranslations } from '@/lib/i18n/client'
import { CONTROL_SELECT } from '@/app/components/ui/control-style'

import { NEA_CATEGORY_NOT_SET, type NeaCategory } from './neaCategoryOptions'
export type { NeaCategory }

export default function NeaCategoryPicker({ categories, defaultValue, locale }: {
    categories: NeaCategory[]
    defaultValue: string | null
    locale: string
}) {
    const t = useTranslations()
    return (
        <div>
            <label className="block mb-1">{t('materials.form.neaCategory')}</label>
            <select name="nea_waste_category_code" defaultValue={defaultValue ?? NEA_CATEGORY_NOT_SET} className={`${CONTROL_SELECT} w-full`}>
                <option value={NEA_CATEGORY_NOT_SET}>{t('materials.form.neaCategoryNotSet')}</option>
                {categories.map((c) => (
                    <option key={c.code} value={c.code}>{c.code} · {locale === 'zh' ? c.name_zh : c.name_en}</option>
                ))}
            </select>
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                {categories.length === 0 ? t('materials.form.neaCategoryNone') : t('materials.form.neaCategoryHint')}
            </p>
        </div>
    )
}

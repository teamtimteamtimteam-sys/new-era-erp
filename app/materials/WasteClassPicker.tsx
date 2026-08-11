'use client'

// MAT-1:受控废物分类选择器。物料的新增页与编辑页共用一个。
//
// 【「未分类」是一个明写的选项】它的意思是"没有人分过类",与「非重点物料」
// (有人分过、结论是不受控)在合规判断上不是一回事 —— 所以它出现在下拉里,
// 而不是"不选就是它"。
import { useTranslations } from '@/lib/i18n/client'
import { WASTE_CLASS_UNCLASSIFIED, type WasteClass } from './wasteClassOptions'

export default function WasteClassPicker({
    name, classes, defaultValue, locale,
    className = 'w-full border border-gray-300 px-3 py-2 rounded',
}: {
    name: string
    classes: WasteClass[]
    defaultValue: string | null
    locale: string
    className?: string
}) {
    const t = useTranslations()
    return (
        <select name={name} defaultValue={defaultValue ?? WASTE_CLASS_UNCLASSIFIED} className={className}>
            {/* 未分类排在最前:它是既有物料的状态,也是"还没判断"的诚实答案 */}
            <option value={WASTE_CLASS_UNCLASSIFIED}>{t('materials.wasteClass.unclassified')}</option>
            {classes.map((c) => (
                <option key={c.code} value={c.code}>
                    {locale === 'zh' ? c.name_zh : c.name_en}
                    {c.is_controlled ? ` — ${t('materials.wasteClass.controlled')}` : ''}
                </option>
            ))}
        </select>
    )
}

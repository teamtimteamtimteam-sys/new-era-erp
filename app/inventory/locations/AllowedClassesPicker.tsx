'use client'

// LOC-1:允许存放的分类 —— 多选。清单从 waste_classifications 现读(加一种分类
// 是往那张表加一行,不是改这个文件)。
//
// 【一个都不勾是合法的,而且要当场说出它的意思】空集合 = 未配置 = 还没有人
// 决定,不是"不允许任何分类"。所以这里不做"至少选一个"的校验,而是在勾数
// 归零的那一刻把那句话显示出来 —— 让人在保存之前就看见自己留下的是哪一种状态。
import { useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import type { WasteClass } from '@/app/materials/wasteClassOptions'

export default function AllowedClassesPicker({
    classes,
    defaultSelected,
    locale,
}: {
    classes: WasteClass[]
    defaultSelected: string[]
    locale: string
}) {
    const t = useTranslations()
    const [selected, setSelected] = useState<string[]>(defaultSelected)

    const toggle = (code: string) =>
        setSelected((s) => (s.includes(code) ? s.filter((x) => x !== code) : [...s, code]))

    return (
        <div>
            <label className="block text-sm font-medium mb-1">{t('locations.form.allowedClasses')}</label>
            <p className="text-xs text-gray-500 mb-2">{t('locations.form.allowedClassesHint')}</p>

            <div className="space-y-2">
                {classes.map((c) => (
                    <label key={c.code} className="flex items-center gap-2 text-sm">
                        <input
                            type="checkbox"
                            checked={selected.includes(c.code)}
                            onChange={() => toggle(c.code)}
                        />
                        <span>{locale === 'zh' ? c.name_zh : c.name_en}</span>
                        <span className="text-gray-400 font-mono text-xs">{c.code}</span>
                        {/* 受控与否是这一类的语义,合规逻辑读的是它 —— 标出来,
                            免得人以为"重点/非重点"只是两个名字 */}
                        {c.is_controlled && (
                            <span className="px-2 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                                {t('locations.form.controlled')}
                            </span>
                        )}
                    </label>
                ))}
            </div>

            {/* 提交用的隐藏字段:勾选集合就是提交集合 */}
            {selected.map((code) => (
                <input key={code} type="hidden" name="allowed_class" value={code} />
            ))}

            {/* 【空集合当场自报是哪一种状态】 */}
            {selected.length === 0 && (
                <p className="mt-3 text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                    {t('locations.form.unconfiguredWarning')}
                </p>
            )}
        </div>
    )
}

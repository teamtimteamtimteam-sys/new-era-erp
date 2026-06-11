'use client'

import { useState } from 'react'
import { CUSTOM_VALUE } from './options'

export default function CustomSelect({
    name,
    label,
    options,
    required,
    defaultValue,
}: {
    name: string
    label: string
    options: string[]
    required?: boolean
    defaultValue?: string
}) {
    // 如果 defaultValue 不在 options 里,说明上次存的是自定义值
    const isCustom = !!defaultValue && !options.includes(defaultValue)

    const [selected, setSelected] = useState<string>(() => {
        if (!defaultValue) return ''
        return isCustom ? CUSTOM_VALUE : defaultValue
    })
    const [customText, setCustomText] = useState<string>(() =>
        isCustom ? defaultValue! : ''
    )

    // 实际提交给 formData 的值:选了"其他"就用自定义文本,否则用 select 的值
    const submittedValue = selected === CUSTOM_VALUE ? customText : selected

    return (
        <div className="space-y-2">
            <label className="block text-sm font-medium mb-1">
                {label} {required && <span className="text-red-600">*</span>}
            </label>

            <select
                value={selected}
                onChange={(e) => setSelected(e.target.value)}
                required={required}
                className="w-full border border-gray-300 px-3 py-2 rounded"
            >
                <option value="" disabled>
                    请选择{label}
                </option>
                {options.map((opt) => (
                    <option key={opt} value={opt}>
                        {opt}
                    </option>
                ))}
            </select>

            {selected === CUSTOM_VALUE && (
                <input
                    type="text"
                    value={customText}
                    onChange={(e) => setCustomText(e.target.value)}
                    placeholder={`请输入${label}`}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
            )}

            {/* 真正提交的字段(隐藏)*/}
            <input type="hidden" name={name} value={submittedValue} />
        </div>
    )
}

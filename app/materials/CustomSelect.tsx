'use client'

import { useState } from 'react'

type SelectOption = { value: string; label: string }

export default function CustomSelect({
    name,
    label,
    placeholder,
    options,
    customValue,
    customInputPlaceholder,
    required,
    defaultValue,
}: {
    name: string
    label: string
    placeholder: string
    options: SelectOption[]
    customValue: string
    customInputPlaceholder: string
    required?: boolean
    defaultValue?: string
}) {
    // 如果 defaultValue 不在 options 里,说明上次存的是自定义值
    const isCustom =
        !!defaultValue && !options.some((o) => o.value === defaultValue)

    const [selected, setSelected] = useState<string>(() => {
        if (!defaultValue) return ''
        return isCustom ? customValue : defaultValue
    })
    const [customText, setCustomText] = useState<string>(() =>
        isCustom ? defaultValue! : ''
    )

    // 实际提交给 formData 的值:选了"其他"就用自定义文本,否则用 select 的值
    const submittedValue = selected === customValue ? customText : selected

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
                    {placeholder}
                </option>
                {options.map((opt) => (
                    <option key={opt.value} value={opt.value}>
                        {opt.label}
                    </option>
                ))}
            </select>

            {selected === customValue && (
                <input
                    type="text"
                    value={customText}
                    onChange={(e) => setCustomText(e.target.value)}
                    placeholder={customInputPlaceholder}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
            )}

            {/* 真正提交的字段(隐藏)*/}
            <input type="hidden" name={name} value={submittedValue} />
        </div>
    )
}

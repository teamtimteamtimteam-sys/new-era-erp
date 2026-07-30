'use client'

// 受控小数输入框。
//
// 为什么不用 <input type="number">:number 输入框的 value 取值器遵循 HTML 规范 ——
// 缓冲区里不是一个合法浮点数时一律返回 ""。于是"975."(用户刚敲完小数点)会被
// 读成 "",受控回环把小数点抹掉,用户永远打不出 975.50。step="any" 救不了这个,
// 因为问题出在取值而不是校验。
//
// 这里改用 type="text" + inputMode="decimal"(移动端仍出数字键盘),自己放行
// /^-?\d*\.?\d*$/,于是 ""、"-"、"975."、"." 这些中间态都能原样保留。
// 父组件【始终持有原始字符串】;需要数字的地方用 parseDecimal。
// 给了 name 时额外渲染一个同名 hidden input,保证 <form action> 的非受控提交照常拿到值。

import type { ChangeEvent } from 'react'

// 允许的中间态:空、单个负号、单个小数点、以及任意"数字/小数点"组合
const DECIMAL_RE = /^-?\d*\.?\d*$/

// 把原始字符串转成数字;空值与"还没成形"的输入返回 null(由调用方决定怎么处理)。
// 注意 "975." 视为 975 —— 它已经有确定的数值,只是用户还没敲完小数位。
export function parseDecimal(raw: string): number | null {
    const s = (raw ?? '').trim()
    if (s === '' || s === '-' || s === '.' || s === '-.') return null
    const n = Number(s)
    return Number.isFinite(n) ? n : null
}

export default function DecimalInput({
    value,
    onChange,
    allowNegative = false,
    name,
    required,
    placeholder,
    className,
    id,
    disabled,
}: {
    value: string
    onChange: (raw: string) => void
    allowNegative?: boolean
    name?: string
    required?: boolean
    placeholder?: string
    className?: string
    id?: string
    disabled?: boolean
}) {
    function handleChange(e: ChangeEvent<HTMLInputElement>) {
        const raw = e.target.value
        if (raw === '') {
            onChange('')
            return
        }
        // 不合规的按键直接丢弃(不回写 state,输入框保持原样)
        if (!DECIMAL_RE.test(raw)) return
        if (!allowNegative && raw.startsWith('-')) return
        onChange(raw)
    }

    return (
        <>
            <input
                type="text"
                inputMode="decimal"
                value={value}
                onChange={handleChange}
                required={required}
                placeholder={placeholder}
                className={className}
                id={id}
                disabled={disabled}
            />
            {/* 提交用:可见框不带 name,值由这个 hidden input 携带(disabled 时一并不提交)*/}
            {name && <input type="hidden" name={name} value={value} disabled={disabled} />}
        </>
    )
}

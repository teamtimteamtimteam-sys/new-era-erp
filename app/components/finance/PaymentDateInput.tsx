'use client'

// app/components/finance/PaymentDateInput.tsx
// PAY-REQ-1(2026-09-23):付款日期那一格,两处共用 —— 收付款登记表(/finance/payments/new)
// 与付款申请的「付款」面板(/finance/payment-requests/[id])。
//
// 【为什么抽出来,而不是在申请页上再写一个原生日期框】
// scripts/check-date-format.mjs 的维度③只许原生日期控件【变少】(DATE-0 那一刀之前的债
// 不再长)。付款日是同一件事的同一格 —— 决定期间与汇率,必填,绝不替人填 ——
// 所以它应当是【一个】控件,而不是两份各自记得 onBlur 的副本。
//
// 【onBlur 也写回】React 不会拿受控输入的 value 与活的 DOM 对账:一个"看起来填好了"的
// 日期框可以提交出空串(AGENTS.md「Dates and amounts that decide a period」)。
// 失焦时再读一次 DOM,是 NewPaymentForm 原来就有的那一道,原样搬过来。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'

export function PaymentDateInput({
    name,
    value,
    onChange,
    className,
}: {
    name: string
    value: string
    onChange: (v: string) => void
    className?: string
}) {
    return (
        <input
            type="date"
            name={name}
            required
            value={value}
            onChange={(e) => onChange(e.target.value)}
            onBlur={(e) => onChange(e.target.value)}
            className={className ?? CONTROL_INPUT}
        />
    )
}

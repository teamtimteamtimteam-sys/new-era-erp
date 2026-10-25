'use client'

// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-1(Tim 2026-10-25 Q10)· 一块被禁用的区域里,表格的【只读】控件照样按得下去
// ════════════════════════════════════════════════════════════════════════════
// 【问题】结束了的记录(EndedFieldset)、缺权限的区域(PermissionGate / TaskEditGate)、被锁住的面板
//   (MetalContentPanel · PricingPanel)都用 `<fieldset disabled>` —— 那是对的:里面的写入一个都不该按得下去。
//   ★ 而 HTML 的规矩是【子树里每一个表单控件】都被禁用(button / input / select / textarea),
//   与它做什么无关 —— 于是表格的导出、排序、翻页也一起灰掉。一份结束了的记录恰恰是最常被拿去存档的那一种。
//   TABLE-EXPORT-3c 量到的(登记为 EXPORT-DISABLED-ON-ENDED-RECORDS):12 个结束块(约 38 处导出)、
//   5 处缺权限、1 份活着的记录(MetalContentPanel)。
//
// 【为什么不是"把表挪到 fieldset 外面"】很多块里,表格本身带着写入控件(删一行、撤回)—— 挪出去,那些就不灰了。
// 【为什么不是 inert / pointer-events】那会把只读控件一起挡掉,方向反了。
// 【HTML 唯一的豁免】是那个 fieldset 的【第一个 legend】—— 一块里只有一个,装不下几张表。
//
// ☞ 所以:**禁用块告诉它里面的组件「你在一块被禁用的区域里」**(本文件的 context),
//   表格层的只读控件(导出 · 客户端排序 · 翻页)在那时改画成一个【不是表单控件】的 `<span role="button">` ——
//   fieldset 管不到它,读屏照样念「按钮」,键盘照样能按(Enter / 空格)。
//   ★ 写入控件不受任何影响:它们不读这个 context,照旧被 fieldset 禁用。
//
// ⚠【做不到的一件,照直写】表格自带的文字筛选框是一个 `<input>` —— 它没有「不是表单控件」的替身,
//   在禁用块里它仍然是灰的。今天线上 0 张生产表开着它(TABLE-FEATURES-1 Step 0:只有 brand-sampler)。
//   登记在 docs/known-issues.md 的 TABLE-SEARCH-IN-DISABLED-BLOCK。
//
// ★ 仓库里所有 `<fieldset disabled>` 都必须经 `<DisabledBlock>`(scripts/check-disabled-block.mjs,进 npm run build)——
//   一处手写的 fieldset 会把它里面的表格悄悄带回「导出是灰的」。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { Button } from '@/app/components/ui/button'

const DisabledScope = React.createContext(false)

/** 这个组件是不是坐在一块被禁用的区域里。 */
export function useInDisabledBlock(): boolean {
    return React.useContext(DisabledScope)
}

/**
 * `<fieldset disabled>` 的唯一写法。`disabled` 为假时仍然画一个 fieldset(与原来几处 `disabled={!!x}` 的写法同形),
 * 只是那时 context 为假。其余属性原样传给 fieldset。
 */
export function DisabledBlock({
    disabled, children, ...rest
}: { disabled: boolean; children: React.ReactNode } & Omit<React.ComponentProps<'fieldset'>, 'disabled' | 'children'>) {
    return (
        // ★ 仓库里唯一一处手写的 <fieldset disabled>(check-disabled-block.mjs 认这一个文件)
        <fieldset disabled={disabled} {...rest}>
            <DisabledScope.Provider value={disabled}>{children}</DisabledScope.Provider>
        </fieldset>
    )
}

/**
 * 表格层的【只读】按钮:平时是一颗普通的 `<Button type="button">`;在禁用块里是一颗同样外观的 `<span role="button">`,
 * fieldset 禁不掉它。**只给不写库的控件用**(导出、排序、翻页)—— 写入控件一律用普通的 Button,让 fieldset 管住它。
 */
export function ReadOnlyButton({
    onClick, disabled = false, children, className, variant, size, ...aria
}: {
    onClick: () => void
    disabled?: boolean
    children: React.ReactNode
    className?: string
    variant?: React.ComponentProps<typeof Button>['variant']
    size?: React.ComponentProps<typeof Button>['size']
    'aria-label'?: string
    'aria-expanded'?: boolean
}) {
    const inBlock = useInDisabledBlock()
    if (!inBlock) {
        return (
            <Button type="button" variant={variant} size={size} className={className} disabled={disabled} onClick={onClick} {...aria}>
                {children}
            </Button>
        )
    }
    return (
        <Button asChild variant={variant} size={size} className={className}>
            <span
                role="button"
                tabIndex={disabled ? -1 : 0}
                aria-disabled={disabled || undefined}
                data-readonly-control=""
                onClick={() => { if (!disabled) onClick() }}
                onKeyDown={(e) => {
                    if (disabled) return
                    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick() }
                }}
                {...aria}
            >
                {children}
            </span>
        </Button>
    )
}

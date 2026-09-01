// BRAND-1(2026-09-02):shadcn/ui 的 class 合并器。
// twMerge 负责【后面的 Tailwind 类覆盖前面同族的类】—— 没有它,
// `cn('px-2','px-4')` 会两条都留着,由 CSS 顺序决定胜负,那是不可预测的。
import { clsx, type ClassValue } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
    return twMerge(clsx(inputs))
}

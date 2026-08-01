// app/components/MaskedValue.tsx
// 被字段级遮蔽(cut 2b)置空的数字,统一由这里渲染。
//
// 遮蔽视图对没有相应 data.* 权限的人把敏感列返回 null。而 null 在本系统里本来
// 就有别的含义(未分摊 / 未填 / 未定价),所以【不能】一律留白 —— 留白看起来像
// 缺数据,显示 0 更是撒谎。因此:
//   canView = false  → 灰字「受限」
//   canView = true   → 交给调用方的格式化结果(null 时仍是原本的空白或「—」)
'use client'

import { useTranslations } from '@/lib/i18n/client'

export function MaskedValue({
    value,
    canView,
    format,
    fallback = '',
}: {
    value: number | string | null | undefined
    canView: boolean
    format?: (v: never) => string
    /** canView 为真且 value 为空时显示什么(沿用各页原本的空白或「—」) */
    fallback?: string
}) {
    const t = useTranslations()
    if (!canView && (value === null || value === undefined)) {
        return (
            <span className="text-gray-400 italic" title={t('common.restricted')}>
                {t('common.restricted')}
            </span>
        )
    }
    if (value === null || value === undefined) return <>{fallback}</>
    return <>{format ? format(value as never) : String(value)}</>
}

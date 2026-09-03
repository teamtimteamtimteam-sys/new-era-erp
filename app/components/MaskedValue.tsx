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
import { Refusal } from '@/app/components/ui/refusal'

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
    // ★【CONV-0 ①:这一句从 `text-gray-400 italic` 换成 <Refusal>】★
    //   这是本刀最省力的一处收敛:改这一个文件,10 个已上线文件的「受限」当场统一
    //   (另 4 个走 ActorName)。**词一个字没变** —— 漂的从来是颜色,不是词。
    //   【看得见的变化】此前它是一行灰斜体,和"没填"「—」长得几乎一样;
    //   现在它是一枚带边的小药丸,一眼看得出这是【一句答复】而不是一处空缺。
    //   这正是 lib/permissions.ts 存在的那条理由在屏幕上的样子:受限不是零。
    if (!canView && (value === null || value === undefined)) {
        //   (原来那个 title 与可见文字【一字不差】—— 一个重复可见文字的 tooltip
        //    不是信息,所以没有搬过来。<Refusal> 的 why 留给真正解释得了
        //    「为什么看不到」的那一句,这里没有那一句。)
        return <Refusal>{t('common.restricted')}</Refusal>
    }
    if (value === null || value === undefined) return <>{fallback}</>
    return <>{format ? format(value as never) : String(value)}</>
}

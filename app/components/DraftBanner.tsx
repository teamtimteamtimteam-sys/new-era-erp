'use client'

// app/components/DraftBanner.tsx
// 草稿留存【看得见的那一面】。四种状态,每一种说一句不同的话。
//
// 【为什么恢复必须由人点一下,而不是自动填上】(IDLE-DRAFT 4.2)
// 一张自己把格子填满的表单,是一次【预填】穿着【救援】的外衣。本仓库对这两者
// 的规矩是:**看得见、改得动的预填是一次选择;悄悄填上的是一个错误答案。**
// 所以这里永远是"发现了一份草稿" + 一个按钮,而不是把值直接写进去。
// 套用之后那句"这些格子来自一份草稿"【不消失】,一直显示到提交为止。
import { useTranslations } from '@/lib/i18n/client'
import type { DraftState } from '@/lib/useFormDraft'
import { Button } from '@/app/components/ui/button'

function when(ts: number, locale: string) {
    return new Date(ts).toLocaleString(locale === 'en' ? 'en-SG' : 'zh-SG', {
        month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
    })
}

export default function DraftBanner({ draft, locale = 'zh' }: { draft: DraftState; locale?: string }) {
    const t = useTranslations()

    // ① 受限表单:**在人开始打字【之前】就说清楚**,不是事后才发现没留住。
    if (draft.restricted && !draft.found && !draft.restored) {
        return (
            <p data-draft="restricted-notice"
               className="text-xs text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-3">
                {t('draft.restrictedNotice')}
            </p>
        )
    }

    // ② 主语变了 —— 不给套用,并且说出为什么
    if (draft.found && draft.stale) {
        return (
            <div data-draft="stale"
                 className="text-sm bg-amber-50 border border-amber-300 rounded px-3 py-2 mb-3">
                <p className="text-amber-900 mb-2">
                    {t('draft.staleFound', { when: when(draft.found.at, locale) })}
                </p>
                <Button variant="secondary" size="xs" type="button" onClick={draft.discard}>
                    {t('draft.discard')}
                </Button>
            </div>
        )
    }

    // ③ 发现一份可用的草稿
    if (draft.found) {
        return (
            <div data-draft="found"
                 className="text-sm bg-blue-50 border border-blue-300 rounded px-3 py-2 mb-3">
                <p className="text-blue-900 mb-1">
                    {t('draft.found', { when: when(draft.found.at, locale) })}
                </p>
                <p className="text-xs text-blue-800 mb-2">
                    {draft.restricted ? t('draft.whereSession') : t('draft.whereDevice')}
                </p>
                <div className="flex gap-2">
                    <Button size="xs" type="button" onClick={draft.restore}>
                        {t('draft.restore')}
                    </Button>
                    <Button variant="secondary" size="xs" type="button" onClick={draft.discard}>
                        {t('draft.discard')}
                    </Button>
                </div>
            </div>
        )
    }

    // ④ 已经套用过 —— 这句话【不消失】,直到提交
    if (draft.restored) {
        return (
            <div data-draft="restored"
                 className="text-sm bg-blue-50 border border-blue-300 rounded px-3 py-2 mb-3">
                <p className="text-blue-900 mb-2">{t('draft.restoredNotice')}</p>
                <Button variant="secondary" size="xs" type="button" onClick={draft.discard}>
                    {t('draft.discardRestored')}
                </Button>
            </div>
        )
    }

    return null
}

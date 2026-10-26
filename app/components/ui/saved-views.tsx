'use client'
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-3(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3)· 保存的视图 —— 有筛选的 28 张列表共用这一个
// ════════════════════════════════════════════════════════════════════════════
// 一排:「视图」· 本人在这张列表上存过的每一个视图(链接;当前地址就是它时画成当前态;默认的那个带 ★)·「plain list」·「保存视图」。
// 下面一个可展开的「管理视图」:每一个视图 设为默认 / 取消默认 · 删除。
//   · 存:当前地址(筛选 + 排序,包括浏览器里排的那几张表写进地址的 <前缀>sort/dir)经 lib/savedViews.ts encodeViewQuery
//     去掉翻页与一次性参数;日期正好是一个快捷区间 → 存区间的名字(Q2)。同名即覆盖。
//   · 打开:viewHref —— 区间名按今天(服务端算好的 presets)写回两个日期。
//   · plain list:地址带 view=plain,默认视图不套用(Q3);页面自己不读那个键。
// 以后有一张列表长出筛选,它照样经这一个组件拿到视图(Q1)。
import * as React from 'react'
import Link from 'next/link'
import { usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { Input } from '@/app/components/ui/input'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { encodeViewQuery, viewHref, PLAIN_LIST_PARAM, PLAIN_LIST_VALUE, type SavedView, type ViewDates } from '@/lib/savedViews'
import { saveView, deleteView, setDefaultView } from '@/app/components/ui/saved-view-actions'
import { cn } from '@/lib/utils'

export function SavedViewsBar({ listKey, views, dates, className }: {
    /** 这张列表的路由(/finance/expenses)—— 也是 saved_views.list_key。 */
    listKey: string
    views: readonly SavedView[]
    /** 带起止日期的列表:两个键名与当天的四个区间(Q2)。 */
    dates?: ViewDates
    className?: string
}) {
    const t = useTranslations()
    const pathname = usePathname()
    const sp = useSearchParams()
    const [naming, setNaming] = React.useState(false)
    const [name, setName] = React.useState('')
    const [nameError, setNameError] = React.useState<string | null>(null)
    const [pending, startTransition] = React.useTransition()
    const nameId = React.useId()

    // 浏览器里排的表用 replaceState 改地址 —— useSearchParams 跟着变(Next 16),于是"当前是哪个视图"与"存什么"都读得到它
    const current = encodeViewQuery(sp.toString(), dates)
    const isPlain = sp.get(PLAIN_LIST_PARAM) === PLAIN_LIST_VALUE

    const report = (subject: string, headline: string, res: { error?: string; detail?: string }) =>
        showActionMessage({ subject, headline, body: res.error, detail: res.detail })

    const save = () => {
        const n = name.trim()
        if (n === '') { setNameError(t('savedViews.nameRequired')); return }
        startTransition(async () => {
            const res = await saveView(listKey, n, current)
            if (res.error) {
                if (res.field === 'name') setNameError(res.error)
                else report(n, t('savedViews.notSavedHeadline'), res)
                return
            }
            setNaming(false); setName(''); setNameError(null)
        })
    }

    return (
        <div data-slot="saved-views" className={cn('mb-3 space-y-2 text-sm', className)}>
            <nav aria-label={t('savedViews.label')} className="flex flex-wrap items-center gap-2">
                <span className="text-[color:var(--brand-muted-text)]">{t('savedViews.label')}</span>
                {views.map((v) => {
                    const active = !isPlain && v.query === current
                    return (
                        <Link
                            key={v.id}
                            href={viewHref(listKey, v.query, dates)}
                            data-view-name={v.name}
                            data-view-default={v.is_default ? 'true' : undefined}
                            aria-current={active ? 'true' : undefined}
                            className={cn('rounded border px-2 py-1 app-link break-all', active && 'font-bold')}
                        >
                            {v.is_default && <span aria-label={t('savedViews.defaultMark')}>★ </span>}
                            {v.name}
                        </Link>
                    )
                })}
                <Link
                    href={`${pathname}?${PLAIN_LIST_PARAM}=${PLAIN_LIST_VALUE}`}
                    data-view-plain="true"
                    aria-current={isPlain ? 'true' : undefined}
                    className={cn('rounded border px-2 py-1 app-link', isPlain && 'font-bold')}
                >
                    {t('savedViews.plainList')}
                </Link>
                {!naming && (
                    <Button type="button" variant="outline" size="sm" onClick={() => setNaming(true)} data-view-save="open">
                        {t('savedViews.save')}
                    </Button>
                )}
            </nav>

            {naming && (
                <div className="flex flex-wrap items-start gap-2">
                    <label htmlFor={nameId} className="sr-only">{t('savedViews.nameLabel')}</label>
                    <div className="max-w-full">
                        <Input
                            id={nameId}
                            value={name}
                            maxLength={60}
                            placeholder={t('savedViews.namePlaceholder')}
                            aria-invalid={nameError ? true : undefined}
                            onChange={(e) => { setName(e.target.value); setNameError(null) }}
                            onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); save() } }}
                            data-view-save="name"
                        />
                        {nameError && <p className="mt-1 text-red-700" role="alert">{nameError}</p>}
                    </div>
                    <Button type="button" size="sm" disabled={pending} onClick={save} data-view-save="confirm">
                        {t('savedViews.saveConfirm')}
                    </Button>
                    <Button type="button" variant="ghost" size="sm" onClick={() => { setNaming(false); setName(''); setNameError(null) }}>
                        {t('common.cancel')}
                    </Button>
                    <p className="basis-full text-xs text-[color:var(--brand-muted-text)]">{t('savedViews.saveHint')}</p>
                </div>
            )}

            {views.length > 0 && (
                <details>
                    <summary className="cursor-pointer text-[color:var(--brand-muted-text)]">{t('savedViews.manage')}</summary>
                    <ul className="mt-2 space-y-1">
                        {views.map((v) => (
                            <li key={v.id} className="flex flex-wrap items-center gap-2" data-view-manage={v.name}>
                                <span className="break-all">{v.name}</span>
                                {v.is_default && <span className="text-[color:var(--brand-muted-text)]">{t('savedViews.isDefault')}</span>}
                                <Button
                                    type="button" variant="outline" size="xs" disabled={pending}
                                    data-view-action={v.is_default ? 'clear-default' : 'set-default'}
                                    onClick={() => startTransition(async () => {
                                        const res = await setDefaultView(listKey, v.is_default ? null : v.id)
                                        if (res.error) report(v.name, t('savedViews.defaultNotSetHeadline'), res)
                                    })}
                                >
                                    {v.is_default ? t('savedViews.clearDefault') : t('savedViews.setDefault')}
                                </Button>
                                <ConfirmButton
                                    subject={v.name}
                                    title={t('savedViews.deleteTitle')}
                                    confirmLabel={t('savedViews.delete')}
                                    tier="destructive"
                                    triggerVariant="outline"
                                    triggerSize="xs"
                                    disabled={pending}
                                    onConfirm={() => startTransition(async () => {
                                        const res = await deleteView(listKey, v.id)
                                        if (res.error) report(v.name, t('savedViews.notDeletedHeadline'), res)
                                    })}
                                >
                                    {t('savedViews.delete')}
                                </ConfirmButton>
                            </li>
                        ))}
                    </ul>
                </details>
            )}
        </div>
    )
}

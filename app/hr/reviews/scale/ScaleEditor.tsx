'use client'

// 评级档位编辑器 —— 与 LeaveTypesEditor 同一套路:行内编辑 + 底部新增卡。
// 停用而不删除(is_active);is_probation_pass 是【提示,不是规则】,
// 转正与否由评估单据上的 probation_outcome 明说。
//
// CONV-2:那张手写的 7 列表换成 <EditableTable>。
// ★【底部那张"新增一档"的卡【没有】进模板】★ —— 它不是网格的一部分:
//   它是一张【表单】,主语是"还不存在的那一行",所以它没有行键、没有草稿、
//   也没有可比较的原行。把新增塞进可编辑网格,会让那个 Record 里出现一个
//   假的行键(`'__new__'` 之类),而那正是 /settings/dictionaries 今天的写法 ——
//   见 docs/editable-grid-template.md §⑥,这是模板【做不到】的第一件事。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useLocale, useTranslations } from '@/lib/i18n/client'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'
import { saveRatingScale } from './actions'
import { Button } from '@/app/components/ui/button'

export type ScaleRow = {
    code: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    sort_order: number
    is_active: boolean
    is_probation_pass: boolean
}

type Draft = ScaleRow

const inp = 'w-full border border-gray-300 rounded px-1 py-0.5 text-xs'

export default function ScaleEditor({ rows }: { rows: ScaleRow[] }) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    const [nCode, setNCode] = useState('')
    const [nEn, setNEn] = useState('')
    const [nZh, setNZh] = useState('')
    const [nSort, setNSort] = useState('')

    const yesNo = (b: boolean) => (b ? t('permissions.yes') : t('permissions.no'))

    function add() {
        setError(null)
        startTransition(async () => {
            const r = await saveRatingScale(
                nCode.trim().toUpperCase(),
                {
                    name_en: nEn.trim(),
                    name_zh: nZh.trim(),
                    description_en: null,
                    description_zh: null,
                    sort_order: nSort.trim() === '' ? 0 : Number(nSort),
                    is_active: true,
                    is_probation_pass: false,
                },
                true
            )
            if (r.error) setError(r.error)
            else {
                setNCode(''); setNEn(''); setNZh(''); setNSort('')
                router.refresh()
            }
        })
    }

    const columns: EditableColumn<ScaleRow, Draft>[] = [
        {
            key: 'code',
            header: t('reviews.scaleCode'),
            priority: true,
            className: 'font-mono text-gray-500',
            render: (r) => r.code,
        },
        {
            key: 'name',
            header: t('reviews.scaleName'),
            priority: true,
            render: (r) => (locale === 'zh' ? r.name_zh : r.name_en),
            edit: (d, set) => (
                <>
                    <input value={d.name_en} className={inp + ' mb-1'} aria-label={t('permissions.nameEn')}
                           onChange={(e) => set({ name_en: e.target.value })} />
                    <input value={d.name_zh} className={inp} aria-label={t('permissions.nameZh')}
                           onChange={(e) => set({ name_zh: e.target.value })} />
                </>
            ),
        },
        {
            key: 'description',
            header: t('reviews.scaleDescription'),
            className: 'text-xs text-gray-600',
            render: (r) => (locale === 'zh' ? r.description_zh : r.description_en) ?? '—',
            edit: (d, set) => (
                <>
                    <input value={d.description_en ?? ''} className={inp + ' mb-1'} aria-label={t('reviews.scaleDescription') + ' (EN)'}
                           onChange={(e) => set({ description_en: e.target.value || null })} />
                    <input value={d.description_zh ?? ''} className={inp} aria-label={t('reviews.scaleDescription') + ' (中)'}
                           onChange={(e) => set({ description_zh: e.target.value || null })} />
                </>
            ),
        },
        {
            key: 'sort',
            header: t('reviews.scaleSort'),
            align: 'right',
            className: 'font-mono',
            render: (r) => r.sort_order,
            edit: (d, set) => (
                <input type="number" value={d.sort_order} className={inp + ' text-right'} aria-label={t('reviews.scaleSort')}
                       onChange={(e) => set({ sort_order: Number(e.target.value) })} />
            ),
        },
        {
            key: 'active',
            header: t('reviews.scaleActive'),
            render: (r) => yesNo(r.is_active),
            edit: (d, set) => (
                <input type="checkbox" checked={d.is_active} aria-label={t('reviews.scaleActive')}
                       onChange={(e) => set({ is_active: e.target.checked })} />
            ),
        },
        {
            key: 'probationPass',
            header: t('reviews.scaleProbationPass'),
            render: (r) => yesNo(r.is_probation_pass),
            edit: (d, set) => (
                <input type="checkbox" checked={d.is_probation_pass} aria-label={t('reviews.scaleProbationPass')}
                       onChange={(e) => set({ is_probation_pass: e.target.checked })} />
            ),
        },
    ]

    return (
        <div>
            {/* 新增那张卡自己的错误仍然画在这里 —— 它不属于任何一行。
                【行的】错误由 EditableTable 画在那一行下面(role="alert")。 */}
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            <EditableTable<ScaleRow, Draft>
                className="mb-6"
                rows={rows}
                columns={columns}
                rowKey={(r) => r.code}
                phone={{ mode: 'columns' }}
                toDraft={(r) => ({ ...r })}
                // ★ 空态归【表】说,不归外壳 —— 因为把空态变成非空的那张卡
                //   就在这张表下面,而外壳的 empty 分支会把它一起藏掉。
                //   理由写在 page.tsx 的 state 那一处。
                empty={t('reviews.noScale')}
                labels={{
                    edit: t('reviews.edit'), save: t('common.save'), saving: t('common.saving'),
                    cancel: t('common.cancel'), unsaved: t('common.unsavedRow'), expand: t('common.expandRow'),
                }}
                onSave={async (d) => {
                    const r = await saveRatingScale(
                        d.code,
                        {
                            name_en: d.name_en, name_zh: d.name_zh,
                            description_en: d.description_en, description_zh: d.description_zh,
                            sort_order: d.sort_order,
                            is_active: d.is_active,
                            is_probation_pass: d.is_probation_pass,
                        },
                        false
                    )
                    // ★ Q6:失败交回组件 —— 字留住、行留在编辑态、不刷新。
                    if (r.error) return { error: r.error }
                    startTransition(() => router.refresh())
                }}
            />

            {/* ── 新增一档:一张【表单】,不是网格的一行。见本文件抬头。 ───────── */}
            <div className="rounded border border-gray-200 p-4">
                <h3 className="font-bold mb-3 text-sm">{t('reviews.addScale')}</h3>
                <div className="flex gap-2 flex-wrap items-end">
                    <label className="text-xs">
                        {t('reviews.scaleCode')}
                        <input value={nCode} onChange={(e) => setNCode(e.target.value)}
                               className={`block ${inp} w-32 font-mono`} />
                    </label>
                    <label className="text-xs">
                        {t('permissions.nameEn')}
                        <input value={nEn} onChange={(e) => setNEn(e.target.value)} className={`block ${inp} w-40`} />
                    </label>
                    <label className="text-xs">
                        {t('permissions.nameZh')}
                        <input value={nZh} onChange={(e) => setNZh(e.target.value)} className={`block ${inp} w-40`} />
                    </label>
                    <label className="text-xs">
                        {t('reviews.scaleSort')}
                        <input type="number" value={nSort} onChange={(e) => setNSort(e.target.value)}
                               className={`block ${inp} w-20 text-right`} />
                    </label>
                    <Button size="sm"
                        type="button"
                        onClick={add}
                        disabled={pending || !nCode.trim() || !nEn.trim() || !nZh.trim()}
                    >
                        {t('common.save')}
                    </Button>
                </div>
            </div>
        </div>
    )
}

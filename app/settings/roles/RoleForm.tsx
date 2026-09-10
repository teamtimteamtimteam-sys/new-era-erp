'use client'

// app/settings/roles/RoleForm.tsx
// 角色本身的字段:码(建后不可改)、双语名与描述、启用、排序。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { createRole, updateRole, softDeleteRole } from '../accountsActions'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT, CONTROL_CHECKBOX } from '@/app/components/ui/control-style'

export type RoleFormValues = {
    id?: string
    code: string
    name_en: string
    name_zh: string
    description_en: string
    description_zh: string
    is_active: boolean
    sort_order: number
    is_system?: boolean
    user_count?: number
}

export default function RoleForm({ initial }: { initial: RoleFormValues }) {
    const t = useTranslations()
    const router = useRouter()
    const [v, setV] = useState(initial)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState(false)
    const isNew = !initial.id

    function save() {
        setError(null)
        setDone(false)
        startTransition(async () => {
            const res = isNew
                ? await createRole({
                      code: v.code.trim(),
                      name_en: v.name_en.trim(),
                      name_zh: v.name_zh.trim(),
                      description_en: v.description_en.trim() || null,
                      description_zh: v.description_zh.trim() || null,
                      sort_order: v.sort_order,
                  })
                : await updateRole(initial.id!, {
                      name_en: v.name_en.trim(),
                      name_zh: v.name_zh.trim(),
                      description_en: v.description_en.trim() || null,
                      description_zh: v.description_zh.trim() || null,
                      is_active: v.is_active,
                      sort_order: v.sort_order,
                  })
            if (res.error) setError(res.error)
            else if (isNew && 'roleId' in res && res.roleId) {
                router.push(`/settings/roles/${res.roleId}`)
            } else setDone(true)
        })
    }

    function remove() {
        setError(null)
        startTransition(async () => {
            const res = await softDeleteRole(initial.id!)
            if (res.error) setError(res.error)
            else router.push('/settings/roles')
        })
    }

    const field = `${CONTROL_INPUT} w-full`

    return (
        <div className="mb-8">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}
            {done && <p className="mb-3 text-sm text-green-700">{t('permissions.saved')}</p>}

            <div className="grid gap-4 md:grid-cols-2 mb-4">
                <label className="text-sm">
                    {t('permissions.roleCode')}
                    <input
                        value={v.code}
                        disabled={!isNew}
                        onChange={(e) => setV({ ...v, code: e.target.value })}
                        className={field + (isNew ? '' : ' bg-gray-100 text-gray-500')}
                    />
                    {/* 码是稳定标识:策略、函数、以及日后的授权导出都靠它对上号。
                        改一次码,等于把这个角色换成了另一个角色。 */}
                    <span className="mt-1 block text-xs text-gray-500">
                        {isNew ? t('permissions.codeHintNew') : t('permissions.codeHintLocked')}
                    </span>
                </label>
                <label className="text-sm">
                    {t('permissions.sortOrder')}
                    <input
                        type="number"
                        value={v.sort_order}
                        onChange={(e) => setV({ ...v, sort_order: Number(e.target.value) })}
                        className={field}
                    />
                </label>
                <label className="text-sm">
                    {t('permissions.nameEn')}
                    <input
                        value={v.name_en}
                        onChange={(e) => setV({ ...v, name_en: e.target.value })}
                        className={field}
                    />
                </label>
                <label className="text-sm">
                    {t('permissions.nameZh')}
                    <input
                        value={v.name_zh}
                        onChange={(e) => setV({ ...v, name_zh: e.target.value })}
                        className={field}
                    />
                </label>
                <label className="text-sm">
                    {t('permissions.descriptionEn')}
                    <input
                        value={v.description_en}
                        onChange={(e) => setV({ ...v, description_en: e.target.value })}
                        className={field}
                    />
                </label>
                <label className="text-sm">
                    {t('permissions.descriptionZh')}
                    <input
                        value={v.description_zh}
                        onChange={(e) => setV({ ...v, description_zh: e.target.value })}
                        className={field}
                    />
                </label>
            </div>

            {!isNew && (
                <label className="flex items-center gap-2 text-sm mb-4">
                    <input
                        type="checkbox"
                        className={CONTROL_CHECKBOX}
                        checked={v.is_active}
                        disabled={initial.is_system}
                        onChange={(e) => setV({ ...v, is_active: e.target.checked })}
                    />
                    {t('permissions.active')}
                    {initial.is_system && (
                        <span className="text-xs text-gray-500">
                            {t('permissions.systemRoleLocked')}
                        </span>
                    )}
                </label>
            )}

            <div className="flex items-center gap-3">
                <Button
                    type="button"
                    onClick={save}
                    disabled={pending}
                >
                    {pending ? t('common.saving') : t('common.save')}
                </Button>

                {/* ★★【MANUAL-FIX-1 F:这个钮从【撤销档】换成【破坏档】】★★
                    Tim 在本刀的闸上推翻了他自己委托书里那条「软删 → 虚线条正确」:
                    **档位由【人能不能撤回】定,不由【行怎么存】定。**
                    · softDeleteRole 确实只写 deleted_at + is_active=false;
                    · 但全仓库【没有任何一条恢复路径】(app/settings 里 restore /
                      undelete / deleted_at: null 三个写法各零处),而
                      app/settings/deleted/page.tsx:44 把这条写成了成文的立场:
                      「【永不提供恢复】…本页只读,连一个可写入口都没有。」
                    · button.tsx 抬头那条判据也不是软硬,是【动词形状】:
                      破坏档是 Delete/Void,撤销档是 Un-/Re-,而撤销档的定义是
                      「不删任何东西,审计痕迹全留着」。这个钮写着 Delete,
                      按下去每一个持有者【当场】失去这份权限(旁边那句
                      deleteWarnHolders 就是在说这件事)。
                    ☞ 画成虚线撤销档,等于教操作员「这一下可以撤回」——
                      而那句话是假的。button.tsx:41:「一条被教错的规则比没有更坏。」 */}
                {!isNew && !initial.is_system && (
                    <Button variant="destructive"
                        type="button"
                        onClick={remove}
                        disabled={pending}>
                        {t('common.delete')}
                    </Button>
                )}
                {/* ★ ALERT-2a:这个钮写着 Delete,做的是软删 —— 而它是本族里
                      【唯一没有确认框】的那一个,所以那句话只能长在这里。
                    ☞ 用的就是别处那八处确认框里同一个键 `common.softDeleteNote`,
                      本刀把它改准了:它此前写着「可以恢复」,而全仓库
                      **没有任何一条恢复路径**(见上面那段注释与
                      `app/settings/deleted/page.tsx` 抬头「永不提供恢复」)。
                      于是这一行与上面那段注释不再互相矛盾:记录留着、权限当场失去、
                      而没有人会去撤销它。 */}
                {!isNew && !initial.is_system && (
                    <span className="text-sm text-[color:var(--brand-muted-text)]">
                        {t('common.softDeleteNote')}
                    </span>
                )}
                {/* 还有人持有这个角色时,把人数说出来 —— 软删之后他们会立刻失去这份权限 */}
                {!isNew && !initial.is_system && (initial.user_count ?? 0) > 0 && (
                    <span className="text-sm text-amber-800">
                        {t('permissions.deleteWarnHolders', { 0: String(initial.user_count) })}
                    </span>
                )}
                {!isNew && initial.is_system && (
                    <span className="text-sm text-gray-500">
                        {t('permissions.systemRoleNoDelete')}
                    </span>
                )}
            </div>
        </div>
    )
}

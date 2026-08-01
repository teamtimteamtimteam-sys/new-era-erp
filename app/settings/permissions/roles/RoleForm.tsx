'use client'

// app/settings/permissions/roles/RoleForm.tsx
// 角色本身的字段:码(建后不可改)、双语名与描述、启用、排序。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { createRole, updateRole, softDeleteRole } from '../actions'

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
                router.push(`/settings/permissions/roles/${res.roleId}`)
            } else setDone(true)
        })
    }

    function remove() {
        setError(null)
        startTransition(async () => {
            const res = await softDeleteRole(initial.id!)
            if (res.error) setError(res.error)
            else router.push('/settings/permissions/roles')
        })
    }

    const field = 'w-full border border-gray-300 rounded px-2 py-1 text-sm'

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
                <button
                    type="button"
                    onClick={save}
                    disabled={pending}
                    className="bg-gray-900 text-white px-4 py-1.5 rounded text-sm disabled:opacity-50"
                >
                    {pending ? t('common.saving') : t('common.save')}
                </button>

                {!isNew && !initial.is_system && (
                    <button
                        type="button"
                        onClick={remove}
                        disabled={pending}
                        className="border border-red-300 text-red-700 px-3 py-1.5 rounded text-sm disabled:opacity-50"
                    >
                        {t('common.delete')}
                    </button>
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

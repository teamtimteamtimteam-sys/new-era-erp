'use client'

// app/settings/roles/PermissionMatrix.tsx
// 角色的授权编辑:模块矩阵(View / Edit)+ data.* / action.* 勾选表。
//
// 【edit 蕴含 view 在界面里也强制】:勾 Edit 自动勾上 View,取消 View 一并取消 Edit。
// 不是给一句警告就算 —— 2b 量过,只授 edit 不授 view 会让 PostgREST 的
// INSERT ... RETURNING 直接 42501,整条写入路径断掉。那是坏配置,不是口味问题。
// 数据库那一道(set_role_permissions 的 EDIT_REQUIRES_VIEW)才是真正的守卫,
// 这里只是让人不必先犯错再被拒。
import { useState, useTransition } from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { saveRolePermissions } from '../accountsActions'
import { Button } from '@/app/components/ui/button'
import { CONTROL_CHECKBOX } from '@/app/components/ui/control-style'

export type PermissionRow = {
    code: string
    category: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    sort_order: number
}

export default function PermissionMatrix({
    roleId,
    permissions,
    initial,
    disabled = false,
}: {
    roleId: string
    permissions: PermissionRow[]
    initial: string[]
    disabled?: boolean
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [codes, setCodes] = useState<string[]>(initial)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState(false)

    // 模块清单从目录里推导,不写死 —— 加一个模块只是往 permissions 表插两行
    const modules = Array.from(
        new Set(
            permissions
                .filter((p) => p.category === 'module')
                .map((p) => p.code.split('.')[1])
        )
    )
    const moduleMeta = (m: string) =>
        permissions.find((p) => p.code === `module.${m}.view`)

    // ★★【MANUAL-FIX-1 A:Edit 那一格【只在目录里真有这个码时】才画】★★
    //   此前这一列对每个模块【无条件】画一个勾选框,而模块清单是从任意
    //   module.* 码的中段推出来的 —— 于是 module.logistics.view 让物流有了一行,
    //   那一行的 Edit 框却对应着一个【不存在】的 module.logistics.edit。
    //   勾上它再保存,set_role_permissions 会以 PERMISSION_NOT_FOUND 拒掉
    //   【整次调用】—— 于是那一勾不只是没有生效,它还挡住了同一次保存里
    //   其它所有改动,而屏幕上没有一个字说明为什么。
    //   【不铸那个码,而是不画那一格】物流的写入【故意】挂在 module.purchasing.edit
    //   上(db/migrations/2026-09-01-navreg1-logistics-gets-its-own-code.sql:17-20:
    //   「铸一个没有任何策略引用的 module.logistics.edit,就是铸一个死码」)。
    //   目录是迁移级的,界面【不该能凭空造码】—— 那正是那条 RPC 守卫的原话。
    const catalogue = new Set(permissions.map((p) => p.code))
    const hasEditCode = (m: string) => catalogue.has(`module.${m}.edit`)

    const others = permissions
        .filter((p) => p.category !== 'module')
        .sort((a, b) => a.sort_order - b.sort_order)

    const has = (c: string) => codes.includes(c)

    function setModule(m: string, kind: 'view' | 'edit', on: boolean) {
        const view = `module.${m}.view`
        const edit = `module.${m}.edit`
        setCodes((cur) => {
            let next = cur.filter((c) => c !== view && c !== edit)
            const hadView = cur.includes(view)
            const hadEdit = cur.includes(edit)
            if (kind === 'view') {
                // 取消 View 时一并取消 Edit(edit 没有 view 会让写入路径断掉)
                if (on) next = [...next, view, ...(hadEdit ? [edit] : [])]
            } else {
                // 勾 Edit 时自动补上 View
                if (on) next = [...next, view, edit]
                else if (hadView) next = [...next, view]
            }
            return next
        })
    }

    function toggleOther(code: string) {
        setCodes((cur) => (cur.includes(code) ? cur.filter((c) => c !== code) : [...cur, code]))
    }

    function save() {
        setError(null)
        setDone(false)
        startTransition(async () => {
            const res = await saveRolePermissions(roleId, codes)
            if (res.error) setError(res.error)
            else setDone(true)
        })
    }

    return (
        <div>
            <h2 className="text-lg font-bold mb-1">{t('permissions.matrixTitle')}</h2>
            <p className="text-sm text-gray-500 mb-3">{t('permissions.editRequiresViewHint')}</p>

            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}
            {done && <p className="mb-3 text-sm text-green-700">{t('permissions.saved')}</p>}

            <table className="w-full border-collapse mb-6">
                <thead>
                    <tr className="bg-gray-50 text-left text-sm">
                        <th className="border border-gray-300 px-3 py-2">{t('permissions.module')}</th>
                        <th className="border border-gray-300 px-3 py-2 w-24 text-center">
                            {t('permissions.view')}
                        </th>
                        <th className="border border-gray-300 px-3 py-2 w-24 text-center">
                            {t('permissions.edit')}
                        </th>
                    </tr>
                </thead>
                <tbody>
                    {modules.map((m) => {
                        const meta = moduleMeta(m)
                        return (
                            <tr key={m} className="text-sm">
                                <td className="border border-gray-300 px-3 py-2">
                                    {meta
                                        ? (locale === 'zh' ? meta.name_zh : meta.name_en).replace(
                                              /\s*[(（](view|查看)[)）]\s*$/i,
                                              ''
                                          )
                                        : m}
                                    <span className="ml-2 font-mono text-xs text-gray-400">{m}</span>
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-center">
                                    <input
                                        type="checkbox"
                                        className={CONTROL_CHECKBOX}
                                        disabled={disabled}
                                        checked={has(`module.${m}.view`)}
                                        onChange={(e) => setModule(m, 'view', e.target.checked)}
                                    />
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-center">
                                    {/* 目录里没有这个码 = 这个模块【没有】编辑这一档权限。
                                        画一条短横而不是留空:空格读起来像"还没勾",
                                        短横读起来像"这里没有这样东西"。 */}
                                    {hasEditCode(m) ? (
                                        <input
                                            type="checkbox"
                                            className={CONTROL_CHECKBOX}
                                            disabled={disabled}
                                            checked={has(`module.${m}.edit`)}
                                            onChange={(e) => setModule(m, 'edit', e.target.checked)}
                                        />
                                    ) : (
                                        <span className="text-gray-400" title={t('permissions.noEditCapability')}>
                                            —
                                        </span>
                                    )}
                                </td>
                            </tr>
                        )
                    })}
                </tbody>
            </table>

            <h3 className="font-bold mb-1">{t('permissions.dataAndActions')}</h3>
            {/* 描述【就是重点】—— 要授出 data.view_pay 的人,应当先读到它到底泄露什么。 */}
            <p className="text-sm text-gray-500 mb-3">{t('permissions.dataAndActionsHint')}</p>
            <div className="space-y-2 mb-6">
                {others.map((p) => (
                    <label
                        key={p.code}
                        className="flex gap-3 items-start border border-gray-200 rounded px-3 py-2"
                    >
                        <input
                            type="checkbox"
                            disabled={disabled}
                            className={`${CONTROL_CHECKBOX} mt-1`}
                            checked={has(p.code)}
                            onChange={() => toggleOther(p.code)}
                        />
                        <span className="text-sm">
                            <span className="font-medium">
                                {locale === 'zh' ? p.name_zh : p.name_en}
                            </span>
                            <span className="ml-2 font-mono text-xs text-gray-400">{p.code}</span>
                            <span className="block text-gray-600">
                                {(locale === 'zh' ? p.description_zh : p.description_en) ?? ''}
                            </span>
                        </span>
                    </label>
                ))}
            </div>

            <Button
                type="button"
                onClick={save}
                disabled={pending || disabled}
            >
                {pending ? t('common.saving') : t('permissions.savePermissions')}
            </Button>
        </div>
    )
}

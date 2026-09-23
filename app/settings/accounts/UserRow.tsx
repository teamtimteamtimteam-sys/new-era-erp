'use client'

// app/settings/accounts/UserRow.tsx
// 一个系统账号一行,展开后是编辑面板:勾选角色 + 关联员工档案。
import { useState, useTransition } from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { saveUserRoles, linkAdditionalAccount, unlinkAdditionalAccount } from '../accountsActions'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { Button } from '@/app/components/ui/button'
import { CONTROL_CHECKBOX, CONTROL_SELECT, CONTROL_INPUT } from '@/app/components/ui/control-style'

export type DirectoryRow = {
    user_id: string
    email: string | null
    created_at: string | null
    last_sign_in_at: string | null
    employee_id: string | null
    employee_code: string | null
    employee_name: string | null
    roles: { role_id: string; code: string; name_en: string; name_zh: string }[]
    /** APR-ROUTE-1 Batch B(R3):'primary' | 'additional' | null(没关联任何人) */
    account_kind: 'primary' | 'additional' | null
}
export type RoleOption = {
    id: string
    code: string
    name_en: string
    name_zh: string
    is_system: boolean | null
}
export type EmployeeOption = {
    id: string
    code: string
    legal_name: string
    user_id: string | null
}

export default function UserRow({
    row,
    roles,
    employees,
    lastSignInDisplay,
    createdDisplay,
}: {
    row: DirectoryRow
    roles: RoleOption[]
    employees: EmployeeOption[]
    lastSignInDisplay: string
    createdDisplay: string
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [open, setOpen] = useState(false)
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState(false)

    const [checked, setChecked] = useState<string[]>(row.roles.map((r) => r.role_id))
    const [employeeId, setEmployeeId] = useState<string>(row.employee_id ?? '')
    const [reason, setReason] = useState('')

    // employees.user_id 上是 partial unique index(一名员工最多绑一个账号),
    // 所以选项里【排除已经绑给别人的员工】,并在提示里说明为什么它们不在列表上。
    const options = employees.filter((e) => e.user_id === null || e.id === row.employee_id)

    // ★ APR-ROUTE-1 Batch B(R3):额外账号。
    //   · 这一行【就是】某人的额外账号 → 不给"关联员工档案"那个下拉(它设的是主账号),
    //     给一个"解除"钮;
    //   · 这一行【谁都不属于】 → 除了设主账号,还可以把它链成某人的额外账号。
    //     候选只列【已经有主账号】的人 —— 一个人只有额外账号、没有主账号,
    //     是函数会按名拒绝的形状(ADDITIONAL_NEEDS_PRIMARY)。
    const isAdditional = row.account_kind === 'additional'
    const isUnlinked = row.account_kind === null
    const additionalOptions = employees.filter((e) => e.user_id !== null)
    const [additionalOf, setAdditionalOf] = useState<string>('')

    function linkAdditional() {
        setError(null)
        setDone(false)
        startTransition(async () => {
            const res = await linkAdditionalAccount(row.user_id, additionalOf)
            if (res.error) setError(res.error)
            else {
                setDone(true)
                setOpen(false)
            }
        })
    }

    function unlinkAdditional() {
        setError(null)
        setDone(false)
        startTransition(async () => {
            const res = await unlinkAdditionalAccount(row.user_id)
            if (res.error) setError(res.error)
            else {
                setDone(true)
                setOpen(false)
            }
        })
    }

    function toggle(id: string) {
        setChecked((c) => (c.includes(id) ? c.filter((x) => x !== id) : [...c, id]))
    }

    function save() {
        setError(null)
        setDone(false)
        startTransition(async () => {
            const res = await saveUserRoles(
                row.user_id,
                checked,
                reason,
                employeeId === '' ? null : employeeId,
                isAdditional
            )
            if (res.error) setError(res.error)
            else {
                setDone(true)
                setOpen(false)
            }
        })
    }

    return (
        <div className="border border-gray-200 rounded">
            {/* ★ FONT-1(2026-09-11):这一行加了 `flex-wrap`。
                【为什么】390px 上这一页的整页横向溢出从 35 长到 49 —— 而这一行
                **此前不换行**:左边是邮箱那一格(它有 `min-w-0`,压得下去),
                右边是角色小片 + 「编辑」钮,而右边那一堆**压不下去**。
                换字体之后右边那一堆变宽,整行的 min-content 跟着长,把页面撑破。
                ☞ 这正是 `docs/variant-c-spec.md` §4.1d 那条标准修法的形状:
                  **一个不换行的容器,先给它 `flex-wrap`,不够再谈停手。**
                ★ 实测(390px):整页溢出 **49 → 35**(= round 1 的改前读数);1440px 改前改后都是 0。
                ★ 一个宽度类都没有动,也没有加 `min-w-0` / `max-w-full`。 */}
            <div className="flex flex-wrap items-center justify-between px-4 py-3 gap-4">
                <div className="min-w-0">
                    <div className="font-medium truncate flex items-center gap-2">
                        {row.email ?? '—'}
                        {/* 受邀但从未登录过 → last_sign_in_at 为空。这是"邀请发出去了但人还没进来",
                            与"活跃账号"是两回事,值得一眼看出来。 */}
                        {row.last_sign_in_at === null && (
                            <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs text-amber-800">
                                {t('permissions.pending')}
                            </span>
                        )}
                    </div>
                    <div className="text-sm text-[color:var(--brand-muted-text)]">
                        {row.employee_code && isAdditional ? (
                            // ★ R3:不许读成"这就是他的主账号" —— 说出它是哪一种
                            <>{t('permissions.additionalAccountOf', { code: row.employee_code, name: row.employee_name ?? '' })}</>
                        ) : row.employee_code ? (
                            <>
                                {row.employee_code} — {row.employee_name}
                            </>
                        ) : (
                            <span className="italic text-gray-400">
                                {t('permissions.notLinked')}
                            </span>
                        )}
                    </div>
                </div>

                <div className="flex flex-wrap gap-1 justify-end">
                    {row.roles.length === 0 ? (
                        <span className="text-xs text-gray-400 italic">
                            {t('permissions.noRoles')}
                        </span>
                    ) : (
                        row.roles.map((r) => (
                            <span
                                key={r.role_id}
                                className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-[color:var(--brand-text)]"
                            >
                                {locale === 'zh' ? r.name_zh : r.name_en}
                            </span>
                        ))
                    )}
                </div>

                <div className="text-xs text-[color:var(--brand-muted-text)] whitespace-nowrap text-right tabular-nums">
                    <div>
                        {t('permissions.lastSignIn')}: {lastSignInDisplay}
                    </div>
                    <div>
                        {t('permissions.created')}: {createdDisplay}
                    </div>
                </div>

                {/* ★ C-1(2026-09-04):【「重发邀请」按钮删掉了】
                    它调的是 resendInvite → inviteUserByEmail,而本系统没有邮件服务
                    (Tim 的裁定 Q12:不留一个没配 SMTP 时安静失败的按钮)。
                    一个还没登录过的人现在的处置是【当面重新给一次密码】——
                    在这一行的「编辑」里改,或者删掉账号重建。 */}
                <Button
                    type="button"
                    aria-expanded={open}
                    onClick={() => setOpen((o) => !o)}
                    variant="secondary" className="whitespace-nowrap"
                >
                    {open ? t('common.cancel') : t('permissions.editUser')}
                </Button>
            </div>

            {done && (
                <p className="px-4 pb-2 text-sm text-green-700">{t('permissions.saved')}</p>
            )}

            {open && (
                <div className="border-t border-gray-200 px-4 py-4 bg-gray-50">
                    {error && (
                        <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                            {error}
                        </div>
                    )}

                    <div className="grid gap-6 md:grid-cols-2">
                        <div>
                            <h3 className="mb-2">
                                {t('permissions.rolesLabel')}
                            </h3>
                            <div className="space-y-1">
                                {roles.map((r) => (
                                    <label key={r.id} className="flex items-center gap-2">
                                        <input
                                            type="checkbox"
                                            className={CONTROL_CHECKBOX}
                                            checked={checked.includes(r.id)}
                                            onChange={() => toggle(r.id)}
                                        />
                                        <span>
                                            {locale === 'zh' ? r.name_zh : r.name_en}
                                            <span className="ml-1 text-xs text-gray-400">
                                                {r.code}
                                            </span>
                                        </span>
                                    </label>
                                ))}
                            </div>
                        </div>

                        <div>
                            {isAdditional ? (
                                <>
                                    <h3 className="mb-2">{t('permissions.additionalTitle')}</h3>
                                    <p className="text-sm">
                                        {t('permissions.additionalAccountOf', { code: row.employee_code ?? '', name: row.employee_name ?? '' })}
                                    </p>
                                    <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">
                                        {t('permissions.additionalWhy')}
                                    </p>
                                    <div className="mt-2">
                                        <ConfirmButton
                                            subject={row.email ?? row.user_id}
                                            title={t('permissions.unlinkConfirmTitle')}
                                            body={t('permissions.unlinkConfirmBody', { code: row.employee_code ?? '' })}
                                            confirmLabel={t('permissions.unlinkAdditional')}
                                            tier="reversal"
                                            triggerVariant="secondary"
                                            disabled={pending}
                                            onConfirm={() => unlinkAdditional()}
                                        >
                                            {t('permissions.unlinkAdditional')}
                                        </ConfirmButton>
                                    </div>
                                </>
                            ) : (
                                <>
                                    <h3 className="mb-2">
                                        {t('permissions.linkEmployee')}
                                    </h3>
                                    <select
                                        value={employeeId}
                                        onChange={(e) => setEmployeeId(e.target.value)}
                                        className={`${CONTROL_SELECT} w-full`}
                                    >
                                        <option value="">{t('permissions.noEmployee')}</option>
                                        {options.map((e) => (
                                            <option key={e.id} value={e.id}>
                                                {e.code} — {e.legal_name}
                                            </option>
                                        ))}
                                    </select>
                                    <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">
                                        {t('permissions.linkEmployeeHint')}
                                    </p>
                                </>
                            )}

                            {isUnlinked && (
                                <div className="mt-4">
                                    <h3 className="mb-2">{t('permissions.additionalTitle')}</h3>
                                    <select
                                        value={additionalOf}
                                        onChange={(e) => setAdditionalOf(e.target.value)}
                                        className={`${CONTROL_SELECT} w-full`}
                                        aria-label={t('permissions.additionalTitle')}
                                    >
                                        <option value="">{t('permissions.additionalPick')}</option>
                                        {additionalOptions.map((e) => (
                                            <option key={e.id} value={e.id}>
                                                {e.code} — {e.legal_name}
                                            </option>
                                        ))}
                                    </select>
                                    <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">
                                        {t('permissions.additionalWhy')}
                                    </p>
                                    <div className="mt-2">
                                        <Button
                                            type="button"
                                            variant="secondary"
                                            onClick={linkAdditional}
                                            disabled={pending || additionalOf === ''}
                                        >
                                            {t('permissions.linkAdditional')}
                                        </Button>
                                    </div>
                                </div>
                            )}

                            <label className="mt-4 block">
                                {t('permissions.revokeReason')}
                                <input
                                    value={reason}
                                    onChange={(e) => setReason(e.target.value)}
                                    className={`${CONTROL_INPUT} mt-1 w-full`}
                                    placeholder={t('permissions.revokeReasonHint')}
                                />
                            </label>
                        </div>
                    </div>

                    <div className="mt-4">
                        <Button
                            type="button"
                            onClick={save}
                            disabled={pending}
                        >
                            {pending ? t('common.saving') : t('common.save')}
                        </Button>
                    </div>
                </div>
            )}
        </div>
    )
}

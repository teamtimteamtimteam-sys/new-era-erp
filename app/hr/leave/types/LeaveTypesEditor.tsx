'use client'

// app/hr/leave/types/LeaveTypesEditor.tsx
// 就地编辑假别配置。code 只读 —— 它是稳定标识,改了就等于换了一个假别。
//
// CONV-2:列描述符 + <EditableTable>。手写的那张 9 列表没了,
// 行级编辑状态 / 脏值 / 逐行保存 / 手机上怎么改,全部由组件承担。
// **保存的语义一个字没变**:整行 patch 交给 saveLeaveType,
// 失败留在编辑态、成功才 router.refresh()。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'
import { saveLeaveType } from './actions'

export type LeaveTypeRow = {
    code: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    is_paid: boolean
    is_accrued: boolean
    default_days_per_year: number | null
    requires_certificate_after_days: number | null
    allows_half_day: boolean
    is_active: boolean
    sort_order: number
    notes: string | null
}

/** 草稿就是那一行本身 —— 进编辑时整行拷一份,取消就把它丢掉。 */
type Draft = LeaveTypeRow

const inp = 'w-full border border-gray-300 rounded px-1 py-0.5 text-xs'

export default function LeaveTypesEditor({ rows }: { rows: LeaveTypeRow[] }) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [, startTransition] = useTransition()

    const yesNo = (b: boolean) => (b ? t('permissions.yes') : t('permissions.no'))

    const columns: EditableColumn<LeaveTypeRow, Draft>[] = [
        {
            // ★ 身份列 —— 手机上留在表里,用来认清"我在改哪一行"。不可编辑。
            key: 'code',
            header: t('leave.typeCode'),
            priority: true,
            className: 'font-mono text-gray-500',
            render: (r) => r.code,
        },
        {
            key: 'name',
            header: t('leave.typeName'),
            priority: true,
            render: (r) => (
                <>
                    <div>{locale === 'zh' ? r.name_zh : r.name_en}</div>
                    {r.notes && <div className="mt-0.5 text-[10px] text-gray-500">{r.notes}</div>}
                </>
            ),
            edit: (d, set) => (
                <>
                    <input value={d.name_en} className={inp} aria-label={t('leave.typeName') + ' (EN)'}
                           onChange={(e) => set({ name_en: e.target.value })} />
                    <input value={d.name_zh} className={inp + ' mt-1'} aria-label={t('leave.typeName') + ' (中)'}
                           onChange={(e) => set({ name_zh: e.target.value })} />
                </>
            ),
        },
        {
            key: 'days',
            header: t('leave.standardDaysCol'),
            align: 'right',
            render: (r) => r.default_days_per_year ?? '—',
            edit: (d, set) => (
                <input type="number" step="0.5" className={inp} value={d.default_days_per_year ?? ''}
                       aria-label={t('leave.standardDaysCol')}
                       onChange={(e) => set({ default_days_per_year: e.target.value === '' ? null : Number(e.target.value) })} />
            ),
        },
        {
            key: 'cert',
            header: t('leave.certAfter'),
            align: 'right',
            render: (r) => r.requires_certificate_after_days ?? '—',
            edit: (d, set) => (
                <input type="number" step="0.5" className={inp} value={d.requires_certificate_after_days ?? ''}
                       aria-label={t('leave.certAfter')}
                       onChange={(e) => set({ requires_certificate_after_days: e.target.value === '' ? null : Number(e.target.value) })} />
            ),
        },
        // ★ is_paid / is_accrued 没有 edit —— 它们今天就不可改(saveLeaveType 的
        //   patch 里没有这两个字段)。**不给 edit 就是"这一列不可编辑"的说法。**
        { key: 'paid', header: t('leave.paid'), render: (r) => yesNo(r.is_paid) },
        { key: 'accrued', header: t('leave.accrued'), render: (r) => yesNo(r.is_accrued) },
        {
            key: 'halfDay',
            header: t('leave.halfDay'),
            render: (r) => yesNo(r.allows_half_day),
            edit: (d, set) => (
                <input type="checkbox" checked={d.allows_half_day} aria-label={t('leave.halfDay')}
                       onChange={(e) => set({ allows_half_day: e.target.checked })} />
            ),
        },
        {
            key: 'active',
            header: t('permissions.active'),
            render: (r) => yesNo(r.is_active),
            edit: (d, set) => (
                <input type="checkbox" checked={d.is_active} aria-label={t('permissions.active')}
                       onChange={(e) => set({ is_active: e.target.checked })} />
            ),
        },
    ]

    return (
        <EditableTable<LeaveTypeRow, Draft>
            rows={rows}
            columns={columns}
            rowKey={(r) => r.code}
            phone={{ mode: 'columns' }}
            toDraft={(r) => ({ ...r })}
            labels={{
                edit: t('common.edit'), save: t('common.save'), saving: t('common.saving'),
                cancel: t('common.cancel'), unsaved: t('common.unsavedRow'), expand: t('common.expandRow'),
            }}
            onSave={async (d) => {
                const r = await saveLeaveType(d.code, {
                    name_en: d.name_en, name_zh: d.name_zh,
                    default_days_per_year: d.default_days_per_year,
                    requires_certificate_after_days: d.requires_certificate_after_days,
                    allows_half_day: d.allows_half_day,
                    is_active: d.is_active,
                    sort_order: d.sort_order,
                })
                // ★ Q6:失败就把 error 交回组件 —— 字留住、行留在编辑态、【不刷新】。
                if (r.error) return { error: r.error }
                // 成功才刷新。router.refresh 放在 transition 里,免得阻塞收草稿那一步。
                startTransition(() => router.refresh())
            }}
        />
    )
}

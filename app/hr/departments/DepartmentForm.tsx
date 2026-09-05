'use client'

// 部门表单(新建/编辑共用)。上级下拉里【已经不含】自己与自己的所有下级 ——
// 由服务端算好后传进来,让人根本选不到会成环的项;DB 的 DEPARTMENT_CYCLE 是后墙。
import { useActionState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { saveDepartment, type DepartmentFormState } from './actions'
import { Button } from '@/app/components/ui/button'

const initialState: DepartmentFormState = {}

export type DeptOption = { id: string; label: string }

export default function DepartmentForm({
    department,
    parentOptions,
}: {
    department?: {
        id: string
        code: string
        name_en: string
        name_zh: string
        parent_department_id: string | null
        is_active: boolean
        notes: string | null
    }
    parentOptions: DeptOption[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(saveDepartment, initialState)

    return (
        <form action={formAction} className="space-y-4 max-w-2xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {department && <input type="hidden" name="department_id" value={department.id} />}

            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('hr.colCode')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="code"
                        required
                        defaultValue={department?.code ?? ''}
                        className="w-40 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[14rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('hr.colNameEn')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name_en"
                        required
                        defaultValue={department?.name_en ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[14rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('hr.colNameZh')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name_zh"
                        required
                        defaultValue={department?.name_zh ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            <div className="flex flex-wrap gap-4 items-end">
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('hr.colParent')}</label>
                    <select
                        name="parent_department_id"
                        defaultValue={department?.parent_department_id ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">—</option>
                        {parentOptions.map((o) => (
                            <option key={o.id} value={o.id}>
                                {o.label}
                            </option>
                        ))}
                    </select>
                </div>
                <label className="flex items-center gap-2 text-sm pb-2">
                    <input type="checkbox" name="is_active" defaultChecked={department?.is_active ?? true} />
                    {t('pricing.form.active')}
                </label>
            </div>

            <div>
                <label className="block text-sm font-medium mb-1">{t('hr.colNotes')}</label>
                <textarea
                    name="notes"
                    rows={2}
                    defaultValue={department?.notes ?? ''}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
            </div>

            <div className="flex gap-3 pt-2">
                <Button
                    type="submit"
                    disabled={isPending}
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </Button>
                <Link
                    href="/hr/departments"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}

'use client'

// 员工列表工具栏:姓名/编号搜索 + 部门 + 在职状态 + 办公室/车间。
// 改动只写进 URL searchParams,过滤在服务端完成(端口自 InvoicesToolbar)。
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { EMPLOYMENT_STATUS_OPTIONS, WORK_CATEGORY_OPTIONS } from '../options'

export type DeptOption = { id: string; label: string }

export default function EmployeesToolbar({ departments }: { departments: DeptOption[] }) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    const searchParams = useSearchParams()

    const q = searchParams.get('q') ?? ''
    const dept = searchParams.get('department') ?? ''
    const status = searchParams.get('status') ?? ''
    const category = searchParams.get('category') ?? ''

    function onChange(key: string, value: string) {
        const params = new URLSearchParams(searchParams.toString())
        if (!value) params.delete(key)
        else params.set(key, value)
        params.delete('page')
        const qs = params.toString()
        router.push(qs ? `${pathname}?${qs}` : pathname)
    }

    return (
        <div className="mb-4 flex flex-wrap items-center gap-3">
            {/* 搜索走提交(回车)而不是逐字防抖 —— 这张表不大,少一次往返更稳 */}
            <form
                onSubmit={(e) => {
                    e.preventDefault()
                    const value = new FormData(e.currentTarget).get('q')
                    onChange('q', String(value ?? '').trim())
                }}
            >
                <input
                    type="search"
                    name="q"
                    defaultValue={q}
                    placeholder={t('hr.searchPlaceholder')}
                    className="w-56 max-w-full rounded border border-gray-300 px-3 py-2"
                />
            </form>
            <select
                value={dept}
                onChange={(e) => onChange('department', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('hr.allDepartments')}</option>
                {departments.map((d) => (
                    <option key={d.id} value={d.id}>
                        {d.label}
                    </option>
                ))}
            </select>
            <select
                value={status}
                onChange={(e) => onChange('status', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('hr.allStatuses')}</option>
                {EMPLOYMENT_STATUS_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>
                        {t(o.labelKey)}
                    </option>
                ))}
            </select>
            <select
                value={category}
                onChange={(e) => onChange('category', e.target.value)}
                className="rounded border border-gray-300 bg-white px-3 py-2 text-sm"
            >
                <option value="">{t('hr.allCategories')}</option>
                {WORK_CATEGORY_OPTIONS.map((o) => (
                    <option key={o.value} value={o.value}>
                        {t(o.labelKey)}
                    </option>
                ))}
            </select>
        </div>
    )
}

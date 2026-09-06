'use client'

// LOC-1:库位表单 —— 新建与编辑共用一个组件(字段完全相同,差别只有初值与
// 提交动作)。写成两份的那一天,两份就会开始漂开。
import { useActionState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import AllowedClassesPicker from './AllowedClassesPicker'
import type { WasteClass } from '@/app/materials/wasteClassOptions'
import type { LocationFormState } from './actions'
import { Button } from '@/app/components/ui/button'

const initialState: LocationFormState = {}

export default function LocationForm({
    action,
    classes,
    locale,
    defaults,
    submitLabel,
}: {
    action: (prev: LocationFormState, fd: FormData) => Promise<LocationFormState>
    classes: WasteClass[]
    locale: string
    defaults: {
        code: string
        name: string
        zone: string
        notes: string
        allowedCodes: string[]
    }
    // 【传译好的字符串,不传 key】t(变量) 是一次动态取键,而动态前缀必须在
    // check-i18n 的 MANIFEST 里登记;这里根本不需要动态 —— 服务端已经有 t 了。
    submitLabel: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(action, initialState)

    return (
        <form action={formAction} className="space-y-6 max-w-2xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('locations.form.code')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="code"
                        defaultValue={defaults.code}
                        required
                        className="border border-gray-300 px-3 py-2 rounded font-mono w-48"
                    />
                    {/* "SG-" 是约定不是约束 —— 提示写在这里,数据库【故意】不用
                        CHECK 钉死它(多实体是计划中的,见迁移文件头) */}
                    <p className="text-xs text-gray-500 mt-1">{t('locations.form.codeHint')}</p>
                    {state.fieldErrors?.code && (
                        <p className="text-xs text-red-600 mt-1">{state.fieldErrors.code}</p>
                    )}
                </div>
                <div className="flex-1 min-w-[14rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('locations.form.name')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name"
                        defaultValue={defaults.name}
                        required
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.name && (
                        <p className="text-xs text-red-600 mt-1">{state.fieldErrors.name}</p>
                    )}
                </div>
                <div className="w-48">
                    <label className="block text-sm font-medium mb-1">{t('locations.form.zone')}</label>
                    <input
                        type="text"
                        name="zone"
                        defaultValue={defaults.zone}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {/* zone 只是显示分组 —— 说在输入框旁边,免得有人把合规范围
                        写进这一格然后以为系统会照着办 */}
                    <p className="text-xs text-gray-500 mt-1">{t('locations.form.zoneHint')}</p>
                </div>
            </div>

            <div>
                <label className="block text-sm font-medium mb-1">{t('locations.form.notes')}</label>
                <input
                    type="text"
                    name="notes"
                    defaultValue={defaults.notes}
                    className="w-full border border-gray-300 px-3 py-2 rounded"
                />
            </div>

            <div className="border-t pt-5">
                <AllowedClassesPicker
                    classes={classes}
                    defaultSelected={defaults.allowedCodes}
                    locale={locale}
                />
            </div>

            <div className="flex gap-3 pt-2 border-t">
                <Button
                    type="submit"
                    disabled={isPending}
                    variant="default" size="default"
                >
                    {isPending ? t('common.saving') : submitLabel}
                </Button>
                <Link
                    href="/inventory/locations"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}

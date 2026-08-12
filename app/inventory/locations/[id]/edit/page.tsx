// app/inventory/locations/[id]/edit/page.tsx
// LOC-1:编辑库位(服务端壳)。表单与新建共用一个组件 —— 字段完全相同。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getWasteClassifications } from '@/app/materials/wasteClassQuery'
import LocationForm from '../../LocationForm'
import LocationActiveToggle from '../../LocationActiveToggle'
import { updateLocation } from '../../actions'

export default async function EditLocationPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const { data: loc, error } = await supabase
        .from('storage_locations')
        .select('id, code, name, zone, notes, is_active')
        .eq('id', id)
        .single()

    if (error || !loc) notFound()

    const [allowedRes, classes] = await Promise.all([
        supabase
            .from('storage_location_allowed_classes')
            .select('classification_code')
            .eq('location_id', id),
        getWasteClassifications(),
    ])

    const allowedCodes = mustRows(allowedRes, 'storage_location_allowed_classes').map(
        (r) => r.classification_code
    )

    return (
        <div className="p-4 sm:p-8">
            <div className="mb-6">
                <Link href="/inventory/locations" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">
                {t('locations.editTitle')}
                <span className="ml-3 font-mono text-base text-gray-500">{loc.code}</span>
            </h1>

            {!loc.is_active && (
                <p className="text-sm text-gray-600 bg-gray-100 border border-gray-300 rounded px-3 py-2 mb-6 max-w-2xl">
                    {t('locations.inactiveNotice')}
                </p>
            )}

            <div className="mb-8">
                <LocationForm
                    action={updateLocation.bind(null, id)}
                    classes={classes}
                    locale={locale}
                    defaults={{
                        code: loc.code,
                        name: loc.name,
                        zone: loc.zone ?? '',
                        notes: loc.notes ?? '',
                        allowedCodes,
                    }}
                    submitLabel={t('locations.form.save')}
                />
            </div>

            {/* 停用 / 启用 —— 与列表上同一个控件、同一句后果。
                【这里没有删除】理由写在控件文件头上。 */}
            <section className="border-t pt-6 max-w-2xl">
                <h2 className="text-lg font-semibold mb-3">{t('locations.statusSectionTitle')}</h2>
                <LocationActiveToggle id={loc.id} isActive={loc.is_active} />
            </section>
        </div>
    )
}

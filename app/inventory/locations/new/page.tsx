// app/inventory/locations/new/page.tsx
// LOC-1:新建库位(服务端壳)。分类清单从 waste_classifications 现读。
import Link from 'next/link'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getWasteClassifications } from '@/app/materials/wasteClassQuery'
import LocationForm from '../LocationForm'
import { createLocation } from '../actions'

export default async function NewLocationPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const classes = await getWasteClassifications()

    return (
        <div className="p-4 sm:p-8">
            <div className="mb-6">
                <Link href="/inventory/locations" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('locations.newTitle')}</h1>

            <LocationForm
                action={createLocation}
                classes={classes}
                locale={locale}
                defaults={{ code: '', name: '', zone: '', notes: '', allowedCodes: [] }}
                submitLabel={t('locations.form.create')}
            />
        </div>
    )
}

// app/safety/inspections/templates/new/page.tsx
// MES-7b-2(2026-10-16,MES-7b Step 0 Q13):建一张巡检清单。门 module.safety.view;存要 module.safety.edit(表单在 PermissionGate 里)。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import TemplateForm from '../../TemplateForm'

export default async function NewTemplatePage() {
    const denied = await requireFunction(FN.safetyInspections)
    if (denied) return denied
    const t = await getTranslations()
    const canEdit = await can('module.safety.edit')
    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={<Link href="/safety/inspections" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={t('safety.templates.newTitle')}
            intro={t('safety.templates.newIntro')}
            state={{ kind: 'ok' }}
        >
            <TemplateForm init={{ id: null, code: '', name: '', area: '', frequencyDays: '', isActive: true, notes: '', items: [''] }}
                          canEdit={canEdit} hasRuns={false} />
        </ListPage>
    )
}

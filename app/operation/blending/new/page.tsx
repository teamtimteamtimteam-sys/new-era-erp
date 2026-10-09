// app/operation/blending/new/page.tsx
// MES-5b-3:新建一份配料计划。服务端取四份清单(产出物料、候选批次、合同与品位规格、金属),渲染客户端表单。
//   门:requireFunction(FN.blending) = module.processing.view;存要 action.wo_create(表单在 PermissionGate 里,看得见、按不动、说出码)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { loadBlendingOptions } from '../options'
import BlendingPlanForm from '../BlendingPlanForm'

export default async function NewBlendingPlanPage() {
    const denied = await requireFunction(FN.blending)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const o = await loadBlendingOptions(supabase, locale)
    const canEdit = await can('action.wo_create')
    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={<Link href="/operation/blending" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={t('blending.newTitle')}
            intro={t('blending.newNote')}
            state={{ kind: 'ok' }}
        >
            <BlendingPlanForm mode="create" materials={o.outputMaterials} batches={o.batches} contracts={o.contracts} metals={o.metals}
                              canEdit={canEdit} inboundVisible={o.canIn} outputVisible={o.canOut} />
        </ListPage>
    )
}

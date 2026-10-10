import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import EditMaterialForm from './EditMaterialForm'
import { getNeaCategories } from '@/app/materials/neaCategoryQuery'
import { getDgCodes } from '@/app/materials/dgQuery'
import { getWasteClassifications } from '../../wasteClassQuery'
import { getMaterialKinds } from '../../materialKindQuery'
import { getMaterialAxes } from '../../materialAxesQuery'
import AttachmentsPanel from './AttachmentsPanel'
import RequiredMetalsPanel from './RequiredMetalsPanel'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireDeletedAccess, requireModule } from '@/app/components/moduleGuard'
import { canEnter } from '@/lib/moduleAccess'
import { mustRows } from '@/lib/db-helpers'
import { MOD } from '@/lib/modules'
import { loadSubstances, toOptions } from '@/app/tools/pricing/metal-prices/substanceQuery'
import { loadBatteryChemistries, toDictOptions } from '@/app/components/dictionaries/dictionaryQuery'
import { formatAuditStamp } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { DeletedBanner, EndedFieldset } from '@/app/components/trail/EndedBanner'

export default async function EditMaterialPage({
    params, searchParams,
}: {
    params: Promise<{ id: string }>; searchParams: Promise<{ trail?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.materials)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    // PROC-4:物质清单从 substances 那张字典读(清单与顺序都由它定)。
    const substanceOptions = toOptions(await loadSubstances(supabase), await getLocale())
    const t = await getTranslations()
    const locale = await getLocale()
    // PROC-5:化学体系字典
    const chemistryOptions = toDictOptions(await loadBatteryChemistries(supabase), locale)
    // MAT-1:分类选项从表里现读
    const wasteClasses = await getWasteClassifications()
    const neaCategories = await getNeaCategories()
    // MES-3b(Q11 · Q12):危险品 UN 编号字典
    const dgCodes = await getDgCodes()
    const kinds = await getMaterialKinds()
    const axes = await getMaterialAxes()

    // AUDIT-TRAIL-1b-3(Q9 · Q21):删掉的物料不再 404 —— 持 data.view_deleted 的人只读打开(横幅 + 审计记录),
    //   别人得到一句具名拒绝。所以这里不再过滤 deleted_at,而是读出来再判。
    const { data: material, error } = await supabase
        .from('materials')
        .select('*')
        .eq('id', id)
        .single()

    if (error || !material) {
        notFound()
    }
    const deleted = !!material.deleted_at
    if (deleted) {
        const refused = await requireDeletedAccess('materials.editTitle')
        if (refused) return refused
    }

    const { data: attachmentRows } = await supabase
        .from('material_attachments')
        .select('id, file_name, file_type, file_size, doc_category, storage_path, created_at')
        .eq('material_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    // ── ASY-P2:这种物料要化验哪些金属 ──────────────────────────────────────
    // 【失败必须失败】不 `?? []`:读不出来会渲染成"无化验要求",而那正是这一族
    // 最不能撒的谎 —— 它读起来像一个决定,实际是一次没读到。
    const requiredRes = await supabase
        .from('material_required_metals')
        .select('metal')
        .eq('material_id', id)
        .order('metal')
    const requiredMetals = mustRows(requiredRes, 'material_required_metals').map((r) => r.metal)
    // 改这件事要 module.materials.edit(与 ASY-P1 的函数同一个码)——
    // 没有就渲染成只读,而不是摆一个必然被拒的保存钮。
    const canEditMaterials = await canEnter('module.materials.edit')

    // 在服务端按当前语言格式化时间,再传给客户端面板 —— 避免客户端 toLocaleString 引发水合不一致
    const attachments = (attachmentRows ?? []).map((a) => ({
        id: a.id,
        file_name: a.file_name,
        file_type: a.file_type,
        file_size: a.file_size,
        doc_category: a.doc_category,
        storage_path: a.storage_path,
        created_at_display: formatAuditStamp(a.created_at),
    }))

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link
                    href="/materials"
                    className="hover:underline text-sm app-link"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="mb-2">{t('materials.editTitle')}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-6">
                <span>{material.code}</span>
                <span className="mx-2">·</span>
                <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">
                    {material.status}
                </span>
            </p>

            {material.deleted_at && <DeletedBanner kind="material" id={material.id} at={material.deleted_at} />}

            {/* 删掉的物料:下面每一个控件都按不下去,理由是上面那条横幅(EndedFieldset);链接照常可用 */}
            <EndedFieldset ended={deleted}>
                <EditMaterialForm
                    chemistryOptions={chemistryOptions} material={material} wasteClasses={wasteClasses} neaCategories={neaCategories} dgCodes={dgCodes} kinds={kinds}
                    forms={axes.forms} sources={axes.sources} sizeFormats={axes.sizeFormats} locale={locale} />
                <RequiredMetalsPanel
                    substanceOptions={substanceOptions}
                    materialId={material.id}
                    initial={requiredMetals}
                    canEdit={canEditMaterials && !deleted}
                />
                <AttachmentsPanel materialId={material.id} rows={attachments} />
            </EndedFieldset>

            {/* AUDIT-TRAIL-1b-3(Q2):物料只有这一页,审计记录在它的底部 */}
            <AuditTrail subject="material" id={material.id} show={trailCount((await searchParams).trail)} />
        </div>
    )
}

// app/output/[id]/assays/new/page.tsx
// 录入产出化验(服务端壳)。进料侧 assays/new 是形状的出处;区别只有一个,
// 而它是本质的:这里没有价格 —— 产出批没有一张应付可以按含量重述,所以没有
// 算价预览。"应用会怎样"的另一半(过期后果)由 preview_apply_output_assay
// 回答 —— 页面问库,不自己重算那条谓词。
//
// 取:批次(物料/数量/状态)、当前已录含量(作为录入起点 —— 一次更正是小改
// 而不是重敲)、以及批次侧的应用后果(产出它的加工单、会不会过期)。
import { loadBatchSampleOptions } from '@/app/components/quality/sampleOptions'
import { loadIndicatorDefs, indicatorName } from '@/app/components/quality/AssayIndicators'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import OutputAssayForm from './OutputAssayForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { loadSubstances, toOptions } from '@/app/tools/pricing/metal-prices/substanceQuery'
import { getLocale } from '@/lib/i18n/server'
import { loadLaboratories, toDictOptions } from '@/app/components/dictionaries/dictionaryQuery'
import { can } from '@/lib/permissions'

export default async function NewOutputAssayPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    /** MES-6a-1:样品页上的"记一份化验"带着 ?sample= —— 选单预选那一份 */
    searchParams: Promise<{ sample?: string | string[] }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.output)
    if (denied) return denied

    const { id } = await params
    const sp = await searchParams
    const supabase = await createClient()
    // PROC-4:物质清单从 substances 那张字典读(清单与顺序都由它定)。
    const substanceOptions = toOptions(await loadSubstances(supabase), await getLocale())
    // PROC-5:实验室字典
    const locale = await getLocale()
    const labOptions = toDictOptions(await loadLaboratories(supabase), locale)
    const t = await getTranslations()

    const { data: batch, error } = await supabase
        .from('output_batches')
        .select('id, code, quantity, unit, status, material_id')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !batch) {
        notFound()
    }

    const [materialRes, metalsRes] = await Promise.all([
        supabase.from('material_lookup').select('name').eq('id', batch.material_id).single(),   // FIX-1 item 3:查名视图
        supabase
            .from('output_batch_metals')
            .select('metal, content_pct')
            .eq('output_batch_id', id),
    ])

    // 应用的后果【问库】:产出它的加工单是谁、"记录并应用"会不会让分摊过期。
    // 谓词与过期视图第六源同一条(preview_apply_output_assay 的注释里有账)。
    // ROLE-1 Batch 2b(Q15):试算归 action.apply_assay(cto)。没有它的人不去问 —— 问了是
    //   PERMISSION_DENIED,而表单会把那读成"后果未知";它真实的意思是"这不归你看"。
    const canApply = await can('action.apply_assay')
    const { data: impactRaw, error: impactErr } = canApply
        ? await supabase.rpc('preview_apply_output_assay', { p_output_batch_id: id })
        : { data: null, error: null }
    // 试算失败不挡记录:化验单是实验室出的客观事实,先落库;后果说明缺席时
    // 表单顶部会说明"后果未知",applying 仍走服务端的同一套闸。
    const impact = impactErr
        ? null
        : (impactRaw as unknown as {
              producing_run_code: string | null
              producing_run_allocated_at: string | null
              producing_run_basis: string | null
              will_flag_stale: boolean
          })

    // 起点含量:批次当前已录的数
    const currentMetals: Record<string, string> = {}
    for (const m of mustRows(metalsRes)) {
        currentMetals[m.metal] = String(m.content_pct)
    }

    return (
        <div className="p-4 sm:p-8 max-w-5xl">
            <div className="mb-6">
                <Link href={`/output/${id}/edit`} className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="mb-2">{t('assay.newTitle')}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-6">
                <span>{batch.code}</span>
                <span className="mx-2">·</span>
                {materialRes.data?.name ?? '—'}
                <span className="mx-2">·</span>
                <span>
                    {batch.quantity} {batch.unit}
                </span>
            </p>

            <OutputAssayForm
                labOptions={labOptions}
                substanceOptions={substanceOptions}
                batchId={batch.id}
                currentMetals={currentMetals}
                impact={impact}
                canApply={canApply}
                sampleOptions={await loadBatchSampleOptions(supabase, 'output', batch.id)}
                defaultSampleId={(() => { const v = sp.sample; return Array.isArray(v) ? v[0] : v ?? null })()}
                // MES-6a-2(Q3 · Q4):还能新选的指标,名字按读者语言、单位是字典自己的
                indicatorOptions={(await loadIndicatorDefs(supabase, true)).map((d) => ({ code: d.code, label: indicatorName(d, locale), unit: d.unit }))}
            />
        </div>
    )
}

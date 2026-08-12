// app/output/[id]/assays/new/page.tsx
// 录入产出化验(服务端壳)。进料侧 assays/new 是形状的出处;区别只有一个,
// 而它是本质的:这里没有价格 —— 产出批没有一张应付可以按含量重述,所以没有
// 算价预览。"应用会怎样"的另一半(过期后果)由 preview_apply_output_assay
// 回答 —— 页面问库,不自己重算那条谓词。
//
// 取:批次(物料/数量/状态)、当前已录含量(作为录入起点 —— 一次更正是小改
// 而不是重敲)、以及批次侧的应用后果(产出它的加工单、会不会过期)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import OutputAssayForm from './OutputAssayForm'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function NewOutputAssayPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.output)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
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
        supabase.from('materials').select('name').eq('id', batch.material_id).single(),
        supabase
            .from('output_batch_metals')
            .select('metal, content_pct')
            .eq('output_batch_id', id),
    ])

    // 应用的后果【问库】:产出它的加工单是谁、"记录并应用"会不会让分摊过期。
    // 谓词与过期视图第六源同一条(preview_apply_output_assay 的注释里有账)。
    const { data: impactRaw, error: impactErr } = await supabase.rpc('preview_apply_output_assay', {
        p_output_batch_id: id,
    })
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
                <Link href={`/output/${id}/edit`} className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('assay.newTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">
                <span className="font-mono">{batch.code}</span>
                <span className="mx-2">·</span>
                {materialRes.data?.name ?? '—'}
                <span className="mx-2">·</span>
                <span className="font-mono">
                    {batch.quantity} {batch.unit}
                </span>
            </p>

            <OutputAssayForm
                batchId={batch.id}
                currentMetals={currentMetals}
                impact={impact}
            />
        </div>
    )
}

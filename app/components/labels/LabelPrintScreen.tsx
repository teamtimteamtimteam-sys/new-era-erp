// app/components/labels/LabelPrintScreen.tsx
// MES-3b(2026-10-07,MES-3b Step 0 Q4–Q9,Tim):三张打印页(进料批 · 产出批 · 库位)共用的服务端壳。
//   此前 /inbound/[id]/label 与 /output/[id]/label 是两支 GET 路由处理器:一打开就自动打印、什么都不记,
//   而且以读者身份内嵌读物料名 —— 仓库印出来的物料那一格是"—"(MES-3b Step 0 §1.3)。
//   现在:页面只读(label_print_preview —— 一次 GET 不写),按下"打印"才经 record_label_print 记下、再打印(LabelPrinter)。
//   拒绝(看不见、找不到、没有模板)说成句子,画在一页拒绝里,不是 404。
//   旧的标签链接(五处)指的仍是同一条路径,所以不必改;它们照旧在新标签页里打开。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { RefusalPage } from '@/app/components/ui/refusal'
import LabelPrinter from './LabelPrinter'
import { localizeLabelError } from './labelErrorCodes'
import type { LabelContext, LabelKind, LabelTemplateInfo } from './actions'

const BACK: Record<LabelKind, (id: string) => string> = {
    inbound_batch: (id) => `/inbound/${id}/edit`,
    output_batch: (id) => `/output/${id}/edit`,
    storage_location: (id) => `/inventory/locations/${id}/edit`,
}

export default async function LabelPrintScreen({ kind, id, template }: { kind: LabelKind; id: string; template?: string }) {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const [ctxRes, tplRes] = await Promise.all([
        // ?template=<代码> 打开时先选那一张(版式探针用它分别量 A6 与 A5);不给就是默认那张。不认识的模板由函数按名拒
        supabase.rpc('label_print_preview', template ? { p_kind: kind, p_id: id, p_template: template } : { p_kind: kind, p_id: id }),
        supabase.from('label_templates').select('code, name_en, name_zh, page_size, show_dg')
            .eq('object_kind', kind).eq('is_active', true).order('sort_order').order('code'),
    ])
    if (ctxRes.error) {
        return <RefusalPage title={t('labels.print.title')} statement={await localizeLabelError(ctxRes.error.message)}
                            backHomeLabel={t('common.backHome')} />
    }
    const ctx = ctxRes.data as unknown as LabelContext
    const templates = mustRows(tplRes, 'label_templates') as LabelTemplateInfo[]

    return (
        <div className="p-4 sm:p-8">
            <div className="mb-6">
                <Link href={BACK[kind](id)} className="hover:underline text-sm app-link">{t('common.back')}</Link>
            </div>
            <h1 className="mb-1">{t('labels.print.title')} · <span className="font-mono">{ctx.data.code}</span></h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-6">{t('labels.print.intro')}</p>
            <LabelPrinter kind={kind} id={id} initial={ctx} templates={templates} locale={locale} />
        </div>
    )
}

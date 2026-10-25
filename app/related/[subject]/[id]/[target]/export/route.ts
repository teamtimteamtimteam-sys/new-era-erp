// TABLE-EXPORT-3c(Tim 2026-10-25):关联页的统一导出 —— 服务端那一半。
// 页面是 keyset 分页的,手里只有一屏;这里跑页面【自己】的三层权限与同一支 search_related_rows,取全体交给表
// (app/components/related/relatedRows.ts)。超过 50,000 行按名拒绝(TABLE-EXPORT-1 Q8)。
import { relatedExportResponse } from '@/app/components/related/relatedRows'

export async function GET(
    _request: Request,
    { params }: { params: Promise<{ subject: string; id: string; target: string }> },
) {
    const { subject, id, target } = await params
    return relatedExportResponse({ subjectKey: subject, subjectId: id, targetKey: target })
}

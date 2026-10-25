// TABLE-EXPORT-3c(Tim 2026-10-25):无主语那一页(/documents/<种类>)的统一导出 —— 服务端那一半。
// 与关联页同一支取数(app/components/related/relatedRows.ts),只是不带主语。
import { relatedExportResponse } from '@/app/components/related/relatedRows'

export async function GET(
    _request: Request,
    { params }: { params: Promise<{ key: string }> },
) {
    const { key } = await params
    return relatedExportResponse({ targetKey: key })
}

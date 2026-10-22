// app/finance/freight/page.tsx
// 运费单据列表(FRT-1)。运费【资本化进批次成本】—— 借方进 1200/5000,
// 贷方记在【货代】名下,与材料供应商的应付是两笔账。
//
// CONV-4:套 CONV-1 的两文件模板。没有筛选工具栏,空态判据不必分层。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { FREIGHT_SHOWN, freightCount, freightPage, shapeFreightRows } from './freightRows'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import FreightTable, { type FreightRow } from './FreightTable'

export default async function FreightListPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    // ★ TABLE-EXPORT-2a(Tim Q2):读取与映射搬进 freightRows.ts,与导出路由共用;只画最近 FREIGHT_SHOWN 张,而且说出来。
    const [dbRows, total] = await Promise.all([
        freightPage(supabase, 0, FREIGHT_SHOWN - 1).then((r) => mustRows(r, 'freight_documents')),
        freightCount(supabase).then((r) => mustCount(r, 'freight_documents count')),
    ])
    const tableRows: FreightRow[] = await shapeFreightRows(dbRows)

    return (
        <ListPage
            title={t('finance.freight.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/finance/freight/new">{t('finance.freight.addButton')}</Link>
                </Button>
            }
            // 资本化的代价,写在人看得见的地方:错的分摊藏在存货里,不显示在损益表上
            intro={t('finance.freight.intro')}
            state={tableRows.length === 0
                ? { kind: 'empty', noRows: t('finance.freight.empty') }
                : { kind: 'ok' }}
        >
            <RowCapNotice shown={tableRows.length} total={total} />
            <FreightTable rows={tableRows} empty={t('finance.freight.empty')} />
        </ListPage>
    )
}

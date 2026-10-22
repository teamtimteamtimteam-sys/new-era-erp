// app/finance/credit-notes/page.tsx
// FIX-1:贷项凭证【列表】。此前只有详情页存在,进去的唯一路是先打开那张发票 ——
// 也就是说「本月开过哪些贷项凭证」这个问题,得先知道答案才能问出口。
//
// 【为什么"状态"这一列写的是签发,不是单据状态】credit_notes 没有 status 列,
// 也没有作废:凭证只增不改(CREDIT_NOTE_IMMUTABLE,见详情页抬头)。它唯一
// 真实存在的状态是【有没有签发过给客户的那份 PDF】,以及签到第几版。
// 编一个「已过账 / 草稿」出来会比留白更坏(FIN-26 那条:伪造的出处不如空着)。
//
// CONV-4:套 CONV-1 的两文件模板。没有筛选工具栏,只有服务端分页,所以
// 空态判据不必分"全空"与"筛没了"——分页链接不受行数影响,不会被吞。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { creditNoteCount, creditNotePage, shapeCreditNoteRows } from './creditNoteRows'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import CreditNotesTable, { type CreditNoteRow } from './CreditNotesTable'
import { Button } from '@/app/components/ui/button'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function CreditNotesPage({
    searchParams,
}: {
    searchParams: Promise<{ page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const t = await getTranslations()
    const supabase = await createClient()

    // TABLE-EXPORT-2a:读取与「库里的行 → 表的行」(含客户那一格的权限判断)搬进 creditNoteRows.ts,与导出路由共用一份。
    // 总数数不出来就失败(mustCount)—— 从前是 `count ?? 0`,一次失败会读成「没有贷项凭证」。
    const total = mustCount(await creditNoteCount(supabase), 'credit_notes count')
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(parsePage(sp.page), totalPages)

    const notes = mustRows(
        await creditNotePage(supabase, (page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1),
        'credit_notes'
    )
    const tableRows: CreditNoteRow[] = await shapeCreditNoteRows(supabase, notes)

    function pageHref(targetPage: number) {
        return `/finance/credit-notes?page=${targetPage}`
    }

    return (
        <ListPage
            title={t('cn.title')}
            // 【没有"新建"按钮是对的】贷项凭证只能从它要冲的那张发票上开,
            // 因为每一行的可冲上限是按发票行算出来的。所以这里说出那条路,
            // 而不是摆一个注定要先问"冲哪张发票"的钮。
            intro={t('cn.listNote')}
            state={total === 0
                ? { kind: 'empty', noRows: t('cn.empty') }
                : { kind: 'ok' }}
        >
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">{t('finance.recordCount', { count: total })}</p>

            <CreditNotesTable rows={tableRows} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('finance.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('finance.pagination.prev')}
                    </Button>
                )}
                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>
                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('finance.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('finance.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}

// app/finance/bank/statements/page.tsx
// 对账单列表:最新在前(period_end DESC),账户 + 状态筛选,count+range 分页
// (端口自收付款列表)。已软删的不列。每张报表的行状态计数按页级一次 .in 聚合。
//
// CONV-4:套 CONV-1 的两文件模板。state 恒为 'ok' —— 筛选工具栏是真实出口,
// 理由与 /finance/expenses 同一条。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import StatementsToolbar from './StatementsToolbar'
import StatementsTable, { type StatementRow } from './StatementsTable'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { parseStatementListParams, statementCount, statementPage, shapeStatementRows, statementExportHref } from './statementRows'
import { can } from '@/lib/permissions'
import { trailCount } from '@/app/components/trail/AuditTrail'
import ListTrail from '@/app/components/trail/ListTrail'
import { setSortParams } from '@/lib/listSort'
import { SavedViewsBar } from '@/app/components/ui/saved-views'
import { loadSavedViews } from '@/lib/savedViewsServer'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function BankStatementsPage({
    searchParams,
}: {
    searchParams: Promise<{ account?: string; status?: string; page?: string; trail?: string; sort?: string; dir?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    // TABLE-FEATURES-3(Tim 2026-10-26 Q1–Q3):保存的视图 —— 地址为空时套用本人的默认视图(一次跳转,所以在任何别的查询之前)
    const savedViews = await loadSavedViews(supabase, { listKey: '/finance/bank/statements', sp })
    const t = await getTranslations()

    // TABLE-EXPORT-2a:读取、筛选与「库里的行 → 表的行」(含逐张的行状态计数)搬进 statementRows.ts,与导出路由共用一份。
    const params = parseStatementListParams(sp)
    const listParams = params
    const { account, status } = params
    const requestedPage = parsePage(sp.page)

    const total = mustCount(await statementCount(supabase, params), 'bank_statements count')
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PAGE_SIZE
    const to = from + PAGE_SIZE - 1

    const { data: statements, error } = await statementPage(supabase, params, from, to)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="mb-4">{t('bank.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(error, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (account) params.set('account', account)
        if (status) params.set('status', status)
        setSortParams(params, listParams.sort)  // TABLE-FEATURES-1 Q9:翻页保留排序
        params.set('page', String(targetPage))
        return `/finance/bank/statements?${params.toString()}`
    }

    const tableRows: StatementRow[] = await shapeStatementRows(supabase, statements ?? [])

    // AUDIT-TRAIL-1c-3:删掉的对账单 —— 只给持 data.view_deleted 的人读(与它那一页的门同一个码)
    const canDeleted = await can('data.view_deleted')
    const deletedStatements = canDeleted
        ? mustRows(await supabase.from('bank_statements').select('id, code').not('deleted_at', 'is', null)
            .order('deleted_at', { ascending: false }).limit(50), 'bank_statements deleted') as { id: string; code: string }[]
        : []

    return (
        <ListPage
            title={t('bank.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/finance/bank/import">{t('bank.import')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <SavedViewsBar listKey="/finance/bank/statements" views={savedViews} />
                <StatementsToolbar />
            </Suspense>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">{t('finance.recordCount', { count: total })}</p>

            <StatementsTable rows={tableRows} empty={t('bank.empty')} exportHref={statementExportHref(params)}
                             sort={params.sort} shown={tableRows.length} total={total} />

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
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

            {/* AUDIT-TRAIL-1c-3:删掉的对账单(清单只列在用的)—— 一块合起来的审计记录,每一张链到它只读的页(1c-2 的 Q6)。
                与那一页同一道门:持 data.view_deleted 的人看得见;别人看到一句具名的拒绝,不是一块空白。 */}
            <ListTrail anchor="deleted-statements-trail" intro="listTrail.intro.deletedStatements" show={trailCount(sp.trail)}
                refused={!canDeleted}
                records={deletedStatements.map((b) => ({ subject: 'bank_statement' as const, id: b.id, href: `/finance/bank/statements/${b.id}`,
                    label: `${b.code} (deleted)` }))} />
        </ListPage>
    )
}

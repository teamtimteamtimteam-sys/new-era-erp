// app/hr/claims/page.tsx
// 医疗报销列表。settlement_state 来自 medical_claim_status —— 它从【已过账的付款】
// 推导"钱到底付了没有",而不是相信报销单自己的状态列。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— 这一页的筛选表单是真实出口,筛空了不能连表单一起藏。
//   见 docs/list-page-template.md §⑩-3(这一刀 15 张页面共用同一条判据)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ClaimsTable from './ClaimsTable'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { CLAIMS_SHOWN, claimsCount, claimsFilterFrom, claimsPage, claimsQuery, shapeClaimRows, claimsTotals } from './claimsRows'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { Suspense } from 'react'
import { SavedViewsBar } from '@/app/components/ui/saved-views'
import { loadSavedViews } from '@/lib/savedViewsServer'

export default async function ClaimsPage({
    searchParams,
}: { searchParams: Promise<{ status?: string; employee?: string; year?: string; sort?: string; dir?: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    // TABLE-FEATURES-3(Tim 2026-10-26 Q1–Q3):保存的视图 —— 地址为空时套用本人的默认视图(一次跳转,所以在任何别的查询之前)
    const savedViews = await loadSavedViews(supabase, { listKey: '/hr/claims', sp })
    const t = await getTranslations()

    // ★ TABLE-EXPORT-2b-2(Tim Q2):读取、三条筛选与映射搬进 claimsRows.ts,与导出路由共用。状态筛选从前在截断之后跑,
    //   现在与员工、年份一起在查询里;只画最新 CLAIMS_SHOWN 条,而且说出来。
    const f = claimsFilterFrom(sp)
    const [rowsRes, totalRes, empRes, totals] = await Promise.all([
        claimsPage(supabase, f, 0, CLAIMS_SHOWN - 1),
        claimsCount(supabase, f),
        supabase.from('employees').select('id, code, legal_name').is('deleted_at', null).order('code'),
        // TABLE-FEATURES-2(Tim Q1):表尾合计 —— 同一套筛选,所有符合的行
        claimsTotals(supabase, f),
    ])
    const tableRows = await shapeClaimRows(mustRows(rowsRes, 'medical_claim_status'))
    const total = mustCount(totalRes, 'medical_claim_status count')

    const sel = CONTROL_SELECT
    const inp = CONTROL_INPUT

    return (
        <ListPage
            title={t('hr.title')}
            maxWidth="max-w-6xl"
            actions={
                <Button asChild>
                    <Link href="/hr/claims/new">{t('claims.record')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <Suspense fallback={null}><SavedViewsBar listKey="/hr/claims" views={savedViews} /></Suspense>
            <form method="get" className="flex gap-2 flex-wrap items-end mb-4">
                <label className="">{t('claims.state')}
                    <select name="status" defaultValue={sp.status ?? ''} className={`block ${sel}`}>
                        <option value="">{t('leave.allStatuses')}</option>
                        {['submitted','approved','rejected','expense_raised','part_paid','paid','withdrawn'].map((s) => (
                            <option key={s} value={s}>{t(`claims.state_${s}`)}</option>
                        ))}
                    </select>
                </label>
                <label className="">{t('leave.employee')}
                    <select name="employee" defaultValue={sp.employee ?? ''} className={`block ${sel}`}>
                        <option value="">{t('leave.allEmployees')}</option>
                        {(mustRows(empRes)).map((e) => (
                            <option key={e.id} value={e.id}>{e.code} — {e.legal_name}</option>
                        ))}
                    </select>
                </label>
                <label className="">{t('claims.year')}
                    <input type="number" name="year" defaultValue={sp.year ?? ''} className={`block ${inp} w-24`} /></label>
                <Button variant="secondary" type="submit">{t('leave.filter')}</Button>
            </form>

            <RowCapNotice shown={tableRows.length} total={total} />
            <ClaimsTable rows={tableRows} empty={t('claims.none')} exportUrl={`/hr/claims/export${claimsQuery(f)}`}
                         sort={f.sort} shown={tableRows.length} total={total} totals={totals} />
        </ListPage>
    )
}

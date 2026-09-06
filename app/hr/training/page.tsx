// app/hr/training/page.tsx
// 全员培训记录列表,按类别与到期状态筛选。到期日临近的行挂标记 ——
// 安全/合规证书过期意味着这个人暂时不能上那道工序。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— 这一页有一个真实的筛选工具栏,而按【筛选后的行数】走
//   ListPage 的 empty 分支会把工具栏一起藏起来(筛空了就再也筛不回来)。
//   同一条判据这一刀在 15 张页面上适用,整套推理写在
//   docs/list-page-template.md §⑩-3,不在每一页重复。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import TrainingToolbar from './TrainingToolbar'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import TrainingTable, { type TrainingRow } from './TrainingTable'

type Row = {
    id: string
    training_name: string
    category: string | null
    completed_date: string
    expiry_date: string | null
    provider: string | null
    certificate_ref: string | null
    employees: { id: string; code: string; legal_name: string } | null
}

export default async function TrainingPage({
    searchParams,
}: {
    searchParams: Promise<{ category?: string; expiry?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const category = (sp.category ?? '').trim()
    const expiry = (sp.expiry ?? '').trim()

    const now = new Date()
    const today = now.toISOString().slice(0, 10)
    const in90Date = new Date(now)
    in90Date.setDate(in90Date.getDate() + 90) // "即将到期" = 90 天内,与 hr_alerts 同档
    const in90 = in90Date.toISOString().slice(0, 10)

    interface Chain {
        eq(c: string, v: string): Chain
        lt(c: string, v: string): Chain
        gte(c: string, v: string): Chain
        lte(c: string, v: string): Chain
        is(c: string, v: null): Chain
        not(c: string, op: string, v: null): Chain
    }
    let query = supabase
        .from('training_records')
        .select('id, training_name, category, completed_date, expiry_date, provider, certificate_ref, employees(id, code, legal_name)')
        .is('deleted_at', null) as unknown as Chain
    if (category) query = query.eq('category', category)
    if (expiry === 'expired') query = query.not('expiry_date', 'is', null).lt('expiry_date', today)
    else if (expiry === 'soon') query = query.gte('expiry_date', today).lte('expiry_date', in90)
    else if (expiry === 'none') query = query.is('expiry_date', null)

    const { data } = await (query as unknown as {
        order(c: string, o: { ascending: boolean }): Promise<{ data: Row[] | null }>
    }).order('completed_date', { ascending: false })

    const rows = (data as unknown as Row[] | null) ?? []

    // 服务端把"到期状态"算成一个纯数据字段:today / in90 只有服务端知道得准,
    // 而列描述符不该重新实现这条判据(CONV-1 §① 通则)。
    const tableRows: TrainingRow[] = rows.map((r) => {
        const expired = r.expiry_date !== null && r.expiry_date < today
        const soon = r.expiry_date !== null && !expired && r.expiry_date <= in90
        return {
            id: r.id,
            employeeId: r.employees?.id ?? null,
            employeeCode: r.employees?.code ?? null,
            employeeName: r.employees?.legal_name ?? null,
            trainingName: r.training_name,
            categoryLabel: r.category ? t('hr.trainingCategory.' + r.category) : '—',
            completedDate: r.completed_date,
            expiryDate: r.expiry_date,
            expiryState: expired ? 'expired' : soon ? 'soon' : 'none',
            provider: r.provider ?? '—',
            certificateRef: r.certificate_ref ?? '—',
        }
    })

    return (
        <ListPage
            title={t('hr.trainingTitle')}
            actions={
                <Button asChild>
                    <Link href="/hr/training/new">{t('hr.newTraining')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <TrainingToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: rows.length })}</p>

            <TrainingTable rows={tableRows} empty={t('hr.trainingEmpty')} />
        </ListPage>
    )
}

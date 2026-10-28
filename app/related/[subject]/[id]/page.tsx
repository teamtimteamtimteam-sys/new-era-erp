// app/related/[subject]/[id]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-3(Tim 2026-10-27 Q2):一张单据的【全部关联记录】—— 与搜索下拉里那几行分组同一份(lib/search/records.ts 的
//   relatedFor:search_related(),INVOKER),每一组链到它自己那一页(/related/<种类>/<id>/<目标>)。
//   入口:每一张链上单据的详情页(单据链条组件 DocumentChains 底下那一行「全部关联记录」)。不进菜单(check-nav-routes 的 EXCEPTIONS)。
// 权限:与 /related/<种类>/<id>/<目标> 的第 ② 层同一条 —— 主语读不到 ⇒ 整页拒绝(标题里印着它的名字)。
//   每一组的计数由 RLS 回答(读者看不见的那一类数出 0,那一组不出现 —— 与搜索下拉同一条)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { ListPage } from '@/app/components/ui/list-page'
import { docType, subjectRow } from '@/app/components/related/relatedRows'

type DbError = { message: string; code?: string } | null

export default async function RelatedIndexPage({ params }: { params: Promise<{ subject: string; id: string }> }) {
    const { subject, id } = await params
    const t = await getTranslations()
    const supabase = await createClient()

    const type = await docType(supabase, subject)
    if (!type) {
        throw new Error(`SEARCH_UNKNOWN_DOCUMENT_TYPE|${subject} —— 它不在 document_types 里`)
    }
    const row = await subjectRow(supabase, type, id)
    if (!row) {
        return (
            <ListPage
                title={t('chain.allRelated')}
                state={{
                    kind: 'restricted',
                    title: t('chain.allRelated'),
                    statement: t('related.subjectUnreadable'),
                    hint: t('related.subjectUnreadableHint'),
                    backHomeLabel: t('common.backHome'),
                }}
            />
        )
    }
    const name = row.label && row.label !== '' ? row.label : row.code
    const groups = mustRows(
        await supabase.rpc('search_related', { p_key: subject, p_id: id }) as {
            data: { target_key: string; n: number }[] | null; error: DbError },
        'search_related')
    const back = mustOne(
        await supabase.rpc('document_detail_href', { p_key: subject, p_id: id }) as { data: string | null; error: DbError },
        'document_detail_href')

    return (
        <ListPage
            title={t('related.indexTitle', { subject: name })}
            breadcrumb={back
                ? <Link href={back} className="app-link hover:underline" data-related-back="1">{t('related.backToSubject', { subject: name })}</Link>
                : undefined}
            maxWidth="max-w-3xl"
            state={groups.length === 0 ? { kind: 'empty', noRows: t('related.indexNone') } : { kind: 'ok' }}
        >
            <ul className="flex flex-col divide-y divide-[color:var(--brand-border)] rounded-md border border-[color:var(--brand-border)]" data-related-groups="">
                {groups.map((g) => (
                    <li key={g.target_key} className="flex items-baseline justify-between gap-4 px-3 py-2">
                        <Link href={`/related/${subject}/${id}/${g.target_key}`} className="app-link hover:underline" data-related-group={g.target_key}>
                            {t(`search.docType.${g.target_key}`)}
                        </Link>
                        <span className="tabular-nums text-[color:var(--brand-muted-text)]" aria-label={t('related.colCount')}>{Number(g.n)}</span>
                    </li>
                ))}
            </ul>
        </ListPage>
    )
}

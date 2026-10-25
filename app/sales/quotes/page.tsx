// SO-4b:报价列表。
//
// 【读 quote_status,不读 quotes】过期是【算出来的】——
// quote_is_expired(valid_until),而那个函数正是 convert_quote 的拒绝读的同一个。
// 在这里自己写一句 valid_until < today,就是给同一个判断留下第二份实现:
// 屏幕上说"还有效"而服务端拒绝转换,或者反过来。CMP-1 的证书过期就是被写了
// 两遍的那一对(它自己的注释写着"改一边要改两边"),这里不重演。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import QuotesTable from './QuotesTable'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { QUOTES_SHOWN, quotesCount, quotesPage, parseQuoteSort, quotesExportHref } from './quotesRows'

export default async function QuotesPage({ searchParams }: { searchParams: Promise<{ sort?: string; dir?: string }> }) {
    const denied = await requireModule(MOD.sales)
    if (denied) return denied
    // TABLE-FEATURES-1 Q9:在数据库里排(排在截取前 QUOTES_SHOWN 张之前)
    const sort = parseQuoteSort(await searchParams)
    const t = await getTranslations()
    const supabase = await createClient()

    // ★ TABLE-EXPORT-2b-2(Tim Q2):读取搬进 quotesRows.ts,与导出路由共用;只画最新 QUOTES_SHOWN 张,而且说出来。
    const [listRes, totalRes] = await Promise.all([quotesPage(supabase, 0, QUOTES_SHOWN - 1, sort), quotesCount(supabase)])
    const rows = mustRows(listRes, 'quote_status')
    const total = mustCount(totalRes, 'quote_status count')

    return (
        <ListPage
            title={t('quotes.listTitle')}
            intro={t('quotes.listNote')}
            actions={
                <Button asChild>
                    <Link href="/sales/quotes/new">{t('quotes.newQuote')}</Link>
                </Button>
            }
            // 【沿用这一页原本那句空态】(PAGE-0 §⑨)。
            // 【不分两种空】—— 一张报价没有"太少所以说明不了问题":一份报价就是一份报价。
            state={rows.length === 0 ? { kind: 'empty', noRows: t('quotes.empty') } : { kind: 'ok' }}
        >
            <RowCapNotice shown={rows.length} total={total} />
            <QuotesTable rows={rows} sort={sort} total={total} exportHref={quotesExportHref(sort)} />
        </ListPage>
    )
}

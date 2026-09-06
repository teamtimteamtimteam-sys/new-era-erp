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
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import QuotesTable, { type QuoteRow } from './QuotesTable'

export default async function QuotesPage() {
    const denied = await requireModule(MOD.sales)
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()

    const rows = mustRows(
        await supabase.from('quote_status')
            .select('quote_id, code, customer_code, customer_name, quote_date, valid_until, currency, status, expired, converted_order_id, converted_order_code, issue_version')
            .order('quote_date', { ascending: false })
            .limit(200),
        'quote_status') as unknown as QuoteRow[]

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
            <QuotesTable rows={rows} />
        </ListPage>
    )
}

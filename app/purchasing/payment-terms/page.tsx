// app/purchasing/payment-terms/page.tsx
// 付款条款模板列表:名称、说明、各期摘要(紧凑一行)、启用状态、编辑入口。
// 模板只为省去回头客的重复录入 —— 不是标准条款,系统也不预置任何模板。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import { ListPage } from '@/app/components/ui/list-page'
import TemplatesTable, { type TemplateRow } from './TemplatesTable'
import { mustRows } from '@/lib/db-helpers'
import { loadPaymentTriggerEvents, triggerLabel } from '@/lib/paymentTriggers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type TemplateLine = {
    template_id: string
    seq: number
    label: string
    percentage: number | null
    fixed_amount_ccy: number | null
    trigger_event: string
    days_offset: number | null
}

export default async function PaymentTermTemplatesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [tplRes, lineRes] = await Promise.all([
        supabase
            .from('payment_term_templates')
            .select('id, name, description, is_active, currency')
            .is('deleted_at', null)
            .order('name'),
        supabase
            .from('payment_term_template_lines_masked')
            .select('template_id, seq, label, percentage, fixed_amount_ccy, trigger_event, days_offset')
            .order('seq'),
    ])

    const templates = mustRows(tplRes)
    const linesByTpl = new Map<string, TemplateLine[]>()
    for (const l of (lineRes.data as TemplateLine[] | null) ?? []) {
        const arr = linesByTpl.get(l.template_id) ?? []
        arr.push(l)
        linesByTpl.set(l.template_id, arr)
    }

    // EQP-PAY-1:里程碑的名字来自字典(按界面语言选一个,不拼接)——
    // 加第七种里程碑是一行数据,包括它叫什么。
    const locale = await getLocale()
    const triggerNames = new Map(
        (await loadPaymentTriggerEvents(supabase)).map((e) => [e.code, triggerLabel(e, locale)])
    )

    // 各期摘要:"60% 下单时 · 30% 到货时 · 10% 化验后"(定额期显示金额)
    // 定额腿的币种由【模板头】payment_term_templates.currency 声明(FIN-29)——
    // 这里带着它一起画。原先写死的 " USD" 是 FIN-29 之前的遗留:同一个模板
    // 套到 USD 单与 SGD 单上,那个数字是两笔差着一个汇率的钱。
    const summary = (tplId: string, tplCurrency: string | null) =>
        (linesByTpl.get(tplId) ?? [])
            .map((l) => {
                const share =
                    l.percentage !== null ? `${l.percentage}%` : formatAmount(l.fixed_amount_ccy, tplCurrency)
                const trigger = triggerNames.get(l.trigger_event) ?? l.trigger_event
                const offset =
                    l.trigger_event === 'fixed_date' && l.days_offset !== null
                        ? ` +${l.days_offset}d`
                        : ''
                return `${share} ${trigger}${offset}`
            })
            .join(' · ')

    // CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— 抬头「新建模板」
    // 住在 actions 里(状态分支之前)。
    const tableRows: TemplateRow[] = templates.map((tpl) => ({
        id: tpl.id,
        name: tpl.name,
        description: tpl.description ?? '—',
        termsSummary: summary(tpl.id, tpl.currency) || '—',
        isActive: Boolean(tpl.is_active),
    }))

    return (
        <ListPage
            title={t('purchasing.templatesTitle')}
            maxWidth="max-w-5xl"
            actions={
                <Button asChild>
                    <Link href="/purchasing/payment-terms/new">{t('purchasing.newTemplate')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <p className="text-sm text-gray-600 mb-4">
                {t('finance.recordCount', { count: templates.length })}
            </p>
            <TemplatesTable rows={tableRows} empty={t('purchasing.templatesEmpty')} />
        </ListPage>
    )
}

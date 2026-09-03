// COMM-1:佣金协议登记簿。
//
// ★【整页服务端渲染,没有客户端开关】★ 藏在开关后面的话,fetch 冒烟永远看不见
//   (那条盲区记在 AGENTS.md)。本页每一句都在初次 HTML 里。
//
// ★★【这一页上两句话是【无条件】渲染的,而那不是排版偏好】★★
//   · notPosted —— 「它只记条款,不过账、不算钱」。
//     把"佣金上线了"读成"佣金会进总账",代价是有人以为账上已经有这笔支出。
//   · noAccrual —— 「算出某一笔欠多少那一半没有建(COMM-ACCRUAL-1)」。
//   两句都【与有没有数据无关】,所以它们不放在任何 length 判断里面 ——
//   一条只在有数据时才出现的警告,等于没有警告。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import CommissionsTable, { type CommissionRow } from './CommissionsTable'
import Link from 'next/link'

type Agreement = {
    id: string
    agent_supplier_id: string
    side: string
    basis: string
    rate_pct: number | null
    amount_ccy: number | null
    currency: string | null
    recognition_trigger: string
    valid_from: string
    valid_to: string
    remarks: string | null
    suppliers: { code: string; legal_name: string } | null
}

export default async function CommissionsPage() {
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const rows = mustRows(
        await supabase
            .from('commission_agreements')
            .select('id, agent_supplier_id, side, basis, rate_pct, amount_ccy, currency, recognition_trigger, valid_from, valid_to, remarks, suppliers!commission_agreements_agent_supplier_id_fkey(code, legal_name)')
            .is('deleted_at', null)
            .order('valid_from', { ascending: false }),
        'commission_agreements') as unknown as Agreement[]

    // 【把嵌套的关联压平成纯数据】—— 函数过不了客户端边界,嵌套对象过得了,
    // 但压平之后列描述符不必再知道这个 select 的形状。
    const tableRows: CommissionRow[] = rows.map((r) => ({
        id: r.id, side: r.side, basis: r.basis,
        rate_pct: r.rate_pct, amount_ccy: r.amount_ccy, currency: r.currency,
        recognition_trigger: r.recognition_trigger,
        valid_from: r.valid_from, valid_to: r.valid_to, remarks: r.remarks,
        agentCode: r.suppliers?.code ?? null,
        agentName: r.suppliers?.legal_name ?? null,
    }))

    return (
        <ListPage
            title={t('commissions.title')}
            intro={t('commissions.what')}
            actions={
                <Link href="/commissions/new" className="text-sm text-blue-600 hover:underline">
                    {t('commissions.newTitle')}
                </Link>
            }
            // ★★【两块提示走 notices —— 它们【无条件】渲染,空态也画】★★
            //   原页面抬头写着理由:「一条只在有数据时才出现的警告,等于没有警告。」
            //   本刀第一版把它们放进了 children,而 children 只在 ok 分支画 ——
            //   于是一张空的登记簿会【安静地】少掉这两句。ListPage 因此长出了
            //   notices 这个槽,见那里的说明。
            notices={
                <>
                    <div className="border-l-4 border-amber-500 bg-amber-50 p-3 mb-3 max-w-3xl">
                        <p className="text-sm text-gray-800">{t('commissions.notPosted')}</p>
                    </div>
                    <div className="border-l-4 border-gray-400 bg-gray-50 p-3 mb-6 max-w-3xl">
                        <p className="text-sm text-gray-800">{t('commissions.noAccrual')}</p>
                    </div>
                </>
            }
            // 【空态沿用这一页原本那句话】(PAGE-0 §⑨:沿用已有文案键)。
            // 【不分两种空】—— 一份佣金协议登记簿没有"太少所以说明不了问题"这回事:
            // 三份协议就是三份协议,它不是一条要够多点才画得出的趋势线。
            state={tableRows.length === 0
                ? { kind: 'empty', noRows: t('commissions.none') }
                : { kind: 'ok' }}
        >
            <CommissionsTable rows={tableRows} />
        </ListPage>
    )
}

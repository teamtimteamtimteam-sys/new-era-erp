'use client'

// PUR-1:这张采购单挂在哪一份合同之下。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【三种状态,三句不同的话 —— 而"没有合同可挂"必须与"你看不见合同"分开】★★
// ════════════════════════════════════════════════════════════════════════════
//   ① 已经挂上了 → 印出合同编号与【条款是什么时候冻下来的】,并说明它不能改挂。
//   ② 没挂,而这家供应商名下有生效中的合同 → 一个下拉框加一个按钮。
//   ③ 没挂,而下拉框是空的 → **空不是一句话,它有三种成因**:
//        · 合同登记簿【整个是空的】(本刀落地当天:线上 0 份合同);
//        · 这家供应商名下没有【生效中】的合同(草稿不算 —— 草稿明说拒收单据);
//        · 你没有 module.suppliers.view,合同对你【根本不可见】。
//      三句话分开说。一个笼统的"没有可选项"会把第三种读成第一种,
//      而那正是 contract_coverage 的表注写下的那条:
//      **一个永远为真的判词是装饰**,一个说不清成因的空集也是。
//
// ★【没有"改挂",也没有"解挂"】★(Tim 2026-09-08 裁定 Q5)
//   改挂等于把一张单据当初依据的条款换掉 —— 那是改历史。
//   DB 那一侧 DOCUMENT_ALREADY_UNDER_CONTRACT 按名拒,这里连按钮都不摆:
//   摆一个注定被拒的按钮,比没有按钮更坏(CMP-2)。
//
// 【采购单可以【没有】合同,而且那是正当的】现货采购本来就没有合同 ——
// 所以这个面板不带任何催促的字眼,也【不】把"未挂合同"画成一个待办。
//
// ★【已作废 / 已结束的单,这个面板【照常】显示 —— 而那是一次克制,不是一次疏忽】★
//   link_document_to_contract 【刻意不看单据状态】,与它刻意不看"单据日期落在
//   合同期之外"是同一条(见那支函数抬头:没有裁定就按名拒,买到的是绕过它的办法,
//   不是控制)。事后给一张已结束的单补挂合同,是一次正当的回填 ——
//   合同登记簿本来就要能回答"这张单当初依据什么"。
//   ★ 所以这里【不】自己加一条"作废单不许挂"★:那会是一条【没有人裁过】的规矩,
//     而且它会与 DB 那一侧说两句不一样的话。要立这条规矩,先要有一次裁定,
//     而且它该立在那支函数里,不是立在这个组件里。
import { useActionState } from 'react'
import { linkOrderToContract, type LinkContractState } from './contractActions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export type ContractOption = { id: string; code: string; title: string | null }

const initialState: LinkContractState = {}

export default function ContractLinkPanel({
    poId,
    linkedCode,
    linkedAt,
    options,
    canSeeContracts,
    registerIsEmpty,
}: {
    poId: string
    /** 已经挂上的合同编号 —— 读的是【抄下来的那一份】(contract_document_terms) */
    linkedCode: string | null
    linkedAt: string | null
    options: ContractOption[]
    /** 有没有 module.suppliers.view —— 没有的话,空下拉框的成因是"看不见" */
    canSeeContracts: boolean
    /** 合同登记簿整个是不是空的 —— 与"这家供应商没有生效合同"是两件事 */
    registerIsEmpty: boolean
}) {
    const t = useTranslations()
    const linkWithId = linkOrderToContract.bind(null, poId)
    const [state, formAction, isPending] = useActionState(linkWithId, initialState)

    return (
        <div className="border border-gray-200 rounded p-4 mb-4">
            <h2 className="font-semibold mb-2">{t('purchasing.contract.title')}</h2>

            {linkedCode ? (
                <>
                    <p className="text-sm">
                        <span className="font-mono font-medium">{linkedCode}</span>
                    </p>
                    {/* ★【冻的是【挂接】那一刻的条款,不是下单那天的】★
                        CONTRACT-1 刻意允许回填挂接,所以这句话要当场说出来 ——
                        link_document_to_contract 的返回里带着 terms_frozen_as_of,
                        /contracts 页也印它。对品位规格这条边不算锋利,对钱锋利。 */}
                    {linkedAt && (
                        <p className="text-xs text-gray-500 mt-1">
                            {t('purchasing.contract.frozenAt', {
                                at: new Date(linkedAt).toISOString().slice(0, 16).replace('T', ' '),
                            })}
                        </p>
                    )}
                    <p className="text-xs text-gray-500 mt-2">{t('purchasing.contract.cannotRelink')}</p>
                </>
            ) : !canSeeContracts ? (
                // ③-c 你看不见合同 —— 这不是"没有合同"
                <p className="text-sm text-gray-600">{t('purchasing.contract.noPermission')}</p>
            ) : registerIsEmpty ? (
                // ③-a 登记簿整个是空的
                <p className="text-sm text-gray-600">{t('purchasing.contract.registerEmpty')}</p>
            ) : options.length === 0 ? (
                // ③-b 这家供应商名下没有【生效中】的合同
                <p className="text-sm text-gray-600">{t('purchasing.contract.noActiveForSupplier')}</p>
            ) : (
                <form action={formAction} className="flex flex-wrap items-end gap-3">
                    <div>
                        <label className="block text-xs text-gray-600 mb-1">
                            {t('purchasing.contract.choose')}
                        </label>
                        {/* 【清单只装【这家供应商的、生效中的买方合同】】—— 三条判据都在
                            服务端那次查询里,与 DB 那三条拒绝说的是同一件事。
                            这里是【礼貌】:把注定被拒的选项先不摆出来。
                            把关仍在 link_document_to_contract —— 直连 PostgREST 也逃不掉。 */}
                        <select name="contract_id" required
                            className="w-72 border border-gray-300 px-2 py-1.5 rounded text-sm">
                            <option value="">{t('common.select')}</option>
                            {options.map((c) => (
                                <option key={c.id} value={c.id}>
                                    {c.code}{c.title ? ` — ${c.title}` : ''}
                                </option>
                            ))}
                        </select>
                    </div>
                    <Button type="submit" disabled={isPending}>
                        {isPending ? t('common.saving') : t('purchasing.contract.link')}
                    </Button>
                    <p className="w-full text-xs text-gray-500">{t('purchasing.contract.optional')}</p>
                </form>
            )}

            {/* 拒绝就地显示 —— 挂错一次要【被读懂】,而不是被反复重试 */}
            {state.error && (
                <p className="mt-3 text-sm text-red-700 bg-red-50 border border-red-300 rounded px-3 py-2">
                    {state.error}
                </p>
            )}
        </div>
    )
}

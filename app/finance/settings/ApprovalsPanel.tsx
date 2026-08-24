// SOD-1:审批开关的状态面板 —— **只读**。
//
// 【为什么这一页没有"打开审批"的按钮,而这是一个决定,不是一处遗漏】
// 打开审批不是拨一个开关:它要求同一次改动里配齐三个策略值(一级审批角色、
// 金额门槛、二级审批人),而那三个值里有两个是【业务决定】,不是可以从屏幕上
// 猜出来的默认。数据库那道闸(guard_approvals_switch)已经保证"开着但没配"
// 这个状态【到不了】—— 所以这一页的职责是把话说清楚,让做决定的人看见自己
// 在决定什么,而不是给一个按下去就会被拒绝的按钮。
// **一个只会招来拒绝的按钮,与一个没有的按钮相比,只多了一次失败。**
//
// 【NULL 在这里不许读成"不需要审批"】三个策略值现在都是 NULL,而 NULL 的意思是
// 【没有人决定过】,不是【不需要】。这一页把这句话写在每一行旁边 ——
// 那正是 lib/permissions.ts 存在的理由的同一条:空着已经有别的含义了。
import { getTranslations } from '@/lib/i18n/server'

type Readiness = {
    enabled: boolean
    level1_role_code: string | null
    level1_real_holders: number
    level1_holders_who_cannot_raise: number
    threshold_base: string | number | null
    level2_user_id: string | null
    level2_user_is_real: boolean
    pending_purchase_orders: number
    blocking: string[]
    can_enable: boolean
    can_disable: boolean
}

export default async function ApprovalsPanel({ r }: { r: Readiness }) {
    const t = await getTranslations()

    const Row = ({ label, value, unsetNote }: {
        label: string; value: string | null; unsetNote: string
    }) => (
        <div className="flex flex-wrap items-baseline gap-x-2 py-1">
            <span className="text-gray-600 text-sm">{label}:</span>
            {value ? (
                <span className="font-mono text-sm">{value}</span>
            ) : (
                <>
                    <span className="text-amber-800 text-sm font-medium">
                        {t('finance.approvals.notDecided')}
                    </span>
                    <span className="text-xs text-gray-600">— {unsetNote}</span>
                </>
            )}
        </div>
    )

    return (
        <div className="border border-gray-200 rounded p-4 mb-6">
            <h2 className="font-semibold mb-1">{t('finance.approvals.title')}</h2>

            <p
                className={
                    'text-sm mb-3 inline-block px-2 py-1 rounded border ' +
                    (r.enabled
                        ? 'bg-green-50 border-green-300 text-green-900'
                        : 'bg-amber-50 border-amber-300 text-amber-900')
                }
            >
                {r.enabled ? t('finance.approvals.on') : t('finance.approvals.off')}
            </p>

            <Row
                label={t('finance.approvals.level1')}
                value={r.level1_role_code}
                unsetNote={t('finance.approvals.level1Unset')}
            />
            <Row
                label={t('finance.approvals.threshold')}
                value={r.threshold_base === null ? null : String(r.threshold_base)}
                unsetNote={t('finance.approvals.thresholdUnset')}
            />
            <Row
                label={t('finance.approvals.level2')}
                value={r.level2_user_id}
                unsetNote={t('finance.approvals.level2Unset')}
            />

            {/* 【一个忠告,不是一道闸】被裁定的一级角色 `finance` 自己就持有
                module.purchasing.edit,于是「结构上提不了单」的审批人可能是 0 个。
                **报告而不拦**:做成拒绝会让 Tim 自己裁定的策略开不起来,
                而一道拦住既定决定的闸是一道会被绕过去的闸。 */}
            {r.level1_role_code && r.level1_holders_who_cannot_raise === 0 && (
                <p className="mt-2 text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1">
                    {t('finance.approvals.noEligibleApprover', { role: r.level1_role_code })}
                </p>
            )}

            {/* 【开关翻过去会发生什么】—— 两个方向都写,因为会搁死单据的是【关】那一边 */}
            <div className="mt-3 text-xs text-gray-700 space-y-1">
                <p className="font-medium">{t('finance.approvals.whatFlipDoes')}</p>
                <p>{t('finance.approvals.flipOn')}</p>
                <p>{t('finance.approvals.flipOff', { n: String(r.pending_purchase_orders) })}</p>
            </div>

            {/* readiness 与闸读的是同一份判据(fixture 127 的 C8 钉这一条) */}
            {!r.enabled && (
                <p className="mt-3 text-xs">
                    {r.can_enable ? (
                        <span className="text-green-800">{t('finance.approvals.canEnable')}</span>
                    ) : (
                        <span className="text-amber-800">
                            {t('finance.approvals.cannotEnable', {
                                what: r.blocking.join(', '),
                            })}
                        </span>
                    )}
                </p>
            )}

            <p className="mt-3 text-xs text-gray-500">{t('finance.approvals.howToTurnOn')}</p>
        </div>
    )
}

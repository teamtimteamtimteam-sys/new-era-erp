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
    level1_holders_total: number
    level1_real_holders: number
    level1_can_see_amounts: boolean
    level1_holders_who_cannot_raise: number
    threshold_base: string | number | null
    // CHAIN-BUILD-1(R1):二级从【具名的人】改成【角色】,与一级同形。
    level2_role_code: string | null
    level2_holders_total: number
    level2_real_holders: number
    level2_can_see_amounts: boolean
    pending_purchase_orders: number
    // ★★ APR-3(Tim 的 Q6):逐链的在途张数,与【会挡住关闭的】那个数。
    //   两个长得一样的数,问的不是同一件事,所以它们是两个字段 ——
    //   而两个都出自同一支函数(approval_pending_documents),于是屏幕与闸
    //   不可能各读一份判据。判别的那一句话:**这条链的决定函数,在审批关着
    //   的时候还跑不跑得动?** 跑不动才算"会被搁死"。
    pending_by_chain: {
        subject_type: string
        pending: number
        blocks_disable: boolean
        amount_unknown: number
    }[]
    pending_blocking_disable: number
    // ★ APR-2:逐条"这条链有几个人批得动"。**一个数,不是一个布尔** ——
    //   要分开的是"哪一条链死了、死在哪一级、缺的是哪个码"。
    chain_gates: {
        subject_type: string
        action_function: string
        level: number
        role_code: string | null
        gate_permissions: string[]
        approvers: number
    }[]
    chains_without_approver: number
    blocking: string[]
    can_enable: boolean
    can_disable: boolean
    no_deputy_by_decision: boolean
}

export default async function ApprovalsPanel({ r }: { r: Readiness }) {
    const t = await getTranslations()

    // ★【三种状态,三句不同的话 —— 这是本刀在屏幕上的全部要点】★
    const HolderState = ({ role, total, real, sees }: {
        role: string; total: number; real: number; sees: boolean
    }) => (
        <div className="ml-4 mb-1 space-y-1">
            {real > 0 ? (
                <p className="text-xs text-green-800">
                    {t('finance.approvals.holdersOk', { n: String(real), role })}
                </p>
            ) : total > 0 ? (
                /* ★ 中间态:有人持有,但他登录不了。**不是"没有人"** ★ */
                <p className="text-xs text-red-800 bg-red-50 border border-red-200 rounded px-2 py-1">
                    {t('finance.approvals.holdersCannotSignIn', { n: String(total), role })}
                </p>
            ) : (
                <p className="text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1">
                    {t('finance.approvals.holdersNone', { role })}
                </p>
            )}
            {!sees && (
                /* R4:看不见金额的角色批的是自己看不见的数字 */
                <p className="text-xs text-red-800 bg-red-50 border border-red-200 rounded px-2 py-1">
                    {t('finance.approvals.cannotSeeAmounts', { role })}
                </p>
            )}
        </div>
    )

    const Row = ({ label, value, unsetNote }: {
        label: string; value: string | null; unsetNote: string
    }) => (
        <div className="flex flex-wrap items-baseline gap-x-2 py-1">
            <span className="text-[color:var(--brand-muted-text)] text-sm">{label}:</span>
            {value ? (
                <span className="text-sm">{value}</span>
            ) : (
                <>
                    <span className="text-amber-800 text-sm font-medium">
                        {t('finance.approvals.notDecided')}
                    </span>
                    <span className="text-xs text-[color:var(--brand-muted-text)]">— {unsetNote}</span>
                </>
            )}
        </div>
    )

    return (
        <div className="border border-gray-200 rounded p-4 mb-6">
            <h2 className="mb-1">{t('finance.approvals.title')}</h2>

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

            {/* ★★【每一级三样都要说出来:哪个角色、几个人、看不看得见金额】★★
                （CHAIN-BUILD-1）而"几个人"不是一个数,是【两个】数的关系:
                  · total = 0            → 没有人持有这个角色
                  · total > 0, real = 0  → ★有人持有,但那个人登录不了★
                  · real > 0             → 有能干活的人
                中间那一种若报成"没有持有人",操作的人会去【再授一次权】,
                而那个角色已经授过了 —— 再授一次不会改变任何事。 */}
            <Row
                label={t('finance.approvals.level1')}
                value={r.level1_role_code}
                unsetNote={t('finance.approvals.level1Unset')}
            />
            {r.level1_role_code && (
                <HolderState
                    role={r.level1_role_code}
                    total={r.level1_holders_total}
                    real={r.level1_real_holders}
                    sees={r.level1_can_see_amounts}
                />
            )}
            <Row
                label={t('finance.approvals.threshold')}
                value={r.threshold_base === null ? null : String(r.threshold_base)}
                unsetNote={t('finance.approvals.thresholdUnset')}
            />
            <Row
                label={t('finance.approvals.level2')}
                value={r.level2_role_code}
                unsetNote={t('finance.approvals.level2Unset')}
            />
            {r.level2_role_code && (
                <HolderState
                    role={r.level2_role_code}
                    total={r.level2_holders_total}
                    real={r.level2_real_holders}
                    sees={r.level2_can_see_amounts}
                />
            )}

            {/* 【一个忠告,不是一道闸】被裁定的一级角色 `finance` 自己就持有
                module.purchasing.edit,于是「结构上提不了单」的审批人可能是 0 个。
                **报告而不拦**:做成拒绝会让 Tim 自己裁定的策略开不起来,
                而一道拦住既定决定的闸是一道会被绕过去的闸。 */}
            {r.level1_role_code && r.level1_holders_who_cannot_raise === 0 && (
                <p className="mt-2 text-xs text-amber-800 bg-amber-50 border border-amber-200 rounded px-2 py-1">
                    {t('finance.approvals.noEligibleApprover', { role: r.level1_role_code })}
                </p>
            )}

            {/* ════════════════════════════════════════════════════════════════
                ★★ APR-2:每一条接上引擎的链,真的有人批得动吗 ★★
                ════════════════════════════════════════════════════════════════
                上面那两块问的是【角色】:有没有真人、看不看得见金额。
                两个都为真时,这条链仍然可以是死的 —— 持有那个角色的人,
                可能根本进不了那张单据所在的模块。
                ★ 这不是假设:WO-1b 就是这么在线上造出一把锁的,而三道闸全绿。
                ☞ 所以它【印在屏幕上】,而不是只活在闸里:一块说"可以开"、
                  而闸会拒绝的屏幕,正是这块面板存在理由的反面。 */}
            <div className="mt-3">
                <p className="text-xs font-medium text-[color:var(--brand-text)]">
                    {t('finance.approvals.chainGatesTitle')}
                </p>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">
                    {t('finance.approvals.chainGatesWhy')}
                </p>
                <div className="ml-4 space-y-1">
                    {(r.chain_gates ?? []).map((c) => (
                        <p
                            key={`${c.action_function}-${c.level}`}
                            className={
                                'text-xs rounded px-2 py-1 border ' +
                                (c.approvers > 0
                                    ? 'text-green-800 bg-green-50 border-green-200'
                                    : 'text-red-800 bg-red-50 border-red-300')
                            }
                        >
                            {c.approvers > 0
                                ? t('finance.approvals.chainGateOk', {
                                      action: c.action_function,
                                      level: String(c.level),
                                      role: c.role_code ?? '—',
                                      n: String(c.approvers),
                                  })
                                : t('finance.approvals.chainGateDead', {
                                      action: c.action_function,
                                      level: String(c.level),
                                      role: c.role_code ?? '—',
                                      perms: c.gate_permissions.join(' + '),
                                  })}
                        </p>
                    ))}
                </div>
            </div>

            {/* ════════════════════════════════════════════════════════════════
                ★★ APR-3:逐链的在途张数 ★★
                ════════════════════════════════════════════════════════════════
                此前这块屏幕只说"有几张采购单在等",而审批已经管着好几条链了 ——
                一个只数其中一条的数,读起来像"总共就这些"。
                ★ 而【会挡住关闭的】是另一个更窄的问题,所以它单独一行写出来:
                  两个数不一样的时候,人要看得见差在哪条链上,而不是猜。 */}
            <div className="mt-3">
                <p className="text-xs font-medium text-[color:var(--brand-text)]">
                    {t('finance.approvals.pendingTitle')}
                </p>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">
                    {t('finance.approvals.pendingWhy')}
                </p>
                <div className="ml-4 space-y-1">
                    {(r.pending_by_chain ?? []).length === 0 ? (
                        <p className="text-xs text-[color:var(--brand-muted-text)]">
                            {t('finance.approvals.pendingNone')}
                        </p>
                    ) : (
                        (r.pending_by_chain ?? []).map((c) => (
                            <p key={c.subject_type} className="text-xs text-[color:var(--brand-text)]">
                                {t(
                                    c.blocks_disable
                                        ? 'finance.approvals.pendingBlocks'
                                        : 'finance.approvals.pendingFree',
                                    {
                                        subject: t('finance.approvals.subject_' + c.subject_type),
                                        n: String(c.pending),
                                    }
                                )}
                                {/* ★ 分不出档的那些单独说 —— 把它们混进计数里读成零,
                                    就是把"我不知道"说成"没有" */}
                                {c.amount_unknown > 0 && (
                                    <span className="ml-1 text-amber-800">
                                        {t('finance.approvals.pendingUnknownAmount', {
                                            n: String(c.amount_unknown),
                                        })}
                                    </span>
                                )}
                            </p>
                        ))
                    )}
                </div>
            </div>

            {/* 【开关翻过去会发生什么】—— 两个方向都写,因为会搁死单据的是【关】那一边 */}
            <div className="mt-3 text-xs text-[color:var(--brand-text)] space-y-1">
                <p className="font-medium">{t('finance.approvals.whatFlipDoes')}</p>
                <p>{t('finance.approvals.flipOn')}</p>
                <p>{t('finance.approvals.flipOff', { n: String(r.pending_purchase_orders) })}</p>
            </div>

            {/* readiness 与闸读的是同一份判据(fixture 127 的 C8 钉这一条) */}
            {!r.enabled && (
                <p className="mt-3 text-xs text-[color:var(--brand-muted-text)]">
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

            {/* ★【没有代理人、没有升级 —— 一条裁定,不是一处遗漏】★(R2)
                无条件渲染:它与有没有配置无关,而一个只在出事时才出现的说明
                等于没有说明。语气与"匿名化函数永久拒绝"那一条相同。 */}
            <p className="mt-3 text-xs text-[color:var(--brand-text)] bg-gray-50 border border-gray-200 rounded px-2 py-1">
                {t('finance.approvals.noDeputy')}
            </p>

            <p className="mt-3 text-xs text-[color:var(--brand-muted-text)]">{t('finance.approvals.howToTurnOn')}</p>
        </div>
    )
}

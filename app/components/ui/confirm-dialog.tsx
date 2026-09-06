'use client'

// app/components/ui/confirm-dialog.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONFIRM-1(2026-09-06)· 一个确认对话框,取代 40 处 window.confirm
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么原来那个不行 —— 三条,而第三条从来没有人说出口】
//   ① 样式够不着它。BTN-1 把破坏档画成淡底 + 实线左竖条,而它背后那一步
//      是一个操作系统的灰盒子 —— 四档之间辛苦做出的区别,在最要紧的那一刻消失。
//   ② 【它说不出自己在确认什么】。一张十行的附件表,每行一个删除钮,
//      而盒子里只问「Delete this attachment?」——【哪一个?】它答不上来。
//      实测:40 处里有 28 处不点名,其中 11 处正在这种列表里(见文末 B 类)。
//   ③ ★【它对冒烟是隐形的】★ 原生对话框自动化点不到,所以这 40 步确认
//      **一次都没有被机器走过**。app/tools/tasks/[id]/TaskHeader.tsx 的注释
//      早就把这件事记下来了 —— 它因此手写了一个"点两次"的确认。
//      那不是覆盖率变小,那是【整整一类动作从来没有进过探针的视野】,
//      与 FIX-2b 的 SMOKE-SINGLE-ROLE-BLINDSPOT 同一个形状。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【subject 是必填的,而这不是一句约定 —— 它有类型,还有一道闸】★
// ════════════════════════════════════════════════════════════════════════════
//   一个可选的 subject 一定会被省略:上面那 28 处就是证据 —— 每一处的调用点
//   【手里都有】那个名字,只是原来的 API 没有地方放它。
//   所以这里 `subject: string` 是必填 prop(编译期),
//   而 scripts/check-confirm-subject.mjs 另外拦住三种"填了等于没填":
//   空串、只有空白、以及英文里含 "this " 的整句式消息(那正是旧消息的写法)。
//   **只有类型没有闸,规矩会漂;而 Tim 拒绝两套习惯的理由,正是漂移。**
//
// ════════════════════════════════════════════════════════════════════════════
// ★【两个机制,一个习惯】(Tim 在 CONFIRM-1 闸上裁定)★
// ════════════════════════════════════════════════════════════════════════════
//   <ConfirmButton>  —— 「一个按钮 + 一个动作」。组件自己拥有触发钮与
//                       对话框;确认钮【直接调用 onConfirm】,不经过 Promise。
//     ★ 为什么不走 await ★:原来的 window.confirm 是【同步】的,
//       `if (!confirm()) return` 之后那一行仍在同一次用户手势里,
//       startTransition 也在同一拍打开。改成 await 会把动作推过一个微任务边界,
//       isPending 亮起的时刻、以及 React 把它算进哪一次转换,都会变。
//       让对话框自己那一次点击去调用动作,动作仍然在【一次真实的用户手势】里 ——
//       这是两种改法里【行为差得更小】的那一种。
//
//   ★【BTN-4 删掉了 useConfirm()】★ CONFIRM-1 连同组件一起留了一个 Promise 版,
//     打算给「表单提交 / 行内判断 / map 里的 onClick」那几种塞不进一个按钮的调用点。
//     **它最终一个消费者都没有**(BTN-4 实测:全库 0 处调用),而 BTN-4 折进来的
//     7 处 ReasonPrompt 也全是「一个按钮一个动作」,ConfirmButton 每一处都合身。
//     ☞ 一个零消费者的导出,是【做同一件事的第二种办法】,躺在那里等一个不知道
//       已经有第一种办法的人捡起来 —— 而"两套习惯"正是本组件存在的理由。
//       真需要 Promise 形状的那一天,从 git 历史里取回来,比现在留着便宜。
//     ☞ scripts/check-confirm-subject.mjs 里那一支 useConfirm 解析【故意留着】:
//       它守的是"那一天",而不是今天的代码;为了落地一次迁移去动闸,是本刀明令禁止的。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【驳回那一侧必须是默认的】★
//   Escape 关、点外面关、而【初始焦点落在「取消」上,不是确认上】。
//   一个会被顺手一个回车确认掉的对话框,比它取代的那个灰盒子更坏 ——
//   原生 confirm 的默认按钮至少是"确定"这件事人尽皆知,而一个自制的不是。
//   焦点在开着的时候【关在里面】,关掉之后【还给触发它的那个钮】。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { Button } from '@/app/components/ui/button'
import { useTranslations } from '@/lib/i18n/client'

/** 确认钮取【它所确认的那个动作】的档位。删除 → destructive;撤销 → reversal。 */
export type ConfirmTier = 'destructive' | 'reversal' | 'default'

export type ConfirmContent = {
    /** ★ 必填:这一次确认【说的是哪一个东西】。批号、人名、期间名、文件名。 */
    subject: string
    /** 那句问话。不要把 subject 拼进来 —— 它自己有位置。 */
    title: string
    /** 可选的补充说明:后果、以及有没有更轻的做法。 */
    body?: string
    /**
     * 结构化的正文。薪资过账要逐条列出会动的科目 ——
     * 原来那一处是 `${t('hr.postConfirm')}\n\n${lines}`,
     * 把一张表拼成一个字符串塞进灰盒子里。**那是原生对话框在主动毁掉信息。**
     */
    details?: React.ReactNode
    /** 确认钮上的字。用动词(Delete / Post / Reopen),不要用 OK。 */
    confirmLabel: string
    tier?: ConfirmTier
    /**
     * ★【要一句"为什么"】给了它,对话框就多一个必填的理由输入框,
     *   而确认钮在理由为空时【不可按】。
     *
     * 【判据是抄来的,不是新写的】空白判据用 `reason.trim() === ''`,
     * 与数据库里的 `p_reason IS NULL OR btrim(p_reason) = ''` 逐字对应。
     * ★ Tim 在 CONFIRM-1 裁定:**不许在这里另写一条空白判据** ——
     *   同一个问题的第二份实现,正是本组件存在的理由。
     * ★【出处链在 BTN-4 变短了一节,而它没有断】★ 这条判据原先抄自
     *   `app/components/ReasonPrompt.tsx`,那个文件已被 BTN-4 折进本组件并删除
     *   (见 git 历史)。**于是今天客户端只剩这一份实现,而它的权威仍然是数据库。**
     *   下一个想"顺手统一一下"的人:这里没有第二条规矩可统一了,
     *   要改就连同 db 那一句一起改。
     *
     * 【两层不是重复】客户端这一层只是不让人白跑一趟;服务端仍然是权威,
     * 绕过界面直接调 RPC 照样会撞上 DELETE_REASON_REQUIRED 那一族。
     */
    reason?: {
        /** 输入框的占位符 —— 说一个真的例子,不要说"请输入理由"。 */
        placeholder: string
    }
}

// ── 对话框本体 ──────────────────────────────────────────────────────────────

function ConfirmDialog({
    content,
    onAccept,
    onDismiss,
}: {
    content: ConfirmContent
    /** 带 reason 时,确认那一下把理由原样交出去。 */
    onAccept: (reason: string) => void
    onDismiss: () => void
}) {
    const t = useTranslations()
    const panelRef = React.useRef<HTMLDivElement>(null)
    const dismissRef = React.useRef<HTMLButtonElement>(null)
    const [reason, setReason] = React.useState('')
    // 与数据库 btrim 逐字同源 —— 出处链见 ConfirmContent.reason 的注释。
    const blank = reason.trim() === ''
    const titleId = React.useId()
    const subjectId = React.useId()

    // 【初始焦点落在驳回那一侧】—— 见抬头。
    React.useEffect(() => {
        dismissRef.current?.focus()
    }, [])

    // 【Escape 关;Tab 关在里面】两件事同一个监听器,因为它们是同一条规矩的两半:
    // 这个对话框在开着的时候,是【唯一】可以操作的东西。
    React.useEffect(() => {
        function onKeyDown(e: KeyboardEvent) {
            if (e.key === 'Escape') {
                e.preventDefault()
                onDismiss()
                return
            }
            if (e.key !== 'Tab') return
            const panel = panelRef.current
            if (!panel) return
            const focusable = panel.querySelectorAll<HTMLElement>(
                'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
            )
            if (focusable.length === 0) return
            const first = focusable[0]
            const last = focusable[focusable.length - 1]
            const active = document.activeElement
            // 焦点跑到外面去了(例如浏览器地址栏回来),先拉回来再说。
            if (!panel.contains(active)) {
                e.preventDefault()
                first.focus()
                return
            }
            if (e.shiftKey && active === first) {
                e.preventDefault()
                last.focus()
            } else if (!e.shiftKey && active === last) {
                e.preventDefault()
                first.focus()
            }
        }
        document.addEventListener('keydown', onKeyDown, true)
        return () => document.removeEventListener('keydown', onKeyDown, true)
    }, [onDismiss])

    const tier = content.tier ?? 'destructive'

    return (
        <div
            data-confirm-overlay="1"
            className="fixed inset-0 z-[200] flex items-end justify-center overflow-y-auto bg-black/40 p-4 sm:items-center"
            // 【点外面关】—— 判据是"这一下落在遮罩自己身上",不是冒泡上来的那些。
            onMouseDown={(e) => {
                if (e.target === e.currentTarget) onDismiss()
            }}
        >
            <div
                ref={panelRef}
                role="dialog"
                aria-modal="true"
                aria-labelledby={titleId}
                aria-describedby={subjectId}
                data-confirm-dialog="1"
                className="w-full max-w-md rounded-lg border border-[color:var(--brand-border)] bg-background p-5 shadow-xl"
            >
                <h2 id={titleId} className="text-base font-medium text-foreground">
                    {content.title}
                </h2>

                {/* ★ 被确认的那个东西 —— 这一格【就是这个组件存在的理由】。
                    它不是标题的一部分,因为它要能被探针单独读出来。 */}
                <p
                    id={subjectId}
                    data-confirm-subject={content.subject}
                    className="mt-2 rounded border-l-[3px] border-[color:var(--brand-border-strong)] bg-muted/60 px-3 py-2 text-sm font-medium break-words text-foreground"
                >
                    {content.subject}
                </p>

                {content.body && (
                    <p className="mt-3 text-sm text-muted-foreground">{content.body}</p>
                )}
                {content.details && <div className="mt-3">{content.details}</div>}

                {content.reason && (
                    <label className="mt-4 block">
                        <span className="mb-1 block text-xs text-muted-foreground">
                            {t('common.reasonRequired')}
                        </span>
                        <input
                            type="text"
                            value={reason}
                            onChange={(e) => setReason(e.target.value)}
                            placeholder={content.reason.placeholder}
                            data-confirm-reason="1"
                            /* ★★【回车不许离开这个框】★★(BTN-4)
                               本对话框【就地渲染,不走 portal】—— CONFIRM-1 是故意的,见抬头。
                               代价是:调用点若在一个 <form> 里,这个输入框就也在那个 form 里,
                               而【在文本框里按回车会隐式提交外层表单】(HTML 标准:向 form 的
                               default button 派一次 click)。对话框自己那两个钮都是
                               type="button",挡不住外面那一个。

                               ★【实测,不是推想】★ BTN-4 量过全部 7 处 ReasonPrompt 调用点
                               (委托书写的是 8 处 —— 第 8 处是个幻影,grep 命中的是 i18n 键
                               `withdrawReasonPrompt`),**三层渲染树里没有一处在 form 里**。
                               所以折进来【没有】制造出这个缺陷。

                               ☞ 而 TaskHeader.tsx:184 那一处 <ConfirmButton> 确实就在
                                 <form onSubmit> 里,那个 form 也确实有一个真的
                                 type="submit"(:164)。它今天安全,**只因为那一处没有声明
                                 reason,于是不渲染输入框** —— 一个 prop 的距离。
                               ★ 这一条【是 CONFIRM-1 自己量出来并写下的】,不是本刀发现的:
                                 docs/forward-queue.md 那条队列项逐字写着「唯一落在 <form>
                                 里的是 TaskHeader 的删除钮,而它没有 reason」。
                                 **BTN-4 的委托书把这句话转述成了"CONFIRM-1 测出七处里零处
                                 受影响",丢掉了"带 reason 的"这个限定,于是读起来像是
                                 CONFIRM-1 漏掉了一处。它没有漏。**
                                 —— 而这恰好又是 AGENTS.md 那条法则:一句话经过一次转述会
                                 变硬,下一刀把它当事实读。记在这里,免得再转述一次。

                               【为什么不是 portal】零个现存调用点的隐患,不值得把对话框搬出
                               CONFIRM-1 刻意保留的那棵树(焦点归还、动作跑在同一次用户手势里,
                               都挂在那上面)。preventDefault 一行就地封死,而且顺手让回车
                               【做那件有用的事】,而不是什么都不做。 */
                            onKeyDown={(e) => {
                                if (e.key !== 'Enter') return
                                e.preventDefault()          // ← 隐式提交死在这里
                                if (!blank) onAccept(reason)
                            }}
                            className="w-full rounded border border-[color:var(--brand-border)] bg-background px-2 py-1 text-sm"
                        />
                    </label>
                )}

                {/* 【驳回在前】—— DOM 顺序就是 Tab 顺序,而默认那一侧应该先到。 */}
                <div className="mt-5 flex flex-wrap items-center justify-end gap-2">
                    <Button
                        ref={dismissRef}
                        type="button"
                        variant="secondary"
                        data-confirm-dismiss="1"
                        onClick={onDismiss}
                    >
                        {t('common.cancel')}
                    </Button>
                    {/* 【空理由时不可按】—— 服务端必然拒绝的动作不该有可提交的控件。 */}
                    <Button
                        type="button"
                        variant={tier}
                        data-confirm-accept="1"
                        disabled={content.reason ? blank : undefined}
                        onClick={() => onAccept(reason)}
                    >
                        {content.confirmLabel}
                    </Button>
                    {content.reason && blank && (
                        <span className="text-xs text-muted-foreground">
                            {t('common.reasonBlankHint')}
                        </span>
                    )}
                </div>
            </div>
        </div>
    )
}

// ── 机制 (b):触发钮 + 对话框,给 34 处「一个按钮一个动作」──────────────────

type ConfirmButtonProps = ConfirmContent & {
    /** 确认之后要做的事。**与原来 `if (!confirm()) return` 之后那几行逐字相同。**
     *  声明了 `reason` 时,人填的那句话原样传进来。 */
    onConfirm: (reason: string) => void
    children: React.ReactNode
    disabled?: boolean
    className?: string
    /**
     * 触发钮的画法。
     * 【为什么默认是一个素 <button>】本刀【不】改这 34 个触发钮长什么样 ——
     * 那是 BTN-2 的事,而委托书把 BTN-2 明确排除在外。给了这个 prop 的调用点,
     * 是它原来就在用组件库的 <Button>;没给的,原样保留它自己的 className。
     */
    /**
     * ★ BTN-4:补上 'link' / 'warning' 与 size 'inline'(§八(b),库里缺能力先加进库)。
     *   折进来的 7 处 ReasonPrompt 里有两处是【表格单元格里的一段字】,不是盒子。
     *   照 size="default" 转过去,每一处会变成 h=32px 的盒子 —— BTN-2 §12.5 与
     *   BTN-3 的行内档抬头都为这同一件事付过账。这里不是放宽,是把 <Button>
     *   本来就有的档位如实暴露出来:两个联合原先【比 Button 自己窄】,
     *   于是调用点只能绕开 triggerVariant 去写 className,那正是漂移的入口。
     */
    triggerVariant?:
        | 'default' | 'secondary' | 'destructive' | 'reversal'
        | 'outline' | 'ghost' | 'link' | 'warning'
    triggerSize?: 'default' | 'sm' | 'xs' | 'lg' | 'inline'
}

export function ConfirmButton({
    onConfirm,
    children,
    disabled,
    className,
    triggerVariant,
    triggerSize,
    ...content
}: ConfirmButtonProps) {
    const [open, setOpen] = React.useState(false)
    const triggerRef = React.useRef<HTMLButtonElement>(null)

    // 【关掉之后焦点还给触发它的那个钮】—— 不这么做的话,焦点回到 <body>,
    // 用键盘的人被扔回页首,而他刚才在一张表的第七行。
    const close = React.useCallback(() => {
        setOpen(false)
        triggerRef.current?.focus()
    }, [])

    const accept = React.useCallback((reason: string) => {
        setOpen(false)
        triggerRef.current?.focus()
        // ★ 动作在【对话框这一次点击】里跑 —— 同一次用户手势,没有 await。见抬头。
        onConfirm(reason)
    }, [onConfirm])

    return (
        <>
            {triggerVariant ? (
                <Button
                    ref={triggerRef}
                    type="button"
                    variant={triggerVariant}
                    size={triggerSize}
                    disabled={disabled}
                    className={className}
                    aria-haspopup="dialog"
                    onClick={() => setOpen(true)}
                >
                    {children}
                </Button>
            ) : (
                <button
                    ref={triggerRef}
                    type="button"
                    disabled={disabled}
                    className={className}
                    aria-haspopup="dialog"
                    onClick={() => setOpen(true)}
                >
                    {children}
                </button>
            )}
            {open && (
                <ConfirmDialog
                    content={content as ConfirmContent}
                    onAccept={accept}
                    onDismiss={close}
                />
            )}
        </>
    )
}

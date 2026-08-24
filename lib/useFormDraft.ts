'use client'

// lib/useFormDraft.ts
// 表单草稿留存。**它与空闲超时是同一件事的两半** —— 先上超时、不上草稿留存,
// 等于亲手制造一种今天不存在的工作损失(SESSION-1c 记的那条)。
//
// ════════════════════════════════════════════════════════════════════════════
// 【两种存放地,而分界【不是】一张手写清单】(IDLE-DRAFT,2026-08-24)
//
//   · 不带受限数据的表单 → **localStorage**。草稿活过空闲超时、活过关掉浏览器,
//     72 小时后过期。这是"救回工作"那一半。
//   · 带受限数据的表单   → **sessionStorage**,并且登录页一进去就清掉。
//     也就是说它【不活过一次登出】,包括空闲超时那一次。这是"共用平板"那一半:
//     一份写着薪资与身份证号的草稿,不可以在车间的平板上等着下一个人。
//
// 【分界从哪来:数据库自己的说法,不是第二张清单】
// `MASKED_TABLES` 由 scripts/gen-masked-tables.mjs 从 lib/database.types.ts 生成 ——
// 一张表有 `<表>_masked` 伴生视图,意思就是它有列被从 authenticated 手里收回。
// 那正是"受限"的定义,而且线上加一张遮蔽表时它会自己跟上
// (check-masked-reads.mjs 校验同步,不同步就构建失败)。
// **手写一张"哪些表单算受限"的清单,是把系统已经陈述过的规矩再陈述一遍。**
// ════════════════════════════════════════════════════════════════════════════
import { useCallback, useEffect, useRef, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { DRAFT_MAX_AGE_MS } from '@/lib/session'
import { MASKED_TABLES } from '@/lib/maskedTables'

const PREFIX = 'evoltrya:draft:v1'

export type DraftPayload = {
    /** 存下来的时刻 */
    at: number
    /** 表单字段 */
    values: Record<string, string>
    /**
     * 【主语的指纹】编辑既有记录时,存下它当时的 updated_at。
     * 恢复之前比一次:对不上就【不恢复】—— 见 staleness 那一段。
     * 新建表单没有主语,这里是 null。
     */
    subject: string | null
}

export type DraftState = {
    /** 发现了一份草稿(还没有被套用 —— 套用必须由人点一下) */
    found: DraftPayload | null
    /** 这份草稿的主语已经变了 / 不见了,所以【不能】套用 */
    stale: boolean
    /** 这张表单是不是受限表单(草稿不活过登出) */
    restricted: boolean
    /** 已经套用过一份草稿(界面上要一直显示,直到提交) */
    restored: boolean
    restore: () => void
    discard: () => void
}

function storageFor(restricted: boolean): Storage | null {
    if (typeof window === 'undefined') return null
    try {
        return restricted ? window.sessionStorage : window.localStorage
    } catch {
        return null   // 隐私模式等
    }
}

/** 登录页调用:清掉【受限】草稿。见抬头 —— 这是"不活过一次登出"的落实点。 */
export function clearRestrictedDrafts() {
    try {
        const ss = window.sessionStorage
        for (const k of Object.keys(ss)) if (k.startsWith(PREFIX)) ss.removeItem(k)
    } catch { /* 没有 sessionStorage 就没有要清的 */ }
}

export function useFormDraft(opts: {
    /**
     * 稳定的表单标识,例如 `'suppliers/new'`。
     *
     * 【用斜杠,不要用点】check-i18n 会把【点分的字符串字面量】当成翻译键去查,
     * 一个点分的表单标识会被它报成"缺于 en 与 zh"。**实测撞到过两次:第一次是
     * 真的标识,第二次是这段注释里举的那个例子** —— 一个按文本找调用的检查器
     * 分不出代码与注释(PROC-CLEANUP 与 middleware 抬头各为同一件事记过一笔)。
     * 所以这里【不举那个例子】,而不是给检查器加一条例外。
     * 这不是检查器的毛病 —— 它按形状认键,而那正是它抓得住动态键的原因
     * (那三次线上事故都出在动态拼出来的键上)。所以让这个标识【长得不像键】,
     * 而不是给检查器加一条例外。斜杠还顺带让它读起来就是那条路由。
     */
    formKey: string
    /** 这张表单写哪张表 —— 受限与否由它推出来,不由调用方声明 */
    table: string
    /** 编辑既有记录时传它的 updated_at;新建表单传 null */
    subject: string | null
    /** 表单元素 */
    formRef: React.RefObject<HTMLFormElement | null>
}): DraftState {
    const { formKey, table, subject, formRef } = opts
    const restricted = MASKED_TABLES.has(table)

    // 【草稿按人隔离,而 user id 在这里自己取】(IDLE-DRAFT A4)
    // **绝不把 A 打的字递给 B。** 这不只是隐私:B 一保存,A 的工作就被记在
    // B 的名下 —— 那是一个出处问题,而本仓库对出处的规矩比对隐私的更硬。
    // 【取不到就不留草稿】getUser() 可能失败,而"问不到答案"不等于"没有人"
    // (lib/supabase/middleware.ts 抬头那一条)。问不到时我们什么都不存 ——
    // 这一层宁可少救一次工作,也不肯把它存到一个不知道是谁的键上。
    const [userId, setUserId] = useState<string | null>(null)
    useEffect(() => {
        let alive = true
        void (async () => {
            try {
                const { data, error } = await createClient().auth.getUser()
                // 【error 必须接住】三类的区别见 lib/supabase/middleware.ts 抬头。
                // 这一层【三类都不存草稿】,而理由各不相同:
                //   · 判断不出(AuthRetryableFetchError)→ 不知道是谁,不能落键;
                //   · 确立的否定 → 本来就没有人,没有草稿可言;
                //   · 有 user → 正常路径,落键。
                // 少救一次工作,好过把它存到一个不知道属于谁的键上(A4 的出处理由)。
                if (alive && !error) setUserId(data.user?.id ?? null)
            } catch {
                /* 同上:问不到答案就不存草稿 */
            }
        })()
        return () => { alive = false }
    }, [])

    const key = userId ? `${PREFIX}:${userId}:${formKey}` : null
    const [found, setFound] = useState<DraftPayload | null>(null)
    const [stale, setStale] = useState(false)
    const [restored, setRestored] = useState(false)
    const writeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

    // 开局:看看有没有草稿。**不套用** —— 套用是人的一次点击(见 4.2)。
    useEffect(() => {
        if (!key) return
        const store = storageFor(restricted)
        if (!store) return
        const raw = store.getItem(key)
        if (!raw) return
        let d: DraftPayload
        try { d = JSON.parse(raw) } catch { store.removeItem(key); return }
        // 【过期就当没有】72 小时,理由见 lib/session.ts
        if (!d.at || Date.now() - d.at > DRAFT_MAX_AGE_MS) { store.removeItem(key); return }
        // 【主语变了就不给套用】—— 见下面那段
        setStale(d.subject !== subject)
        setFound(d)
    }, [key, restricted, subject])

    // 存:输入之后延迟写,别每一次按键都序列化一遍
    useEffect(() => {
        if (!key) return
        const form = formRef.current
        if (!form) return
        const onInput = () => {
            if (writeTimer.current) clearTimeout(writeTimer.current)
            writeTimer.current = setTimeout(() => {
                const store = storageFor(restricted)
                if (!store) return
                const values: Record<string, string> = {}
                for (const [k, v] of new FormData(form).entries()) {
                    if (typeof v === 'string') values[k] = v      // 文件不进草稿
                }
                const payload: DraftPayload = { at: Date.now(), values, subject }
                try { store.setItem(key, JSON.stringify(payload)) } catch { /* 配额满 */ }
            }, 800)
        }
        form.addEventListener('input', onInput)
        form.addEventListener('change', onInput)
        return () => {
            form.removeEventListener('input', onInput)
            form.removeEventListener('change', onInput)
            if (writeTimer.current) clearTimeout(writeTimer.current)
        }
    }, [key, restricted, subject, formRef])

    const discard = useCallback(() => {
        if (key) storageFor(restricted)?.removeItem(key)
        setFound(null); setStale(false); setRestored(false)
    }, [key, restricted])

    const restore = useCallback(() => {
        const form = formRef.current
        if (!form || !found || stale) return
        for (const [name, value] of Object.entries(found.values)) {
            const el = form.elements.namedItem(name)
            if (!el) continue
            if (el instanceof HTMLInputElement) {
                if (el.type === 'checkbox' || el.type === 'radio') el.checked = el.value === value
                else el.value = value
            } else if (el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) {
                el.value = value
            }
        }
        setFound(null)
        setRestored(true)     // ← 界面上一直显示"这是恢复出来的",直到提交
    }, [found, stale, formRef])

    return { found, stale, restricted, restored, restore, discard }
}

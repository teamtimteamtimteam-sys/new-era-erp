'use client'

// app/components/ui/date-picker.tsx
// ════════════════════════════════════════════════════════════════════════════
// DATE-PICK-1(2026-10-05;AUDIT-TRAIL-0 Q35–Q39)· 全站【唯一】的日期框
// ════════════════════════════════════════════════════════════════════════════
// 【为什么不再用原生控件】原生日期框按【操作系统的 locale】画它的字(CSS 够不到、JS 改不了),
//   于是同一个日期在屏幕上是 01/09/2026、在框里是 9/1/2026 —— Tim 最初抱怨的「同一个日期读出三种样子」,
//   DATE-1 只治好了显示那一半。这一个组件换掉全部原生的 date / month / datetime-local。
//
// 【它做什么】(Q35 · Q36 · Q37 · Q39)
//   · 框里永远是 DD/MM/YYYY(月份 MM/YYYY,日期时间再加一个 HH:MM),两种界面都一样;
//   · 能敲:5/10/2026 · 05/10/26(= 2026)· 05102026 · 粘贴进来的 2026-10-05 —— 解析在 lib/dates.ts;
//   · 能点:Radix Popover 里的月历,周一开头;中文界面的月名与星期名是中文;
//   · 键盘:方向键挪一天 / 一周,PageUp / PageDown 换月(按住 Shift 换年),Home / End 到周首周尾,Enter 选中,Esc 关上;
//   · 表单收到的是 ISO:`<input type="hidden" name=… value="2026-10-05">` —— 服务端动作收到的与原生控件一字不差;
//     日期时间是 `2026-10-05T14:30+08:00`:新加坡时间,带偏移(Q36:不再交给浏览器的时区)。
//
// 【拦住的东西】(Q37 —— 这一段是本组件存在的理由之一)
//   · 敲了一个【不存在】的日子(31/02/2026)或一个【范围外】的日子:框下面说出原因,而且
//     ① 它【永远不会】被交出去 —— onChange 只收到合法的 ISO 或空串;
//     ② 原生表单的提交被拦住(setCustomValidity —— 浏览器在 submit 事件之前就停下);
//     ③ 不走原生表单、靠按钮 onClick 提交的面板,用 `onInvalidChange` 把按钮关掉(每一处调用点自己接)。
//   · min / max 之外的日子在月历里是灰的、点不了,原因写在月历底下(Q37)。
//   ★ 从前那道 onBlur 回写(AGENTS.md「Dates and amounts that decide a period」:受控的原生框可以看起来填好了、
//     而状态是空的)在这里【按构造】不存在:交出去的值只来自 React 的状态,框里的字与它对不上时提交被拦。
//
// 【尺寸】宽度固定(由组件定,不由内容定 —— INPUT-2b 那条:一个内在尺寸由内容决定的控件坐在不换行的容器里就是危险形状),
//   高 32px(R3);390px 上日期时间那一种也只有约 15rem。
// ════════════════════════════════════════════════════════════════════════════
import * as React from 'react'
import { Popover } from 'radix-ui'
import { useTranslations } from '@/lib/i18n/client'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { DOW_KEYS } from '@/app/components/calendar/MonthGrid'
import { businessToday } from '@/lib/format'
import { cn } from '@/lib/utils'
import {
    DATE_PICKER_RESTORE, addDaysIso, addMonthsIso, businessDateTimeIso, daysInMonthOf, formatTypedDate, formatTypedMonth, mondayIndex,
    parseTypedDate, parseTypedMonth, parseTypedTime, toBusinessDateTime, toYearMonth, toYmd,
} from '@/lib/dates'

/** 月名的键 —— 【也是 check-i18n 的真源】(`datePicker.month.` 那一族)。 */
export const MONTH_KEYS = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12'] as const

export type DatePickerKind = 'date' | 'month' | 'datetime'

export type DatePickerProps = {
    /** date(默认)· month(MM/YYYY,交出 YYYY-MM)· datetime(DD/MM/YYYY + HH:MM,新加坡时间,交出带偏移的 ISO) */
    kind?: DatePickerKind
    /** 有它就渲染一个同名的隐藏输入,表单提交的是 ISO */
    name?: string
    /** 受控:ISO(`YYYY-MM-DD` / `YYYY-MM` / 时间戳)或空串 */
    value?: string
    /** 非受控的初值,ISO 或空串 */
    defaultValue?: string
    /** 只收到合法的 ISO,或者空串(框被清空)—— 永远不会收到一个敲错的值 */
    onChange?: (iso: string) => void
    /** 框里的字是不是一个拦得住提交的错(不存在的日子 / 范围外 / 格式不对)。按钮 onClick 提交的面板用它关按钮。 */
    onInvalidChange?: (invalid: boolean) => void
    /** ISO;月历里早于它的日子点不了,敲进来也拦 */
    min?: string
    /** ISO;月历里晚于它的日子点不了,敲进来也拦 */
    max?: string
    required?: boolean
    disabled?: boolean
    id?: string
    'aria-label'?: string
    /** 调用点自己的"这一格有问题"(例如必填却空着)—— 与组件自己的判断取或 */
    'aria-invalid'?: boolean
    title?: string
    /** 只读:框里的字照常显示、表单照常提交,月历打不开 */
    readOnly?: boolean
    /** 外层的类(外边距、换行之类);宽度由组件自己定 */
    className?: string
    /** 隐藏输入的 form= 属性 */
    form?: string
}

type Eval =
    | { state: 'empty' }
    | { state: 'valid'; iso: string }
    | { state: 'invalid'; message: string }

const WIDTH: Record<DatePickerKind, string> = { date: 'w-[9.75rem]', month: 'w-[7.75rem]', datetime: 'w-[9.75rem]' }

function normalize(kind: DatePickerKind, v: string | undefined | null): string {
    if (!v) return ''
    if (kind === 'month') return toYearMonth(v)
    if (kind === 'date') return toYmd(v)
    const bt = toBusinessDateTime(v)
    return bt ? businessDateTimeIso(bt.date, bt.time) : ''
}

/** 框里该显示的字(datetime 时是日期那一半) */
function dateText(kind: DatePickerKind, iso: string): string {
    if (!iso) return ''
    return kind === 'month' ? formatTypedMonth(iso) : formatTypedDate(iso)
}
function timeText(iso: string): string {
    const m = /T(\d{2}:\d{2})/.exec(iso)
    return m ? m[1] : ''
}
/** 敲完了吗 —— 四位年、八位数字、ISO。只有敲完了才在【敲的时候】就交出去;两位年等到离开框或按 Enter。 */
function looksComplete(kind: DatePickerKind, s: string): boolean {
    const t = s.trim()
    if (kind === 'month') return /^\d{1,2}[/.-]\d{4}$/.test(t) || /^\d{6}$/.test(t) || /^\d{4}-\d{1,2}$/.test(t)
    return /^\d{1,2}[/.-]\d{1,2}[/.-]\d{4}$/.test(t) || /^\d{8}$/.test(t) || /^\d{4}-\d{1,2}-\d{1,2}/.test(t)
}

function CalendarIcon() {
    return (
        <svg aria-hidden="true" viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="1.4">
            <rect x="2" y="3" width="12" height="11" rx="1.5" />
            <path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3" strokeLinecap="round" />
        </svg>
    )
}

export function DatePicker({
    kind = 'date', name, value, defaultValue, onChange, onInvalidChange, min, max,
    required, disabled, id, 'aria-label': ariaLabel, 'aria-invalid': ariaInvalid, title, readOnly, className, form,
}: DatePickerProps) {
    const t = useTranslations()
    const controlled = value !== undefined
    const [inner, setInner] = React.useState(() => normalize(kind, defaultValue))
    const iso = controlled ? normalize(kind, value) : inner

    const [text, setText] = React.useState(() => dateText(kind, iso))
    const [time, setTime] = React.useState(() => timeText(iso))
    const [touched, setTouched] = React.useState(false)
    const [open, setOpen] = React.useState(false)
    const lastIso = React.useRef(iso)
    const textRef = React.useRef<HTMLInputElement>(null)
    const timeRef = React.useRef<HTMLInputElement>(null)
    const hiddenRef = React.useRef<HTMLInputElement>(null)
    const wrapRef = React.useRef<HTMLDivElement>(null)
    const contentRef = React.useRef<HTMLDivElement>(null)
    const refocusText = React.useRef(false)
    const msgId = React.useId()

    // 外面换了值(重置表单、选了另一张单)→ 框里的字跟着换。我们自己交出去的值不算"外面换了"。
    // ★ 判据是【传进来的值变了】,不是"传进来的值与我们最后交出去的不同":受控的筛选条要等 router.push 跑完
    //   才把新值传回来,那段时间里两者不同是正常的 —— 照后一种判据,框里会先闪回旧日期。
    const propIso = React.useRef(iso)
    React.useEffect(() => {
        if (iso === propIso.current) return
        propIso.current = iso
        if (iso === lastIso.current) return
        lastIso.current = iso
        setText(dateText(kind, iso))
        setTime(timeText(iso))
        setTouched(false)
    }, [iso, kind])

    const today = businessToday()
    const lo = min ? normalize(kind === 'month' ? 'month' : 'date', min) : ''
    const hi = max ? normalize(kind === 'month' ? 'month' : 'date', max) : ''
    const shown = (x: string) => (kind === 'month' ? formatTypedMonth(x) : formatTypedDate(x))

    function rangeMessage(day: string): string | null {
        if (lo && day < lo) return t('datePicker.errBeforeMin', { date: shown(day), min: shown(lo) })
        if (hi && day > hi) {
            return kind !== 'month' && hi === today
                ? t('datePicker.errFuture', { date: shown(day), today: shown(today) })
                : t('datePicker.errAfterMax', { date: shown(day), max: shown(hi) })
        }
        return null
    }

    function evaluate(d: string, tm: string): Eval {
        if (kind === 'month') {
            const p = parseTypedMonth(d)
            if (!p) return { state: 'empty' }
            if (!p.ok) return { state: 'invalid', message: p.reason === 'format'
                ? t('datePicker.errMonthFormat') : t('datePicker.errMonthImpossible', { text: d.trim() }) }
            const r = rangeMessage(p.value)
            return r ? { state: 'invalid', message: r } : { state: 'valid', iso: p.value }
        }
        const p = parseTypedDate(d)
        const q = kind === 'datetime' ? parseTypedTime(tm) : null
        if (!p && !q) return { state: 'empty' }
        if (p && !p.ok) return { state: 'invalid', message: p.reason === 'format'
            ? t('datePicker.errFormat') : t('datePicker.errImpossible', { text: d.trim() }) }
        if (!p) return { state: 'invalid', message: t('datePicker.errNeedDate') }
        const r = rangeMessage(p.value)
        if (r) return { state: 'invalid', message: r }
        if (kind !== 'datetime') return { state: 'valid', iso: p.value }
        if (!q) return { state: 'invalid', message: t('datePicker.errNeedTime') }
        if (!q.ok) return { state: 'invalid', message: q.reason === 'format'
            ? t('datePicker.errTimeFormat') : t('datePicker.errTimeImpossible', { text: tm.trim() }) }
        return { state: 'valid', iso: businessDateTimeIso(p.value, q.value) }
    }

    const ev = evaluate(text, time)
    const invalid = ev.state === 'invalid'

    // 原生表单的提交:浏览器在 submit 事件之前就按这一句停下(Q37)
    React.useEffect(() => {
        textRef.current?.setCustomValidity(ev.state === 'invalid' ? ev.message : '')
    })
    const reported = React.useRef<boolean | null>(null)
    React.useEffect(() => {
        if (reported.current === invalid) return
        reported.current = invalid
        onInvalidChange?.(invalid)
    }, [invalid, onInvalidChange])

    function commit(next: string) {
        if (next === lastIso.current) return
        lastIso.current = next
        // 隐藏输入当场改掉:同一次按键里接着发生的隐式提交,读到的必须是这一个值
        if (hiddenRef.current) {
            hiddenRef.current.value = next
            // 月历画在表单【外面】(Portal),在那里点中的日子不会冒出表单的 input 事件 ——
            // 而草稿(lib/useFormDraft.ts)正是听那个事件存的。替它冒一个。
            hiddenRef.current.dispatchEvent(new Event('input', { bubbles: true }))
        }
        if (!controlled) setInner(next)
        onChange?.(next)
    }

    // 草稿恢复:有人直接改了隐藏输入的 value(lib/useFormDraft.ts 的 restore)→ 框里的字跟上,值照常交出去
    const onRestore = React.useEffectEvent(() => {
        const v = normalize(kind, hiddenRef.current?.value ?? '')
        setText(dateText(kind, v))
        setTime(timeText(v))
        setTouched(false)
        lastIso.current = '\u0000'          // 让 commit 不把它当成"没变"
        commit(v)
    })
    React.useEffect(() => {
        const el = hiddenRef.current
        if (!el) return
        const h = () => onRestore()
        el.addEventListener(DATE_PICKER_RESTORE, h)
        return () => el.removeEventListener(DATE_PICKER_RESTORE, h)
    }, [])

    // form.reset():原生日期框会回到它的初值,这一个也一样(非受控的才回;受控的值归调用方管)
    const onReset = React.useEffectEvent(() => {
        if (controlled) return
        const v = normalize(kind, defaultValue)
        lastIso.current = v
        setInner(v)
        setText(dateText(kind, v))
        setTime(timeText(v))
        setTouched(false)
    })
    React.useEffect(() => {
        const f = textRef.current?.form
        if (!f) return
        const h = () => onReset()
        f.addEventListener('reset', h)
        return () => f.removeEventListener('reset', h)
    }, [])

    /** 离开整个日期框(连同月历)或按 Enter:收尾 —— 合法就交出去并把字写规整,错就说出来、什么都不交 */
    function finish(): Eval {
        // 读【屏幕上的】字,不读闭包里的状态 —— 收尾可能发生在一次还没渲染完的改动之后
        const e = evaluate(textRef.current?.value ?? text, timeRef.current?.value ?? time)
        setTouched(true)
        if (e.state === 'valid') {
            commit(e.iso)
            setText(dateText(kind, e.iso))
            if (kind === 'datetime') setTime(timeText(e.iso))
        } else if (e.state === 'empty') {
            commit('')
        }
        return e
    }

    function onTextChange(v: string) {
        setText(v)
        const e = evaluate(v, time)
        if (e.state === 'valid' && looksComplete(kind, v) && (kind !== 'datetime' || parseTypedTime(time)?.ok)) commit(e.iso)
    }
    function onTimeChange(v: string) {
        setTime(v)
        const e = evaluate(text, v)
        if (e.state === 'valid' && /^\d{1,2}[:.]\d{2}$/.test(v.trim()) && looksComplete(kind, text)) commit(e.iso)
    }

    function leaving(e: React.FocusEvent) {
        const to = e.relatedTarget as Node | null
        if (to && (wrapRef.current?.contains(to) || contentRef.current?.contains(to))) return
        finish()
    }

    function onKey(e: React.KeyboardEvent<HTMLInputElement>) {
        if (e.key === 'Enter') {
            const r = finish()
            if (r.state === 'invalid') e.preventDefault()
        } else if (e.key === 'ArrowDown' && e.altKey) {
            e.preventDefault()
            setOpen(true)
        }
    }

    function pick(day: string) {
        // 月历里点中的:日期时间那一种保留已经敲好的时刻
        let next = day
        if (kind === 'datetime') {
            const q = parseTypedTime(time)
            next = q && q.ok ? businessDateTimeIso(day, q.value) : ''
            setText(formatTypedDate(day))
            if (!next) { setOpen(false); requestAnimationFrame(() => timeRef.current?.focus()); return }
        } else {
            setText(dateText(kind, day))
        }
        setTouched(true)
        commit(next)
        refocusText.current = true
        setOpen(false)
    }

    function clear() {
        setText('')
        setTime('')
        commit('')
        refocusText.current = true
        setOpen(false)
    }

    // 离开过框之后才说错 —— 但一个【已经敲完】的错(31/02/2026、将来的日子)当场就说:
    // 按钮提交的面板这时已经把钮关了,不说出原因,人只看见一颗灰掉的钮。
    const showMsg = invalid && (touched || (looksComplete(kind, text) && (kind !== 'datetime' || !!time.trim())))
    const box = cn(CONTROL_INPUT, 'pr-8 tabular-nums', invalid && touched && 'border-destructive')

    return (
        <div ref={wrapRef} className={cn('inline-flex flex-col align-middle', className)} onBlur={leaving} data-date-picker={kind} data-date-value={iso}>
            <Popover.Root open={open} onOpenChange={setOpen}>
                <div className="inline-flex items-center gap-1.5">
                    <Popover.Anchor asChild>
                        <div className={cn('relative shrink-0', WIDTH[kind])}>
                            <input
                                ref={textRef}
                                id={id}
                                type="text"
                                inputMode="numeric"
                                autoComplete="off"
                                spellCheck={false}
                                placeholder={kind === 'month' ? 'MM/YYYY' : 'DD/MM/YYYY'}
                                value={text}
                                onChange={(e) => onTextChange(e.target.value)}
                                onKeyDown={onKey}
                                onInvalid={() => setTouched(true)}
                                required={required}
                                disabled={disabled}
                                readOnly={readOnly}
                                title={title}
                                aria-label={ariaLabel}
                                aria-invalid={showMsg || ariaInvalid || undefined}
                                aria-describedby={showMsg ? msgId : undefined}
                                className={cn(box, 'w-full')}
                                data-date-text=""
                            />
                            <Popover.Trigger asChild>
                                <button
                                    type="button"
                                    disabled={disabled || readOnly}
                                    aria-label={t('datePicker.openCalendar')}
                                    title={t('datePicker.openCalendar')}
                                    className="absolute inset-y-0 right-0 inline-flex w-8 items-center justify-center rounded-r-lg text-[color:var(--brand-muted-text)] hover:text-[color:var(--brand-text)] disabled:opacity-50"
                                    data-date-open=""
                                >
                                    <CalendarIcon />
                                </button>
                            </Popover.Trigger>
                        </div>
                    </Popover.Anchor>
                    {kind === 'datetime' && (
                        <input
                            ref={timeRef}
                            type="text"
                            inputMode="numeric"
                            autoComplete="off"
                            spellCheck={false}
                            placeholder="HH:MM"
                            value={time}
                            onChange={(e) => onTimeChange(e.target.value)}
                            onKeyDown={onKey}
                            disabled={disabled}
                            readOnly={readOnly}
                            aria-label={t('datePicker.time')}
                            title={t('datePicker.time')}
                            aria-invalid={showMsg || undefined}
                            className={cn(CONTROL_INPUT, 'w-[4.75rem] shrink-0 tabular-nums', invalid && touched && 'border-destructive')}
                            data-date-time=""
                        />
                    )}
                </div>
                <Popover.Portal>
                    <Popover.Content
                        ref={contentRef}
                        align="start"
                        sideOffset={4}
                        collisionPadding={8}
                        onOpenAutoFocus={(e) => e.preventDefault()}
                        onCloseAutoFocus={(e) => {
                            e.preventDefault()
                            if (refocusText.current) textRef.current?.focus()
                            refocusText.current = false
                        }}
                        onEscapeKeyDown={(e) => {
                            // Esc 只关月历:不让它再传到外面那一层(弹窗、抽屉听 window 上的 Esc,会把整张表单一起关掉)
                            e.stopPropagation()
                            refocusText.current = true
                        }}
                        className="z-50 rounded-lg border bg-[color:var(--brand-surface)] p-2 shadow-md"
                        style={{ borderColor: 'var(--brand-border)' }}
                        data-date-popover={kind}
                    >
                        {kind === 'month'
                            ? <MonthPanel selected={iso} lo={lo} hi={hi} onPick={pick} t={t} />
                            : <DayPanel selected={kind === 'datetime' ? iso.slice(0, 10) : iso} today={today} lo={lo} hi={hi} onPick={pick} t={t} />}
                        <Footer kind={kind} lo={lo} hi={hi} today={today} required={!!required} onPick={pick} onClear={clear} t={t} />
                    </Popover.Content>
                </Popover.Portal>
            </Popover.Root>
            {name && <input ref={hiddenRef} type="hidden" name={name} value={iso} form={form} disabled={disabled} data-date-picker-value="" />}
            {showMsg && (
                <p id={msgId} role="alert" className="mt-1 max-w-[16rem] text-xs text-destructive" data-date-error="">
                    {ev.message}
                </p>
            )}
        </div>
    )
}

type T = ReturnType<typeof useTranslations>

/** 月历底下那一行:为什么有些日子点不了(Q37),以及「今天」「清空」 */
function Footer({ kind, lo, hi, today, required, onPick, onClear, t }: {
    kind: DatePickerKind; lo: string; hi: string; today: string; required: boolean
    onPick: (iso: string) => void; onClear: () => void; t: T
}) {
    const shown = (x: string) => (kind === 'month' ? formatTypedMonth(x) : formatTypedDate(x))
    const now = kind === 'month' ? today.slice(0, 7) : today
    const nowOk = (!lo || now >= lo) && (!hi || now <= hi)
    const reasons: string[] = []
    if (lo) reasons.push(t('datePicker.reasonBeforeMin', { min: shown(lo) }))
    if (hi) reasons.push(kind !== 'month' && hi === today
        ? t('datePicker.reasonFuture', { today: shown(today) })
        : t('datePicker.reasonAfterMax', { max: shown(hi) }))
    return (
        <div className="mt-2 border-t pt-2" style={{ borderColor: 'var(--brand-border)' }}>
            {reasons.map((r) => (
                <p key={r} className="mb-1 max-w-[15.5rem] text-xs text-[color:var(--brand-muted-text)]" data-date-reason="">{r}</p>
            ))}
            <div className="flex items-center justify-between gap-2">
                <button type="button" disabled={!nowOk} onClick={() => onPick(now)}
                        className="rounded px-2 py-1 text-xs font-medium text-primary hover:bg-[color:var(--brand-muted)] disabled:opacity-40">
                    {kind === 'month' ? t('datePicker.thisMonth') : t('datePicker.today')}
                </button>
                {!required && (
                    <button type="button" onClick={onClear}
                            className="rounded px-2 py-1 text-xs text-[color:var(--brand-muted-text)] hover:bg-[color:var(--brand-muted)]">
                        {t('datePicker.clear')}
                    </button>
                )}
            </div>
        </div>
    )
}

const NAV = 'inline-flex h-8 w-8 items-center justify-center rounded hover:bg-[color:var(--brand-muted)] text-[color:var(--brand-text)]'

function monthTitle(t: T, ym: string): string {
    const [y, m] = ym.split('-')
    return t('datePicker.monthYear', { month: t('datePicker.month.' + String(Number(m))), year: y })
}

/** 日子那一页:周一开头的 7 列,方向键 / PageUp / PageDown / Home / End / Enter(Q35) */
function DayPanel({ selected, today, lo, hi, onPick, t }: {
    selected: string; today: string; lo: string; hi: string; onPick: (iso: string) => void; t: T
}) {
    const start = selected || (hi && today > hi ? hi : lo && today < lo ? lo : today)
    const [focus, setFocus] = React.useState(start)
    const gridRef = React.useRef<HTMLDivElement>(null)
    const ym = focus.slice(0, 7)
    const [y, m] = ym.split('-').map(Number)
    const total = daysInMonthOf(y, m)
    const lead = mondayIndex(`${ym}-01`)
    const heads = [...DOW_KEYS.slice(1), DOW_KEYS[0]].map((d) => t('calendar.dow.' + d))
    const out = (d: string) => (lo && d < lo) || (hi && d > hi)
    const reasonFor = (d: string) => lo && d < lo
        ? t('datePicker.reasonBeforeMin', { min: formatTypedDate(lo) })
        : hi === today ? t('datePicker.reasonFuture', { today: formatTypedDate(today) }) : t('datePicker.reasonAfterMax', { max: formatTypedDate(hi) })

    // 打开时与换月之后,焦点落在【那一天】上(roving tabindex)
    React.useEffect(() => {
        gridRef.current?.querySelector<HTMLButtonElement>(`[data-day="${focus}"]`)?.focus()
    }, [focus])

    function onKey(e: React.KeyboardEvent) {
        const move: Record<string, () => string> = {
            ArrowLeft: () => addDaysIso(focus, -1),
            ArrowRight: () => addDaysIso(focus, 1),
            ArrowUp: () => addDaysIso(focus, -7),
            ArrowDown: () => addDaysIso(focus, 7),
            PageUp: () => addMonthsIso(focus, e.shiftKey ? -12 : -1),
            PageDown: () => addMonthsIso(focus, e.shiftKey ? 12 : 1),
            Home: () => addDaysIso(focus, -mondayIndex(focus)),
            End: () => addDaysIso(focus, 6 - mondayIndex(focus)),
        }
        if (move[e.key]) { e.preventDefault(); setFocus(move[e.key]()); return }
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            if (!out(focus)) onPick(focus)
        }
    }

    const cells: (string | null)[] = [...Array.from({ length: lead }, () => null),
        ...Array.from({ length: total }, (_, i) => `${ym}-${String(i + 1).padStart(2, '0')}`)]
    while (cells.length % 7) cells.push(null)

    return (
        <div className="w-[15.5rem]">
            <div className="mb-1 flex items-center justify-between">
                <button type="button" className={NAV} aria-label={t('datePicker.prevMonth')} title={t('datePicker.prevMonth')}
                        onClick={() => setFocus(addMonthsIso(focus, -1))}>‹</button>
                <span className="text-sm font-semibold text-[color:var(--brand-text)]" aria-live="polite" data-date-title="">{monthTitle(t, ym)}</span>
                <button type="button" className={NAV} aria-label={t('datePicker.nextMonth')} title={t('datePicker.nextMonth')}
                        onClick={() => setFocus(addMonthsIso(focus, 1))}>›</button>
            </div>
            <div ref={gridRef} role="grid" aria-label={monthTitle(t, ym)} onKeyDown={onKey}>
                <div role="row" className="grid grid-cols-7 gap-0.5">
                    {heads.map((h) => (
                        <div key={h} role="columnheader" className="py-1 text-center text-xs font-semibold text-[color:var(--brand-text)]" data-date-dow="">{h}</div>
                    ))}
                </div>
                {Array.from({ length: cells.length / 7 }, (_, w) => (
                    <div key={w} role="row" className="mt-0.5 grid grid-cols-7 gap-0.5">
                        {cells.slice(w * 7, w * 7 + 7).map((d, i) => d === null ? <div key={`b${i}`} role="gridcell" /> : (
                            <div key={d} role="gridcell" aria-selected={d === selected}>
                                <button
                                    type="button"
                                    tabIndex={d === focus ? 0 : -1}
                                    data-day={d}
                                    aria-disabled={out(d) || undefined}
                                    aria-label={formatTypedDate(d)}
                                    title={out(d) ? reasonFor(d) : undefined}
                                    onClick={() => { if (!out(d)) onPick(d); else setFocus(d) }}
                                    className={cn(
                                        'h-8 w-full rounded text-sm tabular-nums',
                                        d === selected ? 'bg-primary text-primary-foreground font-semibold'
                                            : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-muted)]',
                                        d === today && d !== selected && 'ring-1 ring-inset ring-primary',
                                        out(d) && 'cursor-not-allowed text-[color:var(--brand-muted-text)] line-through opacity-50 hover:bg-transparent',
                                    )}
                                >
                                    {Number(d.slice(8))}
                                </button>
                            </div>
                        ))}
                    </div>
                ))}
            </div>
        </div>
    )
}

/** 月份那一页:一年 12 格,三列;方向键挪一月 / 一季,PageUp / PageDown 换年 */
function MonthPanel({ selected, lo, hi, onPick, t }: {
    selected: string; lo: string; hi: string; onPick: (ym: string) => void; t: T
}) {
    const now = businessToday().slice(0, 7)
    const [focus, setFocus] = React.useState(selected || (hi && now > hi ? hi : lo && now < lo ? lo : now))
    const gridRef = React.useRef<HTMLDivElement>(null)
    const year = focus.slice(0, 4)
    const shift = (ym: string, n: number) => addMonthsIso(`${ym}-01`, n).slice(0, 7)
    const out = (x: string) => (lo && x < lo) || (hi && x > hi)

    React.useEffect(() => {
        gridRef.current?.querySelector<HTMLButtonElement>(`[data-month="${focus}"]`)?.focus()
    }, [focus])

    function onKey(e: React.KeyboardEvent) {
        const move: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -3, ArrowDown: 3, PageUp: -12, PageDown: 12 }
        if (move[e.key] !== undefined) { e.preventDefault(); setFocus(shift(focus, move[e.key])); return }
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); if (!out(focus)) onPick(focus) }
    }

    return (
        <div className="w-[15.5rem]">
            <div className="mb-1 flex items-center justify-between">
                <button type="button" className={NAV} aria-label={t('datePicker.prevYear')} title={t('datePicker.prevYear')}
                        onClick={() => setFocus(shift(focus, -12))}>‹</button>
                <span className="text-sm font-semibold text-[color:var(--brand-text)]" aria-live="polite" data-date-title="">{year}</span>
                <button type="button" className={NAV} aria-label={t('datePicker.nextYear')} title={t('datePicker.nextYear')}
                        onClick={() => setFocus(shift(focus, 12))}>›</button>
            </div>
            <div ref={gridRef} role="grid" aria-label={year} onKeyDown={onKey}>
                {[0, 1, 2, 3].map((r) => (
                    <div key={r} role="row" className="mb-1 grid grid-cols-3 gap-1">
                        {MONTH_KEYS.slice(r * 3, r * 3 + 3).map((k) => {
                            const ym = `${year}-${k.padStart(2, '0')}`
                            return (
                                <div key={k} role="gridcell" aria-selected={ym === selected}>
                                    <button type="button" tabIndex={ym === focus ? 0 : -1} data-month={ym}
                                            aria-disabled={out(ym) || undefined}
                                            onClick={() => { if (!out(ym)) onPick(ym); else setFocus(ym) }}
                                            className={cn('h-8 w-full rounded text-sm',
                                                ym === selected ? 'bg-primary text-primary-foreground font-semibold'
                                                    : 'text-[color:var(--brand-text)] hover:bg-[color:var(--brand-muted)]',
                                                out(ym) && 'cursor-not-allowed opacity-50 line-through hover:bg-transparent')}>
                                        {t('datePicker.month.' + k)}
                                    </button>
                                </div>
                            )
                        })}
                    </div>
                ))}
            </div>
        </div>
    )
}

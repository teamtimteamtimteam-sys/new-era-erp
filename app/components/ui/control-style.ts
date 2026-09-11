// ════════════════════════════════════════════════════════════════════════════
// INPUT-2(2026-09-10)· 表单控件【只有这一处定义】
// ════════════════════════════════════════════════════════════════════════════
// 【它为什么存在,一句话】
//   INPUT-0 量到:540 个单行控件渲染成 15 种高度、4 种圆角、6 种边框色、4 种左内边距,
//   而三项全合标准的只有 2 个。**那不是 540 次疏忽,是【同一个样子被写了 540 遍】。**
//   ☞ 一个样子写两遍,两遍就会漂开;写 540 遍,就是今天这棵树。
//   所以这里是**一处**定义,`<Input>` / `<Textarea>` / 手搓的原生控件 /
//   勾选框 / 单选框 / 文件选择钮 / `<DataTable>` 的筛选框**全部读它**。
//
// ════════════════════════════════════════════════════════════════════════════
// 【值的出处 —— 每一个都标着 MEASURED 还是 TIM'S RULING】
//   MEASURED = `scripts/survey-variant-c.mjs --mode=spec` 在 /brand-sampler 的
//              variant C 上读 getComputedStyle 的解析值(docs/variant-c-spec.md §4.1),
//              INPUT-2 于 2026-09-10 在浏览器里逐项复量过一遍。
//   TIM'S RULING = 取样页没有画过这一类,由 Tim 直接裁的值(spec §2A.2 / §6)。
//
//   高 32px · 圆角 8px · 1px 边框 `--brand-border-strong` #AEBAC9 ·
//   左内边距 10px · 上内边距 4px · 字号 16px(手机)/ 14px(桌面)
//        —— **MEASURED**(2026-09-10 复量:两个视口逐字相同)
//   多行框下限 64px、内容自适应、竖向可拖
//        —— **MEASURED**(`min-height: 64px`;渲染 64px 桌面 / 66px 手机,
//           那 2px 是占位文字在 390px 上折了行,不是一处随视口变的样式)
//   原生 `<select>`:左 10px · **右 24px** · 高 32px
//        —— **TIM'S RULING(2026-09-10, Q9)**。取样页没有画过原生 select;
//           右边那 24px 是给**浏览器自己那颗箭头**让的位置,它不是文本框的对称内边距。
//   勾选框 16×16 · 圆角 4px / 单选框 16px 圆
//        —— **TIM'S RULING(2026-09-10, R5/R6)**
//   ★ 勾选框与单选框**未选中**的边框 = `--brand-muted-text` #62738C
//        —— **TIM'S RULING(2026-09-10, Q8),而它是被一次测量逼出来的:**
//        实测 56 个勾选/单选框**全部**坐在 `--brand-bg` #F1F9FE 上(不是白底),
//        而 R1 的 #AEBAC9 对它只有 **1.85:1**,低于 WCAG 1.4.11 要求的 3:1。
//        #62738C 对 #F1F9FE 是 **4.53:1**、对白卡 #FFFFFF 是 **4.83:1**,两个底都过。
//        ☞ **这一条只管勾选框与单选框。文本框仍然用 #AEBAC9。**
//   选中态填色 = `--brand-ocean-fill` #007FAD + 白勾 / 白横 / 8px 圆点
//        —— **TIM'S RULING(2026-09-10, Q8)**。白对 #007FAD 是 4.53:1。
//   文件选择钮 = Button 的 default 档(#007FAD 底 · 白字 · 高 32 · 左右 10 · 圆角 8 · 无边)
//        —— **TIM'S RULING(2026-09-10, R7/Q10)**;Button 的那几个值本身是 MEASURED(spec §4.2)。
//
// ════════════════════════════════════════════════════════════════════════════
// 【★ 这里【没有】宽度类 —— 它保证的是【不改宽度类】,不是【不改渲染宽度】】
//   Tim 的裁定(2026-09-10, Q6):**手搓控件保持原生元素,只从这里拿【样子】。**
//   于是「采用这套样式」在任何一个调用点上**都不会动那个调用点上的 `w-*`**。
//
//   ★★【一处必须写在这里的更正(INPUT-2 第三轮,2026-09-10)】★★
//   本文件第一版接着写的是「所以渲染宽度不会变,D.3(宽度变了就停手)按构造成立」——
//   **那句话是错的。** 一个**没有宽度类**的原生 `<input>` / `<select>`,宽度是浏览器
//   按**字号与内边距**替它算的(`<input>` = `size` 默认 20 个字符宽;`<select>` = 最长
//   那条选项宽)。本模块把手机字号 14→16px、左内边距 8→10px、下拉右内边距 →24px,
//   于是**没有宽度类的那一批控件当场变宽** —— 实测 `/logistics/lanes` 上两张
//   **不换行的** flex 表单把 390px 的整页溢出从 +12px 推到 +76px。
//   ☞ **Tim 2026-09-10 的裁定(替换旧的宽度停止条件):控件渲染宽度变了【不是停手的理由】,
//     它是标准的必然结果;停手的是【整页横向溢出变大 / 表的行高或滚动范围变化】。**
//     见 `docs/variant-c-spec.md` §4.1 与 `AGENTS.md` 那条同名的教训。
//   ☞ **唯一的例外是勾选框与单选框的 `h-4 w-4`**:一个 `appearance-none` 的勾选框
//     **没有固有尺寸**,不给它 16×16 它就是 0×0 —— 那 16px 本身就是 R5/R6 裁的那个值,
//     不是一次布局宽度。**除此之外,这个文件里一个 `w-*` 都不许出现。**
//
// 【★ 为什么用语义色名而不是写死 #62738C】
//   `border-muted-foreground` → `--color-muted-foreground` → `--brand-muted-text`;
//   `bg-primary` / `border-primary` → `--color-primary` → `--brand-ocean-fill`
//   (`app/brand-tokens.css` 的 @theme inline)。**一个新颜色都没有引入。**
//   ☞ 只有 SVG 里那个白勾没法写 `var(...)`(data URI 里没有 CSS 变量),
//     它写的是 `%23fff` = `--color-primary-foreground` 的值。
// ════════════════════════════════════════════════════════════════════════════

/** 盒子高度 —— 单行控件 32px(MEASURED) */
const BOX = 'h-8'

/** 面:圆角 8px + 1px `--brand-border-strong` + 透明底(MEASURED) */
const SHAPE = 'rounded-lg border border-input bg-transparent'

/** 单行控件的内边距:上下 4px · 左右 10px(MEASURED) */
const PAD_INPUT = 'px-2.5 py-1'

/** 多行框的内边距:上下 8px · 左右 10px(MEASURED) */
const PAD_TEXTAREA = 'px-2.5 py-2'

/**
 * 原生 `<select>` 的内边距:左 10px(照单行控件)· 右 24px(TIM'S RULING, Q9)。
 * 右边这 24px 是给**浏览器自己那颗箭头**的 —— `<select>` 保持 `appearance: auto`,
 * 箭头画在 padding-right 那一段里。文本框没有箭头,所以它不需要这一条。
 */
const PAD_SELECT = 'pl-2.5 pr-6 py-1'

/** 字号与过渡:手机 16px(iOS 在 <16px 的输入框上会自动放大整页)、桌面 14px */
const TYPE = 'text-base transition-colors outline-none'

/** 占位符字色 `--brand-muted-text`(MEASURED) */
const PLACEHOLDER = 'placeholder:text-muted-foreground'

/** 焦点环 —— 每一种控件同一条 */
const FOCUS = 'focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50'

/** 禁用态 */
const DISABLED = 'disabled:cursor-not-allowed disabled:bg-input/50 disabled:opacity-50'

/** 校验失败 */
const INVALID = 'aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20'

/** 断点与暗色 —— 尾巴上这一串对每一种控件都一样 */
const TAIL = 'md:text-sm dark:bg-input/30 dark:disabled:bg-input/80 dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40'

/**
 * `<Input>` 对 `type="file"` 那颗钮做的【复位】。
 * ★ 它与 `CONTROL_FILE_BUTTON`(下面那条,长得像 Button)**不是同一件东西**:
 *   这一条是库里 `<Input type="file">` 今天的样子,原样保留是为了让
 *   `<Input>` 的现有用户**逐字节不变**;那一条是 Tim 为**手搓的**文件输入裁的。
 *   两条都住在这个文件里,所以「一处定义」这件事仍然成立。
 */
const INPUT_FILE_RESET =
    'file:inline-flex file:h-6 file:border-0 file:bg-transparent file:text-sm file:font-medium file:text-foreground'

// ════════════════════════════════════════════════════════════════════════════
// 对外的那几条
// ════════════════════════════════════════════════════════════════════════════

/**
 * ★ 单行控件:`<input type="text|search|email|password|tel|url|date|number|…">`。
 * **不含宽度。** 调用点自己的 `w-*` 原样留着。
 */
export const CONTROL_INPUT = [BOX, SHAPE, PAD_INPUT, TYPE, PLACEHOLDER, FOCUS, DISABLED, INVALID, TAIL].join(' ')

/**
 * ★ 原生 `<select>`。**保持原生**(键盘、手机与无障碍行为一个都不变,spec 的 E5),
 * 只是把**样子**归一,并给浏览器那颗箭头留出右边 24px。**不含宽度。**
 */
export const CONTROL_SELECT = [BOX, SHAPE, PAD_SELECT, TYPE, FOCUS, DISABLED, INVALID, TAIL].join(' ')

/**
 * ★ 多行框:下限 64px、随内容长、竖向拖拽手柄留着(Tailwind preflight 给的 `resize: vertical`)。
 * ☞ **永远不要给多行框一个固定高度**;调用点上的 `rows=` 要去掉 —— `field-sizing-content`
 *   接管之后 `rows` 是空转的(取样页写着 `rows={3}`,渲染不出 78px)。**不含宽度。**
 */
export const CONTROL_TEXTAREA = ['flex field-sizing-content min-h-16', SHAPE, PAD_TEXTAREA, TYPE, PLACEHOLDER, FOCUS, DISABLED, INVALID, TAIL].join(' ')

/**
 * ★ E6 —— 收货与盘点两页上的【触控档】(TIM'S RULING 2026-09-10, Q7;与 E1 同一条理由:
 * 站在仓库里拿手机或扫码枪按,44px 是 Apple HIG 与 WCAG 2.5.5 都点名的那个数)。
 * ☞ 它**只拿**边框色、圆角、焦点环与底色;**高度、上下内边距、字号由调用点自己留着**
 *   (`min-h-[48px] py-3 text-base`)。**不含宽度。**
 */
export const CONTROL_TOUCH = [SHAPE, 'transition-colors outline-none', PLACEHOLDER, FOCUS, DISABLED, INVALID, 'dark:bg-input/30 dark:disabled:bg-input/80 dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40'].join(' ')

// ── 勾选框与单选框 ──────────────────────────────────────────────────────────
// 【为什么是 data URI 而不是一个伪元素】`<input>` 是替换元素,`::before` / `::after`
// 不渲染。原生勾选框上画一个勾,浏览器里唯一稳的办法是 background-image。
// 【为什么整串都做了百分号转义】Tailwind 的任意值里不许有空格、引号与裸括号 ——
// 所以空格是 %20、单引号是 %27、尖括号是 %3C/%3E。**一个字符都不许留白。**
//
// ★★【为什么这两条必须【原样写死】,不许用 `${...}` 拼】★★
//   Tailwind 的扫描器读的是**文件里的字面文本**,不是这段代码跑出来的结果。
//   本刀第一版写的是 `` `checked:bg-[image:url(${TICK})]` `` —— 类名在运行时是对的,
//   而 Tailwind 在文件里只看得见 `checked:bg-[image:url(${TICK})]` 这十几个字符,
//   于是**那两条规则一条都没有生成**,实测浏览器里 `background-image: none`:
//   勾选框选中了,却没有勾。
//   ☞ 这一格是当场量出来的(离线跑 `@tailwindcss/postcss`,10 个候选写法全部生成得出来,
//     而模块里那两条生成不出来 —— 差别只有「字面 vs 拼接」这一件事)。
//   **任何时候在这个文件里改类名,都要保持它是一个字面量。**
const TICK_CLASS =
    "checked:bg-[image:url(data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20viewBox=%270%200%2016%2016%27%3E%3Cpath%20fill=%27none%27%20stroke=%27%23fff%27%20stroke-width=%272%27%20stroke-linecap=%27round%27%20stroke-linejoin=%27round%27%20d=%27M4%208.5L6.5%2011L12%205.5%27/%3E%3C/svg%3E)]"
const DASH_CLASS =
    "indeterminate:bg-[image:url(data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20viewBox=%270%200%2016%2016%27%3E%3Cpath%20fill=%27none%27%20stroke=%27%23fff%27%20stroke-width=%272%27%20stroke-linecap=%27round%27%20d=%27M4%208H12%27/%3E%3C/svg%3E)]"

/** 未选中的框:16×16(R5/R6)· 1px `--brand-muted-text`(Q8,4.53:1)· 透明底 */
const TOGGLE_BASE = 'h-4 w-4 shrink-0 appearance-none border border-muted-foreground bg-transparent bg-center bg-no-repeat transition-colors outline-none'

/** 选中 / 不确定:`--brand-ocean-fill` 填底 + 品牌蓝边 */
const TOGGLE_ON = 'checked:border-primary checked:bg-primary indeterminate:border-primary indeterminate:bg-primary'

/**
 * ★ 勾选框(TIM'S RULING 2026-09-10, R5 + Q8)。
 * 16×16 · 圆角 4px · 未选中 1px #62738C · 选中 = #007FAD 填底 + 白勾 ·
 * 不确定 = #007FAD 填底 + 白横 · 焦点与禁用照 `<Input>`。
 * ☞ **本刀范围内【不确定态的消费者是 0 个】** —— 全仓库唯一用到它的是
 *   `app/components/ui/data-table.tsx:291` 那枚表头全选框,而那个文件归 INPUT-3(Q2)。
 *   先把它定义在这里,是为了 INPUT-3 落地时**不必再定义第二遍**。
 */
export const CONTROL_CHECKBOX = [
    TOGGLE_BASE, 'rounded-[4px]', TOGGLE_ON, 'bg-contain',
    TICK_CLASS, DASH_CLASS,
    FOCUS, DISABLED,
].join(' ')

/**
 * ★ 单选框(TIM'S RULING 2026-09-10, R6 + Q8)。
 * 16px 圆 · 未选中 1px #62738C · 选中 = 边框转 #007FAD + 居中一个 8px 的 #007FAD 圆点。
 * ☞ 圆点用 radial-gradient 画,**底仍然是透明的** —— 与勾选框「整块填掉」是两种样子,
 *   那正是单选与多选在视觉上应当分得开的地方。
 */
export const CONTROL_RADIO = [
    TOGGLE_BASE, 'rounded-full',
    'checked:border-primary',
    'checked:bg-[radial-gradient(circle_at_center,var(--brand-ocean-fill)_0_4px,transparent_4px)]',
    FOCUS, DISABLED,
].join(' ')

/**
 * ★ 文件选择钮(TIM'S RULING 2026-09-10, R7 + Q10)。
 * 它是 `::file-selector-button` **伪元素**,不是一个元素 —— 所以套不上 `<Button>` 组件,
 * 只能把 Button default 档的**样子**用 `file:*` 写出来:
 * #007FAD 底 · 白字 · 高 32px · 左右 10px · 圆角 8px · 无边 · 14px / 500。
 * ☞ 量它要用 `getComputedStyle(el, '::file-selector-button')`,不是量那个 `<input>`。
 *
 * ★★【hover —— INPUT-3(Tim 2026-09-11, Q11)补上的那一条】★★
 *   转换之前,那两处手搓的文件输入自己写着 `hover:file:bg-blue-700`;
 *   照 R2(只许用模块已有的值)接过来,**它们会当场丢掉 hover**。
 *   ☞ Tim 的裁定:**去 `button.tsx` 读 default 档,它有 hover 底色就抄那一条同一个工具类。**
 *     实测 default 档写的是 `hover:bg-primary-hover`(`app/components/ui/button.tsx`,
 *     `buttonVariants` 的 `variant.default`)—— 于是这里写成它的 `file:` 形态。
 *   ★ **这【不是】一个新值**:它逐字就是 Button 已有的那一条,
 *     与「文件钮 = Button 的 default 档」那条裁定同源。
 *   ★ **它不会动 `<Input>` / `<Textarea>`**:那两条发的是 `INPUT_FILE_RESET`(上面那条),
 *     与本常量**不是同一件东西** —— 实测两条组件串逐字未变(见 INPUT-3 交回报告 R6(d))。
 *   ⚠ 写法照本文件抬头那一条:**类名必须是一个完整的字面量**,不许用 `${...}` 拼 ——
 *     Tailwind 的扫描器读的是文件里的字面文本。
 */
export const CONTROL_FILE_BUTTON = [
    'file:mr-3 file:inline-flex file:h-8 file:items-center file:rounded-lg file:border-0',
    'file:bg-primary file:px-2.5 file:text-sm file:font-medium file:text-primary-foreground',
    'file:transition-colors hover:file:bg-primary-hover', TYPE, FOCUS, DISABLED, TAIL,
].join(' ')

/**
 * `<Input>` 自己发的那一串。**它的顺序是刻意逐字保留的** ——
 * INPUT-2 的停止条件之一是「`<Input>` 的现有用户渲染逐字节不变」,
 * 而 `cn()` = `twMerge(clsx())` 在没有冲突时**原样按顺序拼**,
 * 所以只要 token 的顺序不变,发出去的 class 串就逐字不变。
 * ☞ **改这一行之前,先把它和 `git show HEAD:app/components/ui/input.tsx` 里那一串逐字比。**
 *   INPUT-2 是这么证的(见交回报告);把这条比对做成一道常驻的闸,
 *   已经登记在 `docs/forward-queue.md` 的 INPUT-2b 里 —— 本刀不加,
 *   因为本刀只许往 `scripts/` 里添**一支**量具(行高比对器)。
 */
export const INPUT_COMPONENT_CLASS = [
    BOX, 'w-full min-w-0', SHAPE, PAD_INPUT, TYPE, INPUT_FILE_RESET, PLACEHOLDER, FOCUS,
    'disabled:pointer-events-none', DISABLED, INVALID, TAIL,
].join(' ')

/** `<Textarea>` 自己发的那一串。同上,顺序逐字保留。 */
export const TEXTAREA_COMPONENT_CLASS = [
    'flex field-sizing-content min-h-16', 'w-full', SHAPE, PAD_TEXTAREA, TYPE, PLACEHOLDER, FOCUS,
    DISABLED, INVALID, TAIL,
].join(' ')

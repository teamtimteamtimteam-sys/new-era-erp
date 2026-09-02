#!/usr/bin/env node
// scripts/smoke-routes.mjs — 路由冒烟:把 Tim 手点的事一次跑完(OPS 级,按需运行)。
//
// 【为什么存在】两页断了几个月、每道门都是绿的 —— build 只编译、从不渲染;
// RSC 的序列化错误、查询错误只有真的渲染那一页才炸。手点一页一页找,脚本一把全找。
//
// 【它看不见什么 —— 一个自己【画出】错误的页面(EQP-1c-c-fu,2026-08-21)】
// 本脚本断言的是 **2xx**。而本仓库要求"查询失败必须失败"(见 AGENTS.md 的
// mustRows / ?? [] 那一条),页面照做的写法是【接住 error、画一个红框】——
// 那是一次 `return <div>…</div>`,**HTTP 200**。于是:
//     页面写得完全正确 · 每一个登录用户看到的都是一句报错 · 本脚本报 0 FAILED。
// 实测:/finance/expenses/new 的采购行下拉查了遮蔽表 `purchase_order_lines`
// 里被扣住的 `estimated_amount_ccy`,线上 42501;那一轮冒烟 **186 条路由、
// 0 FAILED**,是 Tim 用手点出来的。
// 【与抬头上面那句"?? [] 吞掉错误"不是同一件事,这一点是关键】那一条讲的是
// 写错了的代码;这一条讲的是**照着规矩写对了的代码**,而 2xx 判据同样看不见它。
// 也就是说:**把 ?? [] 全部改掉,这个盲区一个字都不会变窄。**
// 【要收窄它得改判据,不是改页面】断言"渲染出来的 HTML 里没有那个错误框"——
// 那需要脚本认得错误框(一个约定的 data 属性),是一次独立的刀,没有在这里做。
// 做什么:清扫上次残留 → 起 dev server → 建一次性 admin 会话 + 一次性评估人
// fixture(两名 ZZ-SMOKE-* 员工 + 一行试用期评估,/my-reviews/[id] 以评估人
// 视角精确断言 200 —— 对 admin 它 404 是契约,等于从未渲染)→ 请求 app/ 下每一条
// 路由(动态段从库里取真实 id;状态门路由的预期值从被选中那一行算出来,精确断言)
// → 失败的连同【服务端】错误堆栈一起报 —— 浏览器那句话什么都不说,上两只虫都
// 因此多绕了一圈。收尾删掉全部临时行与会话;开跑的清扫兜住 finally 挡不住的 kill。
//
// 【一棵树,同一时刻只跑一个冒烟;一棵树,一个 Claude Code 会话】—— 正确性要求,
// 不是性能建议。sweepScratch() 删掉【所有】smoke-*@test.local 账号,【不看归属、
// 不看年龄】:它分不出"上次崩掉的残骸"与"另一个进程此刻正在用的账号",于是后启动
// 的那个一上来就把先启动的那个的会话删了,而先启动的那个会在下一次 fetch 上拿到
// 一片 401 —— 报出来却像是路由失败。换端口救不了:库是共享的 live 库。
// 两个会话共享的还有 .next(npm run build 会重写它、搞死正在跑的 dev server)、
// git 索引与 /tmp。要并行就各开 worktree 加各自的库,否则排队。
// 全部经过与诊断办法(先查 inode,不要查 diff)见
// docs/concurrency-one-tree-one-smoke.md。
//
// 【开跑前先做一次 3 毫秒的静态预检】preflightIdSources():每条动态路由都取得到 id 吗。
// 那是一个只需要仓库里已有文件就能回答的问题 —— 不该等到起了服务器、建了会话、
// 扫过临时行之后才问(2026-08-11 就是那样,代价是一轮清理加重跑三十分钟)。
// 规律与另外两次(check_mirrors 离开连接池、--reach 改成显式开启)见 AGENTS.md
// §"一条正确的检查放错了相位,就是一条慢检查"。
//
// 用法:node scripts/smoke-routes.mjs                  路由状态那一半(快,2-4 分钟)
//       node scripts/smoke-routes.mjs --reach=finance  【常用】只跑一个角色的可达性
//       node scripts/smoke-routes.mjs --reach          三个角色全跑(约 100 分钟,推送前)
// 【一个角色一跑】GUARD-FIX-1:三个角色一起跑已经装不下(admin 一个人 ~63 分钟,
// 路由前沿爬到一半从 475 涨到 563,finance 被半路杀掉)。角色名拼错会响亮退出 2,
// 不会当成"零个角色"悄悄绿。可选:admin / operations / finance。
// 退出码 0 = 全通;1 = 有失败 / 跳过清单漂移(EXPECTED_SKIPS)/ 脚本自身查询炸了
// 【不进 db/gate.py】整跑约 2-4 分钟且要起 dev server —— 慢门会被跳过,
// check_mirrors 的教训。按需跑:每次改了页面渲染层,或 Tim 又用手找到一只虫之后。
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { spawn, execSync } from 'node:child_process'
import { join } from 'node:path'
import { acquireOrExit } from './liveLock.mjs'

const ROOT = new URL('..', import.meta.url).pathname
const PORT = 3199
const env = readFileSync(join(ROOT, '.env.local'), 'utf8')
const URL_ = env.match(/NEXT_PUBLIC_SUPABASE_URL=(\S+)/)[1]
const ANON = env.match(/NEXT_PUBLIC_SUPABASE_ANON_KEY=(\S+)/)[1]
const SERVICE = env.match(/SUPABASE_SERVICE_ROLE_KEY=(\S+)/)[1]

// ── 路由枚举 ────────────────────────────────────────────────────────────────
// 【BRAND-1(2026-09-02):一条【具名】排除,不是 EXPECTED_SKIPS】
// app/brand-sampler/ 是给 Tim 挑样式的临时页:不在导航里、不连数据库、
// 用完即删。它不该进冒烟的路由清单。
// 【为什么不写进 EXPECTED_SKIPS】那一栏的含义是「这条路由的表里今天没有数据」,
// 而且它的漂移断言会在有数据的那天响,逼人把它删掉。用在这里是【一句假话】:
// sampler 不是没有数据,它是根本不属于这套系统。把一件"故意不测"的事
// 记成一件"暂时没数据"的事,下一个读清单的人会得到一个错的印象。
// 【删除 sampler 时,把这三行一起删掉。】
const SMOKE_EXCLUDED_DIRS = new Set(['brand-sampler'])

function* walk(dir) {
    for (const name of readdirSync(dir)) {
        if (SMOKE_EXCLUDED_DIRS.has(name)) continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (name === 'page.tsx' || name === 'route.ts') yield p
    }
}
const routes = [...walk(join(ROOT, 'app'))].map((p) =>
    p.slice(ROOT.length + 3).replace(/\/(page\.tsx|route\.ts)$/, '') || '/')

// ── 动态段的真实 id 从哪来(PostgREST + service key,随数据变化自动跟上)────
const ID_SOURCES = {
    '[id]': {
        '/customers': 'customers', '/finance/bank/statements': 'bank_statements',
        '/finance/expenses': 'expenses', '/finance/freight': 'freight_documents',
        '/finance/fx': 'fx_rates',
        // EQP-1c-b:资产卡片页。【必须在这里,否则 /finance/assets/[id] 会落到
        // /finance/expenses 那条前缀上吗?—— 不会,前缀取最长匹配,而
        // '/finance/assets' 更长。】它在这里是因为【不在就中止】:预检
        // preflightIdSources() 在 3 毫秒内点名了它,连服务器都没起 —— 那正是
        // "能在开跑前回答的问题就在开跑前回答"。
        // 线上 fixed_assets 今天零行,故同时列在 EXPECTED_SKIPS 里。
        '/finance/assets': 'fixed_assets',
        '/finance/invoices': 'invoices', '/finance/journal': 'journal_entries',
        // GLEXPORT-1:已存档的包。线上今天零行(开放月份不落库,而唯一已关账的
        // 月份还没有人存过),故同时列在 EXPECTED_SKIPS 里。
        '/finance/packs': 'management_packs',
        '/finance/payments': 'payments', '/hr/claims': 'medical_claims',
        '/hr/departments': 'departments', '/hr/employees': 'employees',
        '/hr/leave': 'leave_requests', '/hr/payroll': 'payroll_periods',
        // ATTEND-1:考勤底稿。前缀取最长匹配,所以它不会被 '/hr/' 底下别的条目吃掉。
        // 线上零行(机制与屏幕先于第一份真底稿落地),故同时列在 EXPECTED_SKIPS 里。
        '/hr/attendance': 'attendance_periods',
        '/hr/reviews': 'performance_reviews', '/hr/training': 'training_records',
        '/inbound/receive/done': 'inbound_batches', '/inbound': 'inbound_batches',
        // LOC-1:库位。前缀取最长匹配,所以这一条不会被别的 /inventory 前缀吃掉
        // (今天也没有别的)。线上零行,故同时列在 EXPECTED_SKIPS 里。
        '/inventory/locations': 'storage_locations',
        '/materials': 'materials', '/metal-prices': 'metal_prices',
        '/my-reviews': 'performance_reviews', '/output': 'output_batches',
        '/pricing/formulas': 'pricing_formulas',
        // WO-1c:工单。【必须排在 '/processing' 前面吗?—— 不必,前缀取的是最长匹配】
        // 但它必须【在】,否则 /processing/orders/[id] 会落到 processing_runs 上,
        // 拿一个加工单 id 去开工单详情页 —— 那会是一次看起来像"页面坏了"的 404。
        // 线上零行(机制与屏幕同刀落地),所以同时列在 EXPECTED_SKIPS 里。
        '/processing/orders': 'work_orders',
        '/processing': 'processing_runs',
        '/purchasing/orders': 'purchase_orders', '/purchasing/payment-terms': 'payment_term_templates',
        // SO-1:销售订单。线上零行(这一刀只建单据,没有既有数据),
        // 所以同时列在 EXPECTED_SKIPS 里 —— 与 /inventory/locations 同一种情形。
        '/sales/orders': 'sales_orders',
        // SO-4b:报价。线上零行(机制与屏幕先于第一张真报价落地),所以两条
        // [id] 路由同时列在 EXPECTED_SKIPS 里 —— 开出第一张的那天它们一起响。
        '/sales/quotes': 'quotes',
        '/sales/shipments': 'shipments',
        // CN-1:贷项凭证。线上零行(机制与屏幕先于第一张真凭证落地),
        // 所以同时列在 EXPECTED_SKIPS 里 —— 开出第一张的那天,那条断言会响。
        '/finance/credit-notes': 'credit_notes',
        // STATEMENT-1:客户对账单。**它必须在这里**,否则
        // /finance/statements/[id]/pdf 会落到 '/finance' 这个更短的前缀上
        // (或者干脆没有前缀命中),而预检承诺过的正是这件事。
        // 线上 customer_statements 今天零行(机制与屏幕先于第一份真对账单落地),
        // 故 pdf 那条路由同时列在 EXPECTED_SKIPS 里。
        '/finance/statements': 'customer_statements',
        // TASK-1b:任务详情。**取的 id 必须是一张【团队】任务** —— 见 ID_FILTERS。
        '/tasks': 'tasks',
        '/settings/permissions/roles': 'roles', '/stocktakes': 'stocktakes',
        '/suppliers': 'suppliers',
        // COMM-1:佣金协议的编辑页。线上零行(机制与屏幕先于第一份真协议落地),
        // 所以同时列在 EXPECTED_SKIPS 里 —— 签下第一份的那天,那条断言会响。
        '/commissions': 'commission_agreements',
        // FRT-FIX(2026-08-20):这两条【自建成起就没登记过】,于是 preflightIdSources
        // 每一次都在 3 毫秒内中止整轮冒烟 —— 也就是说 LOG-1b / LOG-2b 之后,
        // 这套路由检查【一次都没跑起来过】。那是这次回归能悄悄上线的一半原因。
        '/logistics/containers': 'containers',
        // 货代详情对【非货代】是 notFound(契约),所以取 id 时必须挑一个货代 ——
        // 见下面 ID_FILTERS 的按路由键。
        '/logistics/forwarders': 'suppliers',
    },
    '[assayId]': { '': 'assay_results' },
    '[batchId]': { '': 'inbound_batches' },
    '[saleId]': { '': 'sales_records' },
    '[materialId]': { '': 'materials' },
    // GST-1:GST 申报期间。两条路由用它 —— /finance/gst/[periodId] 与它的
    // /export(F5 的 CSV 导出)。**预检在起 dev server 之前就点了它的名**,
    // 正如那段注释承诺的:段名不在这里,字面量会原样进 URL,跑到一半报成一次
    // 普通的路由失败,看起来像页面坏了。线上 gst_periods 今天零行
    // (期间要由人开),故两条同时列在 EXPECTED_SKIPS 里。
    '[periodId]': { '': 'gst_periods' },
}
// 预期中的"非 200":这些不是坏,是设计(第一轮全量报告逐条核实后收编)。
// /welcome 与 /set-password 曾在这里挂 [200,307]:两页对持会话的请求都是确定的
// 200(/welcome 根本没有重定向;/set-password 只在无会话时回 /login),宽松项
// 只会挡住"页面开始乱重定向"这个信号,所以删掉,让 2xx 兜底去断言。
// ── 内容断言:状态码看不见的那一类失败 ──────────────────────────────────────
// FRT-FIX(2026-08-20):/finance/freight/new 的货代下拉【自建成起就是空的】
// (一句遗留的 .eq('status','active') 撞上 suppliers.status 默认 'draft'),
// 而那一页始终 HTTP 200 —— 它渲染的是"还没有货代"那句空状态,一句【假话】。
// 冒烟只断言状态码,所以它一路绿着;LOG-1b 也从未往本文件加过任何断言
// (它那一刀 27 个文件,一个都不是这里)。
//
// 【判据要挑那个"空与非空长得不一样"的东西】这里是 name="supplier_id":
// 下拉只在 suppliers.length > 0 时渲染,为空时渲染的是那段琥珀色文字。
// 所以这个字符串在不在,恰好就是"选得到人"与"选不到人"的分界 ——
// 而它与语言无关(断言文案会被下一次改文案弄红,那是喊狼来了)。
// ★【CAPEX-1 想加、而【加不了】的那两条内容断言 —— 写下来,不是留白】★
//   本刀把六句「投用会冻住成本」改写成了别的话,而最想要的一条检查是:
//   **那几句话真的从屏幕上消失了吗**(「一条记录活得比它的主语久」是本仓库
//   自己记着的最常犯缺陷,而它的失败形式恰恰是【什么都不报错】)。
//
//   **加不了,而理由是结构性的:这支冒烟是 fetch 的,不开浏览器。**
//   要断言的那几句话全部长在【客户端开关后面】——
//   `expense.form.existingAssetHint` 在 `isAppend` 之后、
//   `purchasing.form.assetLineHint` 在 `isEquipment` 之后、
//   `assets.actions.commissionWhy` 在面板展开之后。默认状态下它们
//   **不在服务端渲染出来的 HTML 里**,next-intl 的负载里也没有。
//
//   **这是实测出来的,不是推断:** 这两条断言写好跑过一次,双双报红,
//   而两页都是干净的 200 —— **红的是判据,不是页面**。与本仓库为
//   `...&from=` 那条被 HTML 转义成 `&amp;` 的针记过的是同一族:
//   **一个永远满足不了的判据是坏判据**,而它会以「功能坏了」的样子报出来。
//   所以这里【不】留一条假装看得见它的断言,也不把它悄悄删掉不提。
//
//   **这一类文案今天的覆盖是 `docs/manual-walk-list.md` §9 那一步**
//   (已随本刀改写:它现在检查的是那句话【不再出现】)。
//   要把它变成机制,需要一个会点开关的走查器 —— 那是另一件事,
//   不该在一次刚被它绊倒的切次里现写(「匆忙的检查者」那条规矩)。

// PARTY-1:两条内容断言,而它们【都是服务端渲染的】—— 这一点是刻意挑的。
//   昨天(OPS-TIMEOUT 那一刀)刚把第三条冒烟盲区写进 AGENTS.md:
//   **藏在客户端开关后面的针,这支 fetch 冒烟永远看不见。**
//   所以这一次的两句话都画在页面本体上(不在面板的展开态里):
//   客户页那一段联系人的抬头说明,以及重叠页那句"两个敞口不相加"。
//   针从 messages/en.ts 【现读】,并在任何会被 HTML 转义的字符之前收尾
//   (GLEXPORT-1 为一条 `&` → `&amp;` 的针付过一次账)。
const MSG_CONTACTS_SECTION = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    contacts: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 contacts 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*sectionWhat: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 contacts.sectionWhat')
    // 【在文案文件里,破折号是【转义序列】\\u2014 那六个字符,不是那个字符本身】
    // 按真正的破折号切会切不动,于是整句都成了针 —— 而整句里有引号,
    // 服务端渲染会把它转义成 &quot;,那条断言就【永远不可能成立】。
    // 这一条实测踩过一次,写下来是因为下一个人会照抄这个写法。
    return m[1].split('\\u2014')[0].trim()
})()
// ★【这一句是本刀最要紧的一句话,所以它有一条断言看着】★
//   「轧差是一次法律行为,不是一次算术」—— 它必须待在数字旁边。
//   它要是从屏幕上消失了,下一个读这一页的人就会自己把两个数加起来。
const MSG_OVERLAP_NOT_NETTED = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    overlap: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 overlap 这一段')
    const m = blk[0].match(/\n\s*notNettedTitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 overlap.notNettedTitle')
    return m[1]
})()

// KPI-1:两条内容断言,都是【服务端渲染】的 —— 那是刻意挑的,
//   因为藏在客户端开关后面的针这支 fetch 冒烟永远看不见(记在 AGENTS.md)。
// ★ 第一条守的是本刀最要紧的一句话 ★ 原表原文:
//   「矩阵是一份覆盖度的管理视图,不是对组织记分卡的重新加权」。
//   它必须贴着那六行数字 —— 那些数字长得像权重(整数、按 O1–O5 分列),
//   没有这句话在旁边,第一个读的人会把「CCO 在 O4 上有 5 条」读成「权重是 5」。
const MSG_KPI_MATRIX_NOTE = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    kpi: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 kpi 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*matrixNotWeights: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 kpi.matrixNotWeights')
    // 【在会被 HTML 转义的字符之前收尾】原句里有撇号/引号时会变成实体,
    // 那样的针永远不可能成立(GLEXPORT-1 与 PARTY-1 各为此付过一次账)。
    return m[1].split(/[&<>"']/)[0].trim()
})()
// ★ 第二条守的是那句具名缺席 ★ 六个职位里只有两个有人,而一张只显示两人、
//   什么都不说的 roll-up 看起来像是全部。
const MSG_KPI_STAFFING_GAP = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    kpi: \{[\s\S]*?\n    \},/)
    const m = blk[0].match(/\n\s*staffingGap: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 kpi.staffingGap')
    return m[1].split(/[&<>"']/)[0].trim()
})()

// CONTRACT-1:两条内容断言,两条都是【服务端渲染】的 —— 与 PARTY-1 / KPI-1 同一条理由。
// 针从 messages/en.ts 【现读】,并在任何会被 HTML 转义的字符之前收尾
// (GLEXPORT-1 与 PARTY-1 各为一条 `&`/引号的针付过一次账)。
//
// ★ 第一条守的是本刀最要紧的一句话 ★「没有合同被违反」也可能只是「没有人挂过东西」。
//   它必须贴着覆盖率那几个数字 —— 那一段是【无条件渲染】的,所以这条针是死的。
const MSG_CONTRACT_COVERAGE_WHY = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    contracts: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 contracts 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*coverageWhy: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 contracts.coverageWhy')
    return m[1].split('\\u2014')[0].split(/[&<>"']/)[0].trim()
})()
// ★ 第二条守的是那句【具名的缺席】★ 而它有一个坑,写下来免得下一个人踩:
//   breachNothingComparable 只在 documents_with_grade_specs === 0 时渲染,
//   有了第一份带规格的挂接之后它会翻成 breachNone —— 把它写成一条死针,
//   等于给未来安一次【必然的误报】,而误报和真失败长得一模一样(喊狼来了)。
//   所以这里断言的是**两句里至少有一句在**:那个位置【永远有一句具名的话】,
//   绝不会静悄悄地什么都不说。分支走哪一条由真实数据决定,不由这条断言决定。
const MSG_CONTRACT_BREACH_NAMED_ABSENCE = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    contracts: \{[\s\S]*?\n    \},/)
    const cut = (k) => {
        const m = blk[0].match(new RegExp(`\\n\\s*${k}: '([^']+)'`))
        if (!m) throw new Error(`messages/en.ts 里找不到 contracts.${k}`)
        return m[1].split('\\u2014')[0].split(/[&<>"']/)[0].split('{')[0].trim()
    }
    return [cut('breachNothingComparable'), cut('breachNone')]
})()

// PRICE-1:三条内容断言,全部【服务端渲染】—— 与 CONTRACT-1 / PARTY-1 / KPI-1 同一条理由。
// 针从 messages/en.ts 现读,并在会被 HTML 转义的字符与 {占位符} 之前收尾。
// SETTLE-1:把"挑一段够长的字面量"这一步抽出来 —— PRICE-1 那次空针的教训
// 是**结构性**的,所以下一段文案必须用**同一个**守卫,而不是另抄一份判据。
const longestLiteral = (raw, what) => {
    const literals = raw
        .split(/\{[^}]*\}/)
        .map((x) => x.split('\\u2014')[0].split(/[&<>"']/)[0].trim())
        .filter((x) => x.length > 0)
    const best = literals.sort((a, b) => b.length - a.length)[0] ?? ''
    if (best.length < 12) {
        throw new Error(`${what} 抽不出一条够长的针(最长字面量 ${best.length} 字符)—— 空针/短针是永远通过的断言`)
    }
    return best
}
const contractsSubMsg = (section, key) => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(new RegExp(`\\n        ${section}: \\{[\\s\\S]*?\\n        \\},`))
    if (!blk) throw new Error(`messages/en.ts 里找不到 contracts.${section} 这一段 —— 断言无从下手`)
    const m = blk[0].match(new RegExp(`\\n\\s*${key}: '([^']+)'`))
    if (!m) throw new Error(`messages/en.ts 里找不到 contracts.${section}.${key}`)
    return longestLiteral(m[1], `contracts.${section}.${key}`)
}
const settleMsg = (key) => contractsSubMsg('settlement', key)
const pricingMsg = (key) => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n        pricing: \{[\s\S]*?\n        \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 contracts.pricing 这一段 —— 断言无从下手')
    const m = blk[0].match(new RegExp(`\\n\\s*${key}: '([^']+)'`))
    if (!m) throw new Error(`messages/en.ts 里找不到 contracts.pricing.${key}`)
    // ★★【取【占位符之间最长的那一段字面量】,而不是"第一个 { 之前的东西"】★★
    //   第一版就是后者,而它对 '{index}: {days} day(s) loaded…' 这种以占位符开头的
    //   句子求出**空串** —— 而 `html.includes('')` **永远为真**。
    //   一条空针是一条【永远通过】的断言,也就是本仓库反复点名的那种假绿。
    //   这一处是写的时候当场量出来的(两条针都是空的),不是事后想到的。
    const literals = m[1]
        .split(/\{[^}]*\}/)                        // 占位符切开
        .map((x) => x.split('\\u2014')[0].split(/[&<>"']/)[0].trim())
        .filter((x) => x.length > 0)
    const best = literals.sort((a, b) => b.length - a.length)[0] ?? ''
    // 【短针也是坏针】一段太短的字面量会在别处偶然命中,那种"通过"什么都不证明。
    // 抛,而不是返回一个凑合的值 —— 一个说不出话的检查必须说"我不知道"。
    if (best.length < 12) {
        throw new Error(`contracts.pricing.${key} 抽不出一条够长的针(最长字面量 ${best.length} 字符)—— 空针/短针是永远通过的断言`)
    }
    return best
}
// ★ 第一条守的是本刀最要紧的一句话 ★「它【不能】按指数开票」——
//   把「指数定价上线了」读成「我们能按指数开票了」,代价是有人去等一张
//   永远不会自动出现的发票。这一段是无条件渲染的,所以这条针是死的。
const MSG_PRICE_CANNOT_DO = pricingMsg('cannotDo')
// ★ 第二、三条守的是那两句【具名的缺席】,而它们【必须不一样】★
//   「一天开市日历都没加载」与「没有一条报价标了指数」是**两个不同的原因**,
//   而屏幕上它们长得一样的话,读的人会以为只有一件事要修。
//   两条都用 oneOf:分支会随真实数据翻(加载了日历 / 标了指数),
//   写死其中一句等于给未来安一次必然的误报(CONTRACT-1 为这条留过同样的处置)。
const MSG_PRICE_CALENDAR = [pricingMsg('calendarNone'), pricingMsg('calendarLoaded')]
const MSG_PRICE_QUOTES   = [pricingMsg('quotesNone'),   pricingMsg('quotesSome')]

// SETTLE-1:四条内容断言,全部服务端渲染。
// ★ 守的是本刀最要紧的一句:**它【记】结算,它【不过账】**。
const MSG_SETTLE_CANNOT_DO = settleMsg('cannotDo')
// ★ 留样那个【说出来的】未满足前提 —— 第三方复检要有一个罐子,而系统说不出罐子在不在。
const MSG_SETTLE_RETENTION = settleMsg('retentionWhy')
// ★「没有声明容差时系统不替你选」—— 那句话必须贴着条款表,否则下一个人会以为它会选。
const MSG_SETTLE_SPLITTING = settleMsg('splittingWhy')
// 两处具名的缺席,各自会随真实数据翻,所以都用 oneOf。
const MSG_SETTLE_TERMS = [settleMsg('termsNone'), settleMsg('colSettlingParty')]
const MSG_SETTLE_LIST  = [settleMsg('settlementsNone'), settleMsg('notPostedNote')]
// ★★【4.2 的那一条,做成机制而不是一句承诺】★★
//   「没有那一方的化验」与「那一方的结果没被用」**不许长得一样**。
//   今天线上一条结算都没有,所以那两句在页面上都还没机会出现 ——
//   于是这里在**取针的时候**就把它钉住:两句必须存在、够长、而且**彼此不同**。
//   一个只在有数据时才成立的保证,等于没有保证。
const MSG_SETTLE_PARTY_USED = settleMsg('partyResultNotUsed')
const MSG_SETTLE_PARTY_NAMED = settleMsg('partyResultAsNamed')
if (MSG_SETTLE_PARTY_USED === MSG_SETTLE_PARTY_NAMED) {
    throw new Error('contracts.settlement 的两句"用了谁的结果"读起来一模一样 —— 「那一方没有化验」与「那一方的结果没被用」必须分得开')
}

// COMM-1:两块新屏,内容断言全部【服务端渲染】——
// 与 CONTRACT-1 / PRICE-1 / SETTLE-1 同一条理由,而且用【同一个】取针守卫
// (longestLiteral:空针/短针当场抛),不另抄一份判据。
// 【这两个块是顶层的,缩进 4 格】,所以不能用 contractsSubMsg(它匹配的是 8 格的子段)。
const topMsg = (block, key) => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(new RegExp(`\\n    ${block}: \\{[\\s\\S]*?\\n    \\},`))
    if (!blk) throw new Error(`messages/en.ts 里找不到 ${block} 这一段 —— 断言无从下手`)
    const m = blk[0].match(new RegExp(`\\n\\s*${key}: '([^']+)'`))
    if (!m) throw new Error(`messages/en.ts 里找不到 ${block}.${key}`)
    return longestLiteral(m[1], `${block}.${key}`)
}
// ★ 佣金那两句【无条件渲染】的话 —— 它们与有没有数据无关,所以这两条针是死的。
//   「它不过账」被读丢的代价:有人以为总账里已经有这笔支出。
const MSG_COMM_NOT_POSTED = topMsg('commissions', 'notPosted')
//   「计提那一半没建」被读丢的代价:有人以为系统会自己算出欠多少。
const MSG_COMM_NO_ACCRUAL = topMsg('commissions', 'noAccrual')
// ★★ 敞口报表最要紧的两句,同样无条件渲染 ★★
const MSG_EXPO_CANNOT_SEE = topMsg('priceExposure', 'cannotSee')
//   ★ 采购侧那句【关于表结构】的话 —— 它印成 0 吨就是一次撒谎。
const MSG_EXPO_PURCHASE = topMsg('priceExposure', 'purchaseNotModelled')
// 两处会随真实数据翻的分支,用 oneOf:写死其中一句等于给未来安一次必然的误报
// (CONTRACT-1 / PRICE-1 都为这条留过同样的处置)。
// EQP-PAY-1:「这张单没有质保金条款」那一句。★ 它是本刀最要紧的一条【区别】的
// 屏幕那一半:「没有质保金」与「0% 质保金」是两个不同的事实,永远不许长得一样。
// 库里那一半是结构性的(percentage 的 CHECK 是 > 0,0% 那一行存不进去);
// 而屏幕这一半【只有一句话】,**没有任何别的检查看得见一句话在不在**。
const MSG_RETENTION_NONE = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n        retention: \{[\s\S]*?\n        \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 purchasing.retention 这一段 —— 质保金的入口断言无从下手')
    const m = blk[0].match(/\n\s*none: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 purchasing.retention.none')
    return m[1]
})()

const MSG_RETENTION_TITLE = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n        retention: \{[\s\S]*?\n        \},/)
    const m = blk && blk[0].match(/\n\s*title: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 purchasing.retention.title')
    return m[1]
})()

const MSG_EXPO_SELL = [topMsg('priceExposure', 'sellNoContracts'),
                       topMsg('priceExposure', 'sellNoTerms')]
const MSG_EXPO_CALENDAR = [topMsg('priceExposure', 'calendarNone'),
                           topMsg('priceExposure', 'calendarLoaded')]
// ★【那两句"具名的零"必须【彼此不同】,而且在【取针的时候】就钉住】★
//   「一份合同都没有」与「有合同但没写条款」是两种不同的零;屏幕上长得一样的话,
//   读的人会以为只有一件事要修。今天线上一份合同都没有,所以第二句还没机会出现 ——
//   一个只在有数据时才成立的保证,等于没有保证(SETTLE-1 立的规矩)。
if (MSG_EXPO_SELL[0] === MSG_EXPO_SELL[1]) {
    throw new Error('priceExposure 的两句"具名的零"读起来一模一样 —— 「没有合同」与「有合同没条款」必须分得开')
}

const MUST_CONTAIN = {
    // ── 静态判据:下拉在,就说明名单非空 ────────────────────────────────────
    // 这九个下拉是【同一个形状】:名单非空时渲染 <select name="supplier_id">,
    // 为空时改渲染一段琥珀色文字("还没有货代 / 还没有供货商")。所以那个字符串
    // 在不在,恰好就是"选得到人"与"选不到人"的分界,而且与语言无关。
    // 【为什么可以让它在真的没有供应商时红】这几页是收货、采购、计价的主路径,
    // "一个供货商都没有"本来就该响,不是喊狼来了。
    '/finance/freight/new': [
        { needle: 'name="supplier_id"',
          why: '货代下拉是空的 —— 页面会显示"还没有货代",而线上有货代(FRT-FIX 的回归)' },
        // 出境分支的集装箱选择器【由客户端状态开合】,服务端 HTML 里没有那个 <select>。
        // 能验的是【数据有没有到客户端】—— 它作为 prop 序列化在 flight 负载里。
        { probe: '/rest/v1/containers?select=id&limit=1&deleted_at=is.null',
          why: '在册的集装箱没有进到出境分支的选择器负载里(选不到箱子,单据就只能不指出处)' },
        { probe: '/rest/v1/suppliers?select=id&limit=1&deleted_at=is.null&counterparty_type=eq.forwarder',
          why: '那一家在册货代没有出现在货代下拉的负载里' },
    ],
    '/inbound/new': [{ needle: 'name="supplier_id"', why: '供货商下拉是空的' }],
    '/inbound/receive': [{ needle: 'name="supplier_id"', why: '供货商下拉是空的' }],
    '/inbound/[id]/edit': [{ needle: 'name="supplier_id"', why: '供货商下拉是空的' }],
    '/purchasing/orders/new': [{ needle: 'name="supplier_id"', why: '供货商下拉是空的' }],
    // 【这两条用探针,不用静态串】计价公式表单的供应商下拉包在
    // {mode === 'supplier' && …} 里,而 mode 默认是 'generic'(FormulaForm.tsx:74-76)——
    // 服务端 HTML 里【根本没有】那个 <select>。第一版按 name="supplier_id" 写,
    // 两条路由当场报红,而红的是判据不是页面:一个永远满足不了的判据是坏判据。
    // 与 freight/new 出境分支的箱子选择器同一种情形,处置也相同:验负载。
    '/pricing/formulas/new': [
        { probe: '/rest/v1/suppliers?select=id&limit=1&deleted_at=is.null&counterparty_type=neq.forwarder',
          why: '供货商名单没有到客户端 —— 切到"按供应商"那一档就会看到"还没有供货商"' },
    ],
    '/pricing/formulas/[id]/edit': [
        { probe: '/rest/v1/suppliers?select=id&limit=1&deleted_at=is.null&counterparty_type=neq.forwarder',
          why: '供货商名单没有到客户端 —— 切到"按供应商"那一档就会看到"还没有供货商"' },
    ],

    // ── 探针判据:名单藏在负载里,静态字符串表达不了 ────────────────────────
    // 付款页的往来对象是【一个 select 里的一组 option】(CounterpartyOptions),
    // 名单为空时它渲染的是一个禁用 option,不是另一个块 —— 所以
    // name="counterparty" 永远在,不具判别力。PAY-FRT 那次的病是
    // "货代被排除在付款对象之外,于是未付运费永远付不掉",要验的就是那一条:
    // 拿一家在册货代的 id,断言它确实到了客户端。
    // ── PARTY-1:联系人那一段与"不相加"那一句,真的在屏幕上吗 ──────────────
    '/customers/[id]': [
        { needle: MSG_CONTACTS_SECTION,
          why: '客户页上的联系人那一段不见了 —— 而联系人搬进子表之后,那是维护它们的唯一入口' },
    ],
    '/customers/overlap': [
        { needle: MSG_OVERLAP_NOT_NETTED,
          why: '★「两个敞口不相加」那句话从重叠页上消失了 —— 下一个读它的人会自己把两个数加起来,而轧差是一次法律行为' },
    ],

    // ── KPI-1:那句"矩阵不是权重"与那句具名缺席,真的在屏幕上吗 ────────────
    '/hr/kpi': [
        { needle: MSG_KPI_MATRIX_NOTE,
          why: '★「矩阵是覆盖度、不是重新加权」那句话从 KPI 页上消失了 —— 那六行数字长得像权重,没有它就会被读成权重' },
        { needle: MSG_KPI_STAFFING_GAP,
          why: '「六个职位里只有几个有人」那句具名缺席不见了 —— 一张只显示两人、什么都不说的 roll-up 看起来像是全部' },
    ],

    // ── CONTRACT-1:覆盖率那句话、那句具名的缺席,以及【走得到吗】 ──────────
    '/contracts': [
        { needle: MSG_CONTRACT_COVERAGE_WHY,
          why: '★「没挂合同不是缺陷、而"没有违反"可能只是"没有人挂过东西"」那句话从合同页上消失了 —— 下面那句"没有违反"就会撒谎' },
        { oneOf: MSG_CONTRACT_BREACH_NAMED_ABSENCE,
          why: '★ 违反那一段的空状态【一句话都没说】—— "没有违反"与"没有可比的东西"必须分得开,而不是留一片空白' },
        { needle: MSG_PRICE_CANNOT_DO,
          why: '★★「它【不能】按指数开票」那句话从合同页上消失了 —— 把"指数定价上线了"读成"我们能按指数开票了",代价是有人去等一张永远不会自动出现的发票 ★★' },
        { oneOf: MSG_PRICE_CALENDAR,
          why: '开市日历那一段【一句话都没说】—— "一天日历都没加载"是均价算不出来的第一个原因,它必须被说出来,而不是留白' },
        { oneOf: MSG_PRICE_QUOTES,
          why: '标了指数的报价那一段【一句话都没说】—— 它是均价算不出来的【另一个】原因,与缺日历不是同一件事,两者不能长得一样' },
        { needle: MSG_SETTLE_CANNOT_DO,
          why: '★★「它【记】结算、【不过账】」那句话从合同页上消失了 —— 把"结算上线了"读成"结算会过账",代价是有人以为总账里已经有这笔钱 ★★' },
        { needle: MSG_SETTLE_RETENTION,
          why: '★ 留样那个【说出来的】未满足前提不见了 —— 第三方复检要有一个罐子,而这套系统说不出罐子在不在;不说,它就是一个沉默的前提' },
        { needle: MSG_SETTLE_SPLITTING,
          why: '「没有声明容差时系统不替你选」那句话不见了 —— 下一个人会以为系统会选,而替人选就等于决定谁的数字是钱' },
        { oneOf: MSG_SETTLE_TERMS,
          why: '结算口径那一段【一句话都没说】—— "还没有合同写明口径"必须被说出来,而不是留一片空白' },
        { oneOf: MSG_SETTLE_LIST,
          why: '已记录的结算那一段【一句话都没说】—— "还没有结算过"与"结算不可用"是两件事' },
    ],
    // ★【这条不是内容断言,是【可达性】断言】★ /contracts 建好那天没有任何入口,
    //   而本仓库为「页面上线却走不到」付过两次账(SAL-B6、FIX-1)。
    //   --reach 查得到静态路由,只是它要跑两小时 —— 于是那条链接与这条针在同一刀里落地,
    //   把"我记得加了链接"换成机制。链接删了,这里当场红。
    '/suppliers': [
        { needle: 'href="/contracts"',
          why: '★ 供应商列表页上通往合同登记簿的入口不见了 —— /contracts 会变成一个上了线却走不到的页面' },
        // ★【COMM-1:同一条可达性断言,同一个理由】★ /commissions 也是建好那天没有入口的。
        { needle: 'href="/commissions"',
          why: '★ 供应商列表页上通往佣金协议的入口不见了 —— /commissions 会变成一个上了线却走不到的页面(而 --reach 要跑两小时)' },
    ],

    // ── COMM-1:佣金那两句无条件渲染的话,真的在屏幕上吗 ──────────────────
    '/commissions': [
        { needle: MSG_COMM_NOT_POSTED,
          why: '★★「它只记条款、【不过账】」那句话从佣金页上消失了 —— 把"佣金上线了"读成"佣金会进总账",代价是有人以为账上已经有这笔支出 ★★' },
        { needle: MSG_COMM_NO_ACCRUAL,
          why: '★「算出某一笔欠多少那一半没有建(COMM-ACCRUAL-1)」不见了 —— 没有它,下一个人会以为系统会自己算,而金额今天是由人算的' },
    ],

    // ★【COMM-1:敞口报表的入口断言】★ /finance/price-exposure 唯一的入口是财务子导航,
    //   而子导航那个文件里有【两份清单】(ITEMS 管高亮、ordered 管画出来),只加一份
    //   就会出现"链接不出现"或"高亮不对"。这条针钉的是【画出来的那一份】。
    //   Subnav 是 'use client',但它无条件渲染这些 <Link>,所以它在初次 HTML 里 ——
    //   与 AGENTS.md 那条"针必须在默认渲染里、不能藏在点击后面"是相容的。
    '/finance': [
        { needle: 'href="/finance/price-exposure"',
          why: '★ 财务子导航里通往价格敞口的入口不见了 —— 那一页会变成一个上了线却走不到的报表(而它唯一的入口就是这里)' },
    ],

    // ── COMM-1:敞口报表 —— 它的全部价值就是这几句话 ──────────────────────
    '/finance/price-exposure': [
        { needle: MSG_EXPO_CANNOT_SEE,
          why: '★「这一页上的 0 与『没有记录』是两个不同的答案」那句话不见了 —— 没有它,一页零会被读成一个头寸' },
        { needle: MSG_EXPO_PURCHASE,
          why: '★★【采购侧没有被建模】那句话从敞口报表上消失了 —— 它一旦变成一个 0 吨,就是在说"我们没有浮动价买进过",而真相是这套系统还不记这件事 ★★' },
        { oneOf: MSG_EXPO_SELL,
          why: '卖方向那一段【一句话都没说】—— 「一份合同都没有」与「有合同但没写条款」是两种不同的零,那个位置永远要有一句具名的话' },
        { oneOf: MSG_EXPO_CALENDAR,
          why: '开市日历那一段【一句话都没说】—— 它是均价算不出来的【另一个】原因,与"没有合同"不能长得一样' },
    ],

    '/finance/payments/new': [
        { probe: '/rest/v1/suppliers?select=id&limit=1&deleted_at=is.null&counterparty_type=eq.forwarder',
          why: '货代不在付款对象名单里 —— 未付运费就永远付不掉(PAY-FRT 的回归)' },
    ],
}

// 探针为空时【跳过并说出来】,不算失败:"线上还没有货代"是一个正当状态,
// 为它报红就是喊狼来了。与整套冒烟对"没数据 → SKIP"的处置同一条。
const contentSkips = []
async function contentMisses(route, html) {
    const misses = []
    for (const a of MUST_CONTAIN[route] ?? []) {
        if (a.needle) {
            if (!html.includes(a.needle)) misses.push(`${a.needle} —— ${a.why}`)
            continue
        }
        // oneOf:那个位置【至少要有一句话】,走哪一句由真实数据决定。
        // 用在互斥的具名空状态上 —— 写死其中一句会变成一次必然的误报。
        if (a.oneOf) {
            if (!a.oneOf.some((s) => html.includes(s)))
                misses.push(`${a.oneOf.join(' | ')} —— ${a.why}`)
            continue
        }
        const rows = await restRows(a.probe, `${route} ← 内容探针`)
        if (rows.length === 0) { contentSkips.push(`${route}: ${a.why}(探针无数据,跳过)`); continue }
        const id = rows[0].id
        if (!html.includes(id)) misses.push(`${id} —— ${a.why}`)
    }
    return misses
}


const EXPECTED = {
    '/logout': [307, 303],          // 登出即重定向
    '/my-reviews/[id]': [404],      // admin 不是评估人 —— notFound 是契约;评估人视角在主循环后精确单测
    '/purchasing': [307],           // 索引页重定向到 /purchasing/orders
    // ── LOGIN-1-fu1(2026-09-02):登录着的人打开 /login 必然被送进应用 ──────
    // 本冒烟【全程带着 admin 会话】走路由,所以这一条对它永远是 307。
    // 【精确写 307,不写 [200,307]】—— 本文件上面那句话就是理由:两个都行会
    // 静默放过一个开始乱重定向(或者干脆不再重定向)的守卫。这里 200 就是缺陷:
    // 那意味着一个登录着的人又被要求登录一次(Tim 在截图里逮到的正是这个)。
    //
    // 【而「没有会话时它还画不画表单」这一半,状态门在这里【看不见】】
    // 所以主循环后面加了一条【不带 cookie】的探针,专门守那一半 ——
    // 否则这条 EXPECTED 会把登录页彻底坏掉的情形一起放过去。
    '/login': [307],
    // GLEXPORT-1:总账导出【必须】有期间 —— 不带 from/to 就是 400,而那是契约:
    // 一份说不出自己覆盖哪一段的总账导出,日后没有人对得起来。
    // 【只声明这个 400 是不够的】那样这条路由就只有「拒绝」那一半被走过,
    // 而「它真的导得出东西吗」从来没有被问过 —— 所以 QUERY_PROBES 里
    // 配了一条带期间的探针,两条合起来才算走过这条路由。
    '/finance/journal/export': [400],
}
// 三条状态门路由:预期值从被选中的那一行【算出来】,精确断言 ——
// [200,307] 那种"两个都行"会静默放过一个开始乱重定向的守卫。
const STATUS_GUARDS = {
    '/hr/payroll/[id]/edit':                   { table: 'payroll_periods', redirects: (s) => s === 'posted' },      // 已过账不可编辑
    '/stocktakes/[id]/review':                 { table: 'stocktakes',      redirects: (s) => s !== 'open' },        // 非 open 不可复核
    '/finance/bank/statements/[id]/reconcile': { table: 'bank_statements', redirects: (s) => s === 'reconciled' },  // 已对平回详情
}
// 跳过清单要【断言】,不能只打印:一条路由从 ok 移到 skip 是覆盖回归,
// 而它看起来和"还没有数据"一模一样。集合变了(任一方向)都失败,点名差异。
// (/hr/reviews/[id] 与 /my-reviews/[id] 不在此列:评估人 fixture 自带一行评估,
// 这两条每次都真的渲染。)
// 父子配套取 id 的特例(主循环里单独处理,不走 ID_SOURCES)——
// 抽成常量,好让开跑前的预检与主循环【读同一份名单】,不至于各说各话。
const SPECIAL_ID_ROUTES = new Set([
    '/inbound/[id]/assays/[assayId]',
    '/output/[id]/assays/[assayId]',      // PROC-1b:产出化验,父是 output_batch_id
    // FIN-DRILL:科目明细。段里放的是【科目号】(accounts.code),不是 uuid ——
    // ID_SOURCES 一律 select=id,所以它走不了那条路。而且光取一个科目号还不够:
    // 取到一个【没有任何分录】的科目,这条路由照样 200(那是它的具名空状态),
    // 于是这次冒烟就没有走过任何一行明细 —— 与"预期会 SKIP 的路由跑起来了"
    // 互为镜像的一种假绿。所以从 journal_lines 反查一个【确实有行】的科目。
    '/finance/ledger/[account]',
    // IMPORT-1:导入模板。段里放的是**表名**(六个字面量之一),不是任何一行的 id ——
    // ID_SOURCES 一律 `select=id`,所以它走不了那条路,与上面科目号那条同理。
    // 取值直接用 IMPORT_TABLES 的第一个:模板【不读任何业务数据】,
    // 所以"取到哪一张表"不影响这条路由证明得了什么(它证明的是模板生成得出来)。
    '/settings/import/template/[table]',
])

// ════════════════════════════════════════════════════════════════════════════
// 带查询串的探针 —— 定义在模块作用域,好让【总结行也数得到它们】。
//
// ★【GST-FIX-2:这条探针的第一版是【空断言】,而它当场骗过了我自己】★
// 第一版只断言"钻取那一段在不在",而它第一次跑的时候,线上每一个可钻的格
// 都是 0.00 —— 于是它对着一个【空集】变绿,并被当成"这条路已经有覆盖了"。
// **一个因为集合为空而通过的断言什么都没证明** —— 这是本仓库自己的规矩
// (fixture 的"因为错的理由通过"),而它在我新加的检查上第一次跑就应验了。
//
// 现在的口径:**必须对着一个【非空】的格断言,而"非空"由数据说了算,不由断言者说了算。**
// 探针自己去找那张【在册的、带 SR 税码的、落在该期间里的】发票,
// 然后要求页面上出现【那张发票的编号】。找不到这样的发票就【判失败】——
// 一个在空期间上悄悄变绿的探针,比没有这条探针更坏。
// ════════════════════════════════════════════════════════════════════════════
const QUERY_PROBES = [
    {
        name: 'F5 钻取(box1)',
        why: 'F5 的钻取只在 ?box= 之后才存在,而本脚本此前从不发查询串',
        // 找一个【有内容的】期间与它里面的那张发票 —— 两者都找得到才谈得上断言。
        async resolve() {
            const periods = await restRows('/rest/v1/gst_periods?select=id,period_start,period_end&order=period_start.desc',
                'query-probe ← gst_periods')
            for (const p of periods) {
                const rows = await restRows(
                    `/rest/v1/invoice_lines?select=tax_code,invoices!inner(code,issue_date,status)` +
                    `&tax_code=eq.SR&invoices.status=neq.void` +
                    `&invoices.issue_date=gte.${p.period_start}&invoices.issue_date=lte.${p.period_end}&limit=1`,
                    'query-probe ← invoice_lines(SR, live, in period)')
                if (rows[0]?.invoices?.code) {
                    return { url: `/finance/gst/${p.id}?box=box1`, invoiceCode: rows[0].invoices.code }
                }
            }
            return null
        },
        // 断言的是【那张发票的编号出现在钻取里】—— 不是"那一段在不在"。
        // 前者要求集合非空;后者对空集也成立,而那正是第一版的毛病。
        mustNot: 'data-box-detail-error',
    },
    {
        name: 'GL 导出(带期间)',
        why: '总账导出不带 from/to 时按契约返回 400,所以主循环只走过它的「拒绝」那一半;'
           + '这条探针走另一半 —— 它真的导得出这一段里的分录吗',
        // 找一张【真实存在的】分录,用它自己的日期当区间 —— 于是这一段必然非空。
        async resolve() {
            const rows = await restRows(
                '/rest/v1/journal_entries?select=code,entry_date&order=entry_date.desc&limit=1',
                'query-probe ← journal_entries')
            if (!rows[0]?.code) return null
            const d = rows[0].entry_date
            return { url: `/finance/journal/export?from=${d}&to=${d}`, invoiceCode: rows[0].code }
        },
        // 【断言那张分录的编号出现在导出里】—— 不是「文件非空」。
        // 前者要求集合非空;后者对一份只有抬头的 CSV 也成立,而那正是
        // GST-FIX-2 那一课:一条对空集也成立的断言什么都没证明。
        // mustNot 取路由自己失败时会吐的那句话 —— 于是 200 + 有编号 + 没有它,
        // 三条一起才算过。
        mustNot: 'Export failed',
    },
]

const EXPECTED_SKIPS = new Set([
    // (EQP-1c-b 曾在这里挂过 '/finance/assets/[id]' —— 线上 fixed_assets 零行。
    //  2026-08-21 Tim 的走查登记了第一台真机器 FA-2026-0001
    //  「Bosch Deep Discharging Machine」,于是这条断言【在同一天】就报了
    //  「预期会 SKIP 的路由跑起来了 —— 数据到位了」,正如它自己的注释所承诺的。
    //  这一行因此被删掉。留这句话是为了记下:它只跳过了一次跑就到期了,
    //  而那正是"跳过是记录,不是默许"的意思。)
    // 【GST-1 那两行已经删掉了 —— 它自己逼出来的(GST-FIX-1,2026-08-26)】
    // 原文写着:"开出第一期的那天,这条断言会报「预期会 SKIP 的路由跑起来了」,
    // 逼人把这两行删掉。跳过是记录,不是默许。"
    // 那一天到了:Tim 在 2026-08-26 走 §17 时开出了 GST-2026-Q3,于是
    // /finance/gst/[periodId] 与它的 export 从此有数据可跑。两行照约定删除。
    '/hr/claims/[id]',    // medical_claims 空 —— 正常运营会产生;有数据那天此断言逼人收编
    '/hr/leave/[id]',     // leave_requests 空
    // ATTEND-1:线上还没有一份考勤底稿 —— attendance_periods 只由
    // open_attendance_period 写入,而这一刀是机制与屏幕先于第一份真底稿落地。
    // 开出第一个月的那天,这条断言会报「预期会 SKIP 的路由跑起来了」,逼人把它删掉。
    // 【注意它跳过的是明细页,不是列表页】/hr/attendance 每一跑都真的渲染,
    // 而且下面有一条【内容】断言与一条【可达性】断言钉着它。
    '/hr/attendance/[id]',
    // GLEXPORT-1:线上还没有一份【存档】的包。management_packs 只由
    // freeze_management_pack 写入,而它只受理【已关账】的月份;唯一符合条件的
    // 2026-07 至今没有人存过。存下第一份的那天,这条断言会报「预期会 SKIP 的
    // 路由跑起来了」,逼人把这两行删掉 —— 跳过是记录,不是默许。
    // 【注意跳过的是明细页与它的导出,不是列表页】/finance/packs 每一跑都真的
    // 渲染(它有实时预览),而且下面有两条【内容】断言与一条【可达性】断言钉着它。
    '/finance/packs/[id]',
    '/finance/packs/[id]/export',
    // 【FRT-1 的那条跳过已经删掉了 —— 它自己逼出来的(FRT-FIX,2026-08-20)】
    // 原文写着"录第一张的那天,这条断言会逼人把它从这里删掉"。LOG-4b 的端到端
    // 验证在线上留下了三张(已冲销的)运费单,于是那一天到了:这一跑报的是
    // 「预期会 SKIP 的路由跑起来了 —— 数据到位了」,而那正是这条断言存在的理由。
    // 跳过是记录,不是默许。
    // PROC-1b:线上还没有一份产出化验(机制与屏幕先于第一张真单据落地)。
    // 录第一张的那天,这条断言会逼人把它从这里删掉。
    '/output/[id]/assays/[assayId]',
    // STATEMENT-1:线上还没有一份【已签发】的对账单 —— customer_statements 只由
    // issue_customer_statement 写入,而这一刀是机制与屏幕先于第一份真对账单落地。
    // 签发第一份的那天,这条断言会报「预期会 SKIP 的路由跑起来了」,逼人把它删掉。
    // 【注意它跳过的是 PDF 那条路由,不是入口】入口在 /customers/[id] 上,
    // 那一页有数据、每一跑都真的渲染,并且下面有一条【内容】断言钉着它。
    '/finance/statements/[id]/pdf',
    // COMM-1:线上还没有一份佣金协议(机制与屏幕先于第一份真协议落地)——
    // 与上面几条同一种情形。【注意它跳过的是编辑页,不是入口】:
    // /commissions 列表页每一跑都真的渲染,而且下面两条【内容】断言钉着它那两句
    // 无条件渲染的话。签下第一份真协议的那天,这条断言会报「预期会 SKIP 的路由
    // 跑起来了」,逼人把它从这里删掉。
    '/commissions/[id]/edit',
    // (WO-1c 曾在这里挂过 '/processing/orders/[id]' —— 线上零张工单。
    //  2026-08-16 的手走开出了第一张真工单 WO-2026-0001(放行、并挂上
    //  PROC-2026-0225),于是这一行【在同一刀之内】被删掉,正如它自己的注释所
    //  承诺的。留这句话是为了记下:它从来没有真正"跳过"过一次完整的跑 ——
    //  与报价、贷项凭证那两次同一种情形。)
    // (SO-4b 曾在这里挂过 '/sales/quotes/[id]' 与它的 pdf 路由 —— 线上零张报价。
    //  同一天的手走开出了第一张真报价 QT-2026-0001 并签发了两版,于是这两行
    //  【当天就被删掉了】,正如它们自己的注释所承诺的。留这句话是为了记下:
    //  这两条从来没有真正"跳过"过一次完整的跑,它们是被【手走】直接抹掉的。)
    // (CN-1 曾在这里挂过 '/finance/credit-notes/[id]' 与它的 pdf 路由 —— 线上零张
    //  贷项凭证。2026-08-15 的手走开出了第一张真凭证 CN-2026-0001 并签发了 v1,
    //  这条断言【当场响了】,正如它自己的注释所承诺的:SO-4a 的冒烟里报的是
    //  "预期会 SKIP 的路由跑起来了",于是这两行被删掉。留这句话是为了记下它响过 ——
    //  这是同一条断言第三次咬人,而三次里两次是【好消息】:数据到位了。)
    // (SO-3b 曾在这里挂过 '/sales/shipments/[id]/pdf' —— 线上零张发货单。
    //  2026-08-14 的走查发出了第一张真发货单 SHP-2026-0001 并签发了送货单 v1,
    //  这条断言【当场响了】,正如它自己的注释所承诺的:SO-3b fu5 的冒烟里报的是
    //  "预期会 SKIP 的路由跑起来了",于是这一行被删掉。留这句话是为了记下它响过 ——
    //  它此前还响过一次,是新路由刚加进来时【悄悄变成 skip】,而"新路由没被跑过"
    //  与"真的没数据"在屏幕上一模一样。同一条断言,两个方向都咬过人。)
    // (SO-1 曾在这里挂过 /sales/orders/[id] —— 线上零行。2026-08-14 的 SO-1-fu
    //  确认跑开出了第一张真订单 SO-2026-0001 并签发了 v1,这条断言当场逼人把它
    //  删掉,正如它自己的注释所承诺的。留这句话是为了记下【它响过】。
    //  【新加的 /sales/orders/[id]/pdf 也是它报出来的】:一条新路由悄悄变成 skip,
    //  与真的没数据在屏幕上长得一样 —— 那正是这条双向断言存在的理由。)
    // (LOC-1 曾在这里挂过 '/inventory/locations/[id]/edit' —— 线上零行。
    //  2026-08-12 Tim 建了第一个真库位 SG2026081201,这条断言当场逼人把它删掉,
    //  正如它自己的注释所承诺的。留这句话是为了记下【它响过】。)
])
// ── 冒烟临时行的标识 ─────────────────────────────────────────────────────────
// 员工行和评估行会出现在 HR 界面和待办板上 —— 必须一眼即知是脚本垃圾,不是一名
// 幽灵员工挂着一条像真的评估(与 smoke-* 账号前缀同一条理由)。code 自供:
// 取号触发器只在空值时才取,不烧 EMP-YYYY-NNNN 的无缝号。
// ── SMOKE-CONN-1:中止时也要交出【已经做完的那一部分】────────────────────────
// 【为什么】两次历史中止(fetch failed)把整轮结果一起丢掉了,于是十一刀攒下来的
// 按名欠账一条都没答上。**一个残缺的答案胜过没有答案** —— 已经走过的路由是
// 真的走过了,它们的结论不该因为后面某一步炸了而作废。
// 【为什么是模块级】failures/ok/skipped 都是 main() 的局部变量,顶层的 catch
// 看不见它们;这份记录只做一件事:让 catch 说得出"炸之前做完了什么"。
// 【它不参与任何判断】不进退出码、不进断言、不改 SKIP 清单口径 ——
// 纯粹是一份进度回执。加它的那一刀【没有跑过一次冒烟】,所以它被刻意做成
// 无法影响结论的形状。
const PROGRESS = { phase: '启动', ok: [], failed: [], skipped: [] }
function printProgress() {
    const done = PROGRESS.ok.length + PROGRESS.failed.length + PROGRESS.skipped.length
    if (done === 0) {
        console.error(`   中止于【${PROGRESS.phase}】阶段 —— 还没有任何路由被走过,没有部分结果可交。`)
        return
    }
    console.error(`\n── 中止前已完成(阶段:${PROGRESS.phase})—— 这些结论是真的,别丢 ──`)
    console.error(`   走过 ${done} 条:ok ${PROGRESS.ok.length} · FAIL ${PROGRESS.failed.length} · SKIP ${PROGRESS.skipped.length}`)
    if (PROGRESS.failed.length) {
        console.error('   FAILED:')
        for (const f of PROGRESS.failed) console.error('     ' + f)
    }
    if (PROGRESS.skipped.length) console.error('   SKIP: ' + PROGRESS.skipped.join(', '))
    if (PROGRESS.ok.length) console.error('   ok  : ' + PROGRESS.ok.join(', '))
}

const SCRATCH_EMP_PREFIX = 'ZZ-SMOKE-'
// PROBATION-1:入口断言要找的那句话。【从文案文件现读,不写死】——
// 写死一份副本,改了按钮文字这条断言就会安静地失效,而它守的正是"按钮不见了"。
const MSG_RAISE_PROBATION = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const m = src.match(/\n\s*raiseProbation: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 reviews.raiseProbation —— 入口断言无从下手')
    return m[1]
})()
const MSG_RAISE_BLOCKED = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const m = src.match(/\n\s*raiseProbationBlockedTitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 reviews.raiseProbationBlockedTitle')
    return m[1]
})()
// STATEMENT-1:对账单入口断言要找的那句话,同样【从文案文件现读】。
// 先切出 statements: { … } 那一段再取键 —— 'sectionTitle' 这个名字别处也有,
// 全文件正则会抓到别人家的那一条,而那条断言从此守着一件无关的事。
const MSG_STATEMENT_SECTION = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    statements: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 statements 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*sectionTitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 statements.sectionTitle')
    return m[1]
})()
// CHASE-1:催收那一段的入口断言要找的那句话,同样【从文案文件现读】。
const MSG_CHASE_SECTION = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    chases: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 chases 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*sectionTitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 chases.sectionTitle')
    return m[1]
})()
// CASHFLOW-1：现金预测页的入口断言要找的那句话，同样【从文案文件现读】。
// 【它是一张新页面，而这个仓库为「页面上线却走不到」付过两次账】——
// 一条内容断言比一次两小时的走查便宜得多，而且它每一跑都在。
const MSG_FORECAST_TITLE = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    cashForecast: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 cashForecast 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*title: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 cashForecast.title')
    return m[1]
})()
// CLAIM-1：报销那两块面板的入口断言要找的话，同样【从文案文件现读】。
// ★ 前缀是 expenseClaims.*，不是 claims.* —— 后者是【医疗报销】占着的
//   命名空间，而两块面板并排出现在 /me 上。写错前缀的断言会去守另一块面板。
const MSG_MY_CLAIMS = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    expenseClaims: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 expenseClaims 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*myTitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 expenseClaims.myTitle')
    return m[1]
})()
const MSG_CLAIMS_TITLE = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    expenseClaims: \{[\s\S]*?\n    \},/)
    const m = blk[0].match(/\n\s*title: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 expenseClaims.title')
    return m[1]
})()
// ATTEND-1：考勤两块面板的入口断言，同样【从文案文件现读】。
// 【断言用的是 subtitle 而不是 title】"Attendance" 这个词在子导航里也出现，
// 于是拿 title 去断言，会在【页面本身没渲染出来、只有导航条在】时照样通过 ——
// 一条对自己没走过的地面报绿的断言。subtitle 只有这一页画得出来。
const MSG_ATTENDANCE_SUB = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    attendance: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 attendance 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*subtitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 attendance.subtitle')
    return m[1]
})()
// WHT-1：预提税页的入口断言，同样【从文案文件现读】。
// 【断言 subtitle 而不是 title】"Withholding tax" 这个词在财务子导航里也出现，
// 拿 title 去断言，会在【页面本身没渲染出来、只有导航条在】时照样通过 ——
// 一条对自己没走过的地面报绿的断言(ATTEND-1 的原话，这里是它的第二次)。
const MSG_WHT_SUB = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    wht: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 wht 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*subtitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 wht.subtitle')
    return m[1]
})()
// ★【这一条断的是【具名的缺席】，而它红的那一天就是它要说的话】★
// 线上一个非居民服务商都没有(实测 0 家 service_vendor)，所以这一页今天
// 渲染的永远是空状态那一半，**有数据的那一半没有任何东西在走它** ——
// fixture 142 走的是函数，不是页面。先例俱在:/finance/freight/new 的货代
// 下拉自建成起就是空的，冒烟一路绿了好几周(FRT-FIX)。
// 所以这条断言【故意】钉着空状态那句话:第一笔真实的代扣发生时它会变红，
// 而那正是「该有人去走一遍有数据的那条路」的时刻。**它是一个会自己响的返回条件，
// 不是一句没人读的注释。** 红了以后的正确处置不是删掉它，是换成对表格的断言，
// 并在那一刀里把有数据的分支走一遍。
const MSG_WHT_NONE = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    wht: \{[\s\S]*?\n    \},/)
    const m = blk[0].match(/\n\s*noneTitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 wht.noneTitle')
    return m[1]
})()
const MSG_MY_ATTENDANCE = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    attendance: \{[\s\S]*?\n    \},/)
    const m = blk[0].match(/\n\s*myTitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 attendance.myTitle')
    return m[1]
})()
// GLEXPORT-1：报表包页的入口断言，同样【从文案文件现读】。
// 【断言 subtitle 而不是 title】"Monthly pack" 这个词在财务子导航里也出现，
// 拿 title 去断言，会在【页面本身没渲染出来、只有导航条在】时照样通过。
// 这是同一个坑的第三次(ATTEND-1、WHT-1，现在是它)，所以这里不再重新踩。
const MSG_PACK_SUB = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    pack: \{[\s\S]*?\n    \},/)
    if (!blk) throw new Error('messages/en.ts 里找不到 pack 这一段 —— 入口断言无从下手')
    const m = blk[0].match(/\n\s*subtitle: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 pack.subtitle')
    return m[1]
})()
// ★【这一条断的是【这一刀的裁定本身】】★ 「一份存下来的包意味着它产出时那个月
// 已经关账了」—— 那句话必须出现在读者遇到存档包的那一屏上。它不是装饰:
// 整个 freeze 只受理已关账月份的设计，全靠这句话让读者知道自己手上拿的是什么。
// 把它钉住，是因为一句会被下一次改版悄悄删掉的解释，等于这条规矩没有被说出来。
const MSG_PACK_STORED_MEANS = (() => {
    const src = readFileSync(join(ROOT, 'messages/en.ts'), 'utf8')
    const blk = src.match(/\n    pack: \{[\s\S]*?\n    \},/)
    const m = blk[0].match(/\n\s*storedMeans: '([^']+)'/)
    if (!m) throw new Error('messages/en.ts 里找不到 pack.storedMeans')
    return m[1]
})()
const SCRATCH_NAME = '【SMOKE 冒烟脚本临时行 · 勿动 · 随时可删】'

async function rest(path, opts = {}) {
    const r = await fetch(URL_ + path, { ...opts,
        headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json', ...(opts.headers ?? {}) } })
    return r
}
// 有软删列的表跳过已删行 —— 详情页对已删行 404 是契约,不是坏。
// 【只列真有 deleted_at 列的表】expenses/invoices/sales_records 没有这列,曾被错列进来:
// 过滤报错被读成"没数据",四条路由悄悄失去覆盖(下面 restRows 就是那次的教训)。
// FRT-FIX 之后又一处同形的漏登记(2026-08-20):tasks 有 deleted_at,却不在这里。
// 线上 7 张 team 任务里 5 张已软删,而取 id 的那条查询【没有 order by】,
// PostgREST 按物理顺序返回 —— 实测五次全部返回 TASK-2026-0005(2026-08-19 13:26
// 软删)。详情页对已删行 notFound 是【契约】(app/tasks/[id]/page.tsx:33/36),
// 所以那个 404 是这条检查【问错了主语】,不是页面坏了。
// 更坏的是它【不稳定】:物理顺序会随更新漂移,于是这条断言迟早会时绿时红,
// 而那比一直红更难查(ID_FILTERS 上面那段注释说的就是这件事)。
// SWEEP-HYGIENE(2026-08-20):按【线上目录】把这一类关掉,不再靠人想起来。
// 判据是一句话:一张有 deleted_at 列的表,只要喂着某条 [id] 路由,就必须在这里。
// 审计方法与结果记在 docs/known-issues.md;这一轮补了 5 张:
// assay_results / freight_documents / quotes / roles / sales_orders。
// 每一张都是一次【与 tasks 同形的、间歇性的】失败:取到一行已删的,
// 详情页按契约 404,而那个 404 读起来像页面坏了。
const SOFT_DELETED = new Set(['containers','customers','suppliers','materials','bank_statements','tasks',
    'assay_results','freight_documents','quotes','roles','sales_orders',
    'inbound_batches','leave_requests','medical_claims','metal_prices','output_batches',
    'payroll_periods','payment_term_templates','pricing_formulas','processing_runs','purchase_orders',
    'review_cycles','stocktakes','training_records','fx_rates','employees','departments'])
// 查询失败 ≠ 没有数据:失败必须当场炸并点名路由和错误,绝不能记成 SKIP ——
// 与 check-i18n 的"解析出 0 个后缀是坏,不是空集"同一条规矩。
async function restRows(path, ctx) {
    const r = await rest(path)
    const body = await r.text()
    let rows = null
    try { rows = JSON.parse(body) } catch {}
    if (!r.ok || !Array.isArray(rows))
        throw new Error(`id 查询失败(${ctx}): HTTP ${r.status} ${body.slice(0, 300)}`)
    return rows
}
// 【为什么会需要按条件挑 id,而不是随手拿第一行】
// 冒烟是以 admin 登录跑的。TASK-1c 之后,一张【私人】任务属于别人,而 admin
// 并不持有 module.tasks.view_all —— 那一页会【正当地】拒绝。从六行里随机挑,
// 得到的是一个【时好时坏】的冒烟,而那比一直红更坏:没有人会去查一个偶尔绿的失败。
// 所以这里按名声明"这条路由要的是哪一种行",而不是让它去赌。
// 键可以是【表名】,也可以是【整条路由】。后者是 FRT-FIX 加的:suppliers 这张表
// 同时喂 /suppliers/[id]/edit 与 /logistics/forwarders/[id],而后者对非货代
// 是 notFound(契约)—— 只按表名过滤没法把两者分开。路由键优先。
const ID_FILTERS = {
    tasks: '&task_type=eq.team',
    '/logistics/forwarders/[id]': '&counterparty_type=eq.forwarder',
}
// 【没有 order by 的 limit 1 是一个会漂的判据】PostgREST 按物理顺序返回,而物理
// 顺序随更新而变。tasks 那一次是软删撞上它,但病根是排序:同一条断言今天绿、
// 明天红,而"时好时坏的冒烟比一直红更坏"(ID_FILTERS 上面那段注释)。
// 取【最新的在册那一行】,并以 id 收尾破平局 —— 同一批种子数据的 created_at 常常
// 一模一样,只按时间排序仍然是不确定的。
//
// ★【"全部有 created_at"这句话在 2026-08-28 到期了 —— ATTEND-1】★
// 原文写的是「ID_SOURCES 用到的 36 张表全部有 created_at(实测,不是假设)」。
// 那句话在写下那天是真的,但它是一句【当时的实测】,不是一条不变量:
// 全库 166 张表里有 52 张没有 created_at,而 attendance_periods 是新的一张 ——
// 它的"建出来那一刻"叫 opened_at,再加一个 created_at 就是同一件事的两个名字。
// 处置:排序键【按表可覆盖】,而不是为了迁就一句排序去改表的形状。
const ORDER_OVERRIDES = {
    // 一个月一份底稿,period_month 是 UNIQUE 的 —— 它本身就是稳定序。
    attendance_periods: '&order=period_month.desc,id.desc',
    // GLEXPORT-1:一份包"产出来那一刻"叫 produced_at —— 再加一个 created_at
    // 就是同一件事的两个名字(与 attendance_periods 的 opened_at 逐字同一条)。
    // 【为什么不是按 period_month】同一个月可以有多份(重出),period_month
    // 不唯一;produced_at + id 才排得出先后。
    management_packs: '&order=produced_at.desc,id.desc',
}
const ORDER_DEFAULT = '&order=created_at.desc,id.desc'
async function firstId(table, route) {
    const del = SOFT_DELETED.has(table) ? '&deleted_at=is.null' : ''
    const filter = ID_FILTERS[route] ?? ID_FILTERS[table] ?? ''
    const ORDER = ORDER_OVERRIDES[table] ?? ORDER_DEFAULT
    const rows = await restRows(`/rest/v1/${table}?select=id&limit=1${del}${filter}${ORDER}`, `${route} ← ${table}`)
    return rows[0]?.id ?? null
}
async function restOk(path, opts, ctx) {
    const r = await rest(path, opts)
    if (!r.ok) throw new Error(`${ctx}: HTTP ${r.status} ${(await r.text()).slice(0, 300)}`)
    return r
}
// ════════════════════════════════════════════════════════════════════════════
// 【清理动作专用:失败必须【说话】,但【不能中断】后面的清理】
//
// ★ CLEANUP-A(2026-08-31)为什么加它 ★
//   清理一个一次性账号是【两半】:删掉它的 user_roles,再删掉 auth 账号。
//   这两半从前写成两次【各自可失败】的调用,而**删权限那一半用的是 rest()
//   —— 返回码根本没人看**,删账号那一半却用 restOk()。于是"权限没删掉"
//   可以静默失败,"账号删掉了"却一定成功。留下的正是
//   **一条权限还在、而账号已经没了的授权** —— 一个谁也解析不出来的幽灵 admin。
//   `user_roles.user_id` 【没有】指向 auth.users 的外键(employees.user_id 有),
//   所以数据库不会替我们把这两半绑在一起;而账号一旦删掉,
//   任何按"列出账号再清理"写的清扫都【再也看不见】那行授权。
//   ACCOUNTS-CLEAN 在 2026-08-24 删掉 66 条,一周后又长回 21 条(8 + 13)。
//
// 【为什么不是直接换成 restOk】restOk 会抛,而这些调用大多在 finally 里 ——
//   在 finally 里抛出去会把它【后面几步清理一起吃掉】,那是换一个缺陷,不是修。
//   所以:照常往下清,但每一次失败都记账、都印出来、并且让冒烟【变红】。
//   一条没删掉的 admin 授权是一次失败,不是一条日志。
// ════════════════════════════════════════════════════════════════════════════
const cleanupFailures = []
async function restCleanup(path, opts, ctx) {
    try {
        const r = await rest(path, opts)
        if (!r.ok) {
            const body = (await r.text()).slice(0, 200)
            cleanupFailures.push(`${ctx}: HTTP ${r.status} ${body}`)
            console.error(`  ✗ 清理失败(继续清,但记账):${ctx} → HTTP ${r.status} ${body}`)
        }
        return r
    } catch (e) {
        cleanupFailures.push(`${ctx}: ${e.message}`)
        console.error(`  ✗ 清理失败(继续清,但记账):${ctx} → ${e.message}`)
        return null
    }
}
async function signIn(email, password) {
    return (await signInSession(email, password)).cookie
}
// PROBATION-1:同一次登录,既给页面用的 cookie,也给【调 RPC 用的 access_token】。
// 【为什么需要后者】restOk 走的是 SERVICE_ROLE key,而 service_role 下
// auth.uid() 是 NULL → current_user_permissions() 空 → require_permission 直接拒。
// 也就是说:拿 service key 调 open_probation_review 【测不到那条产品路径】,
// 只会测到一句 PERMISSION_DENIED。要走产品的路,就得是一个真的、有权限的人。
async function signInSession(email, password) {
    const sess = await (await fetch(URL_ + '/auth/v1/token?grant_type=password', { method: 'POST',
        headers: { apikey: ANON, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }) })).json()
    if (!sess?.access_token) {
        throw new Error(`登录失败(${email}):${JSON.stringify(sess).slice(0, 200)}`)
    }
    return {
        token: sess.access_token,
        cookie: 'sb-' + URL_.split('//')[1].split('.')[0] + '-auth-token=base64-'
            + Buffer.from(JSON.stringify(sess)).toString('base64url'),
    }
}
// 以【某个人】的身份调 RPC —— 与 rest() 的差别只有一处:Bearer 换成他的 token。
async function rpcAs(token, fn, body) {
    return fetch(URL_ + '/rest/v1/rpc/' + fn, { method: 'POST',
        headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body) })
}
// 【同一条理由的第二半:端口】kill 留下来的不只是库里的临时行,还有一个
// 还占着 3199 的 dev server —— finally 同样挡不住它。缺了这一扫,下一次跑在
// EADDRINUSE 上死掉,而错误看起来像"这一刀把服务器改坏了"(2026-08-10 实际发生)。
// 【规矩写成一句】kill 会留下什么,就得在开跑时扫什么;收尾清理永远兜不住 kill。
//
// 【但绝不无差别杀】docs/concurrency-one-tree-one-smoke.md 记着这条的反面教训:
// 那天双方都在"清理 stray",双方杀掉的都是对方【正在跑】的进程。所以这里只杀
// 【证明得了是孤儿】的:父进程已经没了(被 launchd 收养,ppid = 1)。
// 一个还有活父进程的 dev server 属于另一个正在跑的人 —— 那时不杀,而是【拒绝开跑】
// 并说清楚为什么,因为共享的 live 库让两次冒烟无论如何都不能同时正确。
function sweepStalePort() {
    let pids = []
    try {
        pids = execSync(`lsof -ti:${PORT}`, { encoding: 'utf8' }).trim().split('\n').filter(Boolean)
    } catch { return }          // lsof 无匹配时退出码非 0 —— 没人占端口,正常
    for (const pid of pids) {
        let ppid = '', cmd = ''
        try {
            ppid = execSync(`ps -o ppid= -p ${pid}`, { encoding: 'utf8' }).trim()
            cmd = execSync(`ps -o command= -p ${pid}`, { encoding: 'utf8' }).trim()
        } catch { continue }    // 刚好退干净了
        if (ppid === '1') {
            process.kill(Number(pid), 'SIGKILL')
            console.log(`  清扫孤儿 dev server:pid ${pid}(父进程已死,ppid=1)占着 ${PORT}`)
        } else {
            console.error(`\n✗ 端口 ${PORT} 被一个【还有活父进程】的进程占着(pid ${pid}, ppid ${ppid}):`)
            console.error(`    ${cmd}`)
            console.error(`  这不是孤儿 —— 多半是同一棵树上另一次冒烟正在跑。不杀它。`)
            console.error(`  一棵树同一时刻只能跑一个冒烟(共享 live 库 + sweepScratch 无归属过滤),`)
            console.error(`  理由见 docs/concurrency-one-tree-one-smoke.md。等它跑完,或去确认它真的是孤儿:`)
            console.error(`    ps -o ppid,lstart -p ${pid}   ·   lsof -p ${pid} -a -d 1`)
            process.exit(1)
        }
    }
}

// 【开跑先扫,不只收尾再删】finally 挡不住 kill:上次崩掉的残留必须在开跑时清掉,
// 否则一次崩溃就把临时行永久留在库里 —— 别处的 fixture 靠事务回滚兜底,
// 本脚本驱动 HTTP 打真服务器,回滚不存在,清扫就是它唯一的机制。
async function sweepScratch() {
    const emps = await restRows(`/rest/v1/employees?select=id&code=like.${SCRATCH_EMP_PREFIX}*`, '清扫 ← employees')
    if (emps.length) {
        const ids = emps.map((e) => e.id).join(',')
        await restOk(`/rest/v1/performance_reviews?or=(employee_id.in.(${ids}),reviewer_employee_id.in.(${ids}))`,
            { method: 'DELETE' }, '清扫残留评估行')
        await restOk(`/rest/v1/employees?id=in.(${ids})`, { method: 'DELETE' }, '清扫残留员工行')
    }
    const page = await (await restOk('/auth/v1/admin/users?per_page=1000', {}, '清扫:列账号')).json()
    const stale = (page?.users ?? []).filter((u) =>
        (u.email ?? '').startsWith('smoke-') && (u.email ?? '').endsWith('@test.local'))
    for (const u of stale) {
        // 【顺序要紧:先收权限,再删账号】反过来做,一旦第二步之前挂掉,
        // 剩下的就是一条【认不到人】的授权,而且此后没有任何清扫看得见它。
        await restCleanup(`/rest/v1/user_roles?user_id=eq.${u.id}`, { method: 'DELETE' },
            `清扫授权 ${u.email}`)
        await restOk(`/auth/v1/admin/users/${u.id}`, { method: 'DELETE' }, `清扫账号 ${u.email}`)
    }
    if (emps.length || stale.length)
        console.log(`  清扫上次残留:${emps.length} 员工行 / ${stale.length} 账号`)
}


// ════════════════════════════════════════════════════════════════════════════
// 按角色的可达性(REACH-1)—— 「打得开,却从首页走不到」
// ════════════════════════════════════════════════════════════════════════════
// 【为什么要有】上面那一大圈以 admin 跑,而 admin 什么都有,所以一道【太紧】的门
// 在那里永远是 200;另一侧,纯静态的可达性走查只知道"代码里有没有这条链接",
// 不知道"这个人的屏幕上有没有渲染出来"。两者缺的是同一个东西:
// 【以某个角色的身份从 / 出发,只跟着他真的看得见的链接走】。
// /margin 就是这么漏掉的:它一直有两个入口,但都在模块内部 —— 财务侧的人看不见
// 加工那个,加工侧的人看不见财务那个,而全局导航里一个都没有。
//
// ── 这个检查【看不见】什么(绿灯不等于全覆盖)──────────────────────────────
// 1.【客户端渲染出来的链接】只在 useState / 展开 / 弹窗之后才出现的入口,这里抓不到:
//    我们读的是服务端吐出来的 HTML,不跑浏览器。要覆盖它就得引入 Playwright,
//    那是另一个量级的项目。凡是入口藏在交互后面的页面,本检查【什么也没说】。
// 2.【动态路由】/xxx/[id] 的可达性取决于"这个角色在列表页上看不看得见行"——
//    没有行就没有链接,而"没有数据"与"到不了"在走查眼里长得一模一样
//    (restricted-is-not-zero 那条病换了身测试的衣服)。所以断言【只覆盖静态路由】,
//    动态路由单独计数报出来,绝不悄悄算进"通过"。
// 3.【"打得开"是前提】一个人打不开的页面,谈不上"该有入口"—— 所以断言只覆盖
//    他【打得开】的静态路由。这一条不是偷懒:operations 打不开 /margin(缺
//    data.view_prices),对他而言那一页的入口有无都不改变什么;而 finance 打得开,
//    所以入口消失就必须被点名。注入验证时按角色分别验,别用一个角色的结果替另一个说话。
// 4. 它不判断"这个人【应不应该】看见这个入口"—— 那是产品判断。它只保证
//    "打得开"与"走得到"这两个集合对得上,不一致就点名。
// ════════════════════════════════════════════════════════════════════════════
// 【默认不跑 —— 要跑请显式开:node scripts/smoke-routes.mjs --reach】
// ════════════════════════════════════════════════════════════════════════════
// 代价:三个角色各走一遍 = 在主循环之后再抓上千次页面。它一度是默认打开的,
// 于是【每次提交前都要等着它】—— 那正是当初把它排除在 db/gate.py 之外的同一笔代价,
// 只是换了条路走进来。
//
// 【实测二:【超过 2 小时】(2026-08-24 夜,GST-1 那一跑,189 条路由)】
// 比上面那个数字又长了一倍,而路由只多了 50 条 —— 差额【不在路由数上,在链路上】:
// 当晚隧道是退化的,`select 1` 三次量到 7.05s / 4.61s / 5.91s,
// 而同一天早些时候是 3.1–4.1s。reach 的每一步都是一次真的服务端渲染、
// 每一次渲染都打远端库,所以隧道一慢,这一跑的时长直接跟着乘。
// **所以这个数不能只读一个标量:要连当天的 `select 1` 一起读。**
// 那一跑还撞上了另一件事(已记进 AGENTS.md):它跑过了 run_detached 的 7200s 上限,
// 而上限杀掉的是子壳、不是 node 本身,于是它孤儿化继续跑完,
// 判词只能从下面那行总结里读,没有 SMOKE_EXIT= 可读。
// 【2026-08-29 起不会再这样了(OPS-TIMEOUT)】run_detached 到点先写
// `SMOKE_EXIT=124` 再按【进程组】收尾,所以"跑过上限"从此有判词、也不再留孤儿。
// **但那一次的读法仍然是对的、也仍然值得读**:判词从日志里那行总结读,
// 并写明它是从哪儿来的 —— 一个来路不明的判词才是问题。
// 而 124 与"这一跑其实成功了"是两回事:读到 124 要回头问的是
// **这个上限是不是安得太小了**(那正是 GST-2 那次的直接起因)。
// 【实测:65 分 44 秒(2026-08-11 夜,PUR-2 那一跑,139 条路由)】
// 这里原本写着"十到十五分钟",而那个数字是【早期估的,从没有人回头量过】——
// 实际是它的四到五倍。reach 阶段那一跑抓了 1,018 次页面(admin 走到 337、
// operations 115、finance 281,外加逐条试开),每一次都是一次真的服务端渲染,
// 每一次渲染都要打远端数据库。路由数从 ~135 涨到 139 的同时,这个数只会继续长。
//
// 【为什么把真实数字写在这里要紧】决定"这一刀要不要跑 --reach"的人读的就是这一行。
// 写着十五分钟,他会顺手跑;写着一小时,他会先问一句"这一刀动没动导航"。
// 那正是把它改成显式开启时想要的那种判断 —— 而一个低估了四倍的数字,
// 会让那个判断建立在错的前提上。写下来的成本必须是量过的成本。
// 慢到每次都跑不动的检查,最后的下场是没人跑(check_mirrors 的教训),
// 所以宁可把"什么时候该跑"写清楚,也不要让它默认拖住每一次提交。
//
// 【什么时候跑】
//   * 改了【导航、首页卡片、子导航、模块清单(lib/modules.ts)、权限守卫】之后 ——
//     这些正是"谁能走到哪"的定义;
//   * 【新增了一个页面】之后 —— 尤其是 [id] 这类动态路由:本检查【不覆盖动态路由】
//     (见下面第 2 条),SAL-B6 的客户状况页新建时就差点一个入口都没有,
//     而这道检查不会替你发现,所以新页面的入口要自己确认;
//   * 【推送之前】,若这一轮攒了几刀改过页面;
//   * 有人报告"我进不去某一页"或"这一页我看不见入口"时。
//
// 【什么时候不必跑】只动了数据库、文案、单个页面内部的渲染 —— 那些由主循环
// (每条路由渲染一遍)与 db/gate.py 覆盖,可达性不会因此改变。
// ── 【一个角色一跑】GUARD-FIX-1(2026-09-01)────────────────────────────────
//   node scripts/smoke-routes.mjs --reach=finance    ← 常用:只跑你动过的那个角色
//   node scripts/smoke-routes.mjs --reach            ← 三个角色全跑(推送前的整轮)
//
// 【为什么要能只跑一个角色】上一跑(NAV-REG-1)admin 一个人就吃掉 90 分钟里的 ~63
// 分钟,而路由前沿在爬的中途从 475 涨到 563 —— 这一跑【已经装不下了】,finance 是
// 被半路杀掉的那个。而三小时的检查等于没有检查:GUARD-FIX-1 那两处丢掉的守卫活了
// 四天,恰恰因为唯一看得见那类缺陷的就是本检查,而那四天里没有人跑得起它。
// 一个角色一跑,每跑都在能忍的时间里结束,于是它会被真的跑;并且改了某一个角色的
// 权限之后,可以【只】验那一个角色。
// 【每角色的成本:先估错了一次,所以这里写的是量过的那个】
// GUARD-FIX-1 头一跑按 2026-08-11 的抓取比例(admin 337 / operations 115 /
// finance 281)推出"finance ~20-25 分",据此把上限设成 3600s —— **推错了**:
// 实测爬的速率是 **10 页/分钟**(90 秒 15 页),而 finance 的前沿一路涨到 277+,
// 光爬就要 ~30 分,加上逐条试开 ~15 分,再加前面路由那一半 ~17 分 ≈ **65 分**。
// 于是那一跑会在干完前被 3600s 砍掉 —— 正是 GST-2 那次误杀的同一个形状:
// **上限是从"估的成本"推的,不是从"量的成本"推的**。第二跑上限 9000s。
// 【finance 的真数(本刀量的,2026-09-02)】`--reach=finance` 整跑
// **59 分 47 秒**(3587s;判词 REACHFIN2_EXIT=0),含前面路由那一半。
// 分解:路由 215 条 → 231 ok / 8 skipped / 0 FAILED;finance 走到 **457** 页、
// 试开 **145** 条静态路由、打得开 88 条、其中走不到 3(= EXPECTED_UNREACHABLE)。
// **前沿在爬的过程中从 191 一路涨到 457** —— 这正是 admin 那一跑撑爆 90 分钟的同一件事。
// 【所以:比例外推 ≠ 实测】admin 63 分、operations 17 分是 2026-08-11 量的,
// finance 59分47秒 是本刀量的。第四个角色要跑,去量它,别拿比例推。
//
// 【为什么不按阶段切(先全爬、再全试开)】那样切出来的两跑【谁都判不了】——
// 判据是 unreachable = openable − seen,而这两个集合必须来自【同一个角色的同一跑】。
// 按阶段切会得到两个永远不会红的半跑,那比不跑更坏。谁想"优化"成阶段切,先读这一段。
const ALL_REACH_ROLES = ['admin', 'operations', 'finance']
const reachFlag = process.argv.find((a) => a === '--reach' || a.startsWith('--reach='))
const reachRaw = reachFlag?.includes('=')
    ? reachFlag.slice('--reach='.length)
    : (reachFlag ? '1' : (process.env.SMOKE_REACH ?? ''))
// 【`--reach=` 后面空着是打错了,不是"不跑"】沉默地跳过一条你明明要求了的检查,
// 正是本文件反复记账的那种空过。而 SMOKE_REACH 的旧约定是 '1' 开、其余关 ——
// 保留它:0/false/空 一律当关,别让 SMOKE_REACH=0 变成"三个角色全跑"。
if (reachFlag?.includes('=') && reachRaw.trim() === '') {
    console.error('✗ --reach= 后面是空的 —— 要么写一个角色名(admin / operations / finance),'
        + '要么用不带 = 的 --reach 跑三个。空着不会被当成"不跑"。')
    process.exit(2)
}
const RUN_REACH = !['', '0', 'false', 'no'].includes(reachRaw.trim().toLowerCase())
// 【拼错的角色名必须响亮地死】否则它会跑零个角色然后打印一行绿 ——
// 那是本仓库反复付账的那种【空过】:检查什么都没验,判词却说通过了。
const REACH_ROLES = !RUN_REACH ? []
    : (reachRaw === '1' ? ALL_REACH_ROLES : reachRaw.split(',').map((s) => s.trim()).filter(Boolean))
for (const r of REACH_ROLES) {
    if (!ALL_REACH_ROLES.includes(r)) {
        console.error(`✗ --reach=${r}:不认识这个角色。可选:${ALL_REACH_ROLES.join(' / ')}`
            + '(不带 = 则三个全跑)。拼错的名字不会被当成"没有角色要跑"悄悄放过。')
        process.exit(2)
    }
}

// 打得开却走不到、而且【是有意如此】的静态路由。drift 两个方向都失败:
// 多出来的要么是真漏了入口,要么是这里该添一行并写明理由。
const EXPECTED_UNREACHABLE = {
    admin: new Set(['/login', '/set-password', '/welcome']),
    operations: new Set(['/login', '/set-password', '/welcome',
        // metal_prices 的【读】策略是 USING (true) —— 行情是市场报价,数据自己声明
        // 它公开(理由在 lib/modules.ts 的长注释里)。所以任何人都打得开这一页,
        // 而入口挂在 pricing 模块里,operations 没有那个模块 —— 于是"打得开却走不到"
        // 对他成立,并且【是有意的】。要改的是产品判断(该不该给非定价角色一个入口),
        // 不是这个检查。
        '/metal-prices']),
    finance: new Set(['/login', '/set-password', '/welcome']),
}

// 每个要跑的角色都必须有一条 EXPECTED_UNREACHABLE —— 缺了会在读 .has() 时
// 抛 undefined,而那是在【爬完几十分钟之后】才炸。能在开跑前回答的问题就在开跑前
// 回答(文件上方那条规矩,ID_SOURCES 预检付过一次账)。
for (const r of REACH_ROLES) {
    if (!EXPECTED_UNREACHABLE[r]) {
        console.error(`✗ --reach=${r}:EXPECTED_UNREACHABLE 里没有这个角色的条目 —— 先补一条再跑。`)
        process.exit(2)
    }
}

// 拒绝页认【机器标记】不认文案:refusal() 与 requireManagePermissions() 的外层 div
// 都带 data-access-denied="1"。首跑时这里是一串文案字符串,于是漏掉了权限管理页
// 那一种拒绝,把 /settings/permissions 报成了"打得开却走不到"—— 误报比漏报更坏,
// 它教人忽略这条检查。新增任何一种拒绝屏,只要复用那两个组件就自动被认出来。
const DENIED_MARK = 'data-access-denied'

function hrefsIn(html) {
    const out = new Set()
    for (const m of html.matchAll(/href="([^"]+)"/g)) {
        const h = m[1].split('?')[0].split('#')[0]
        if (h.startsWith('/') && !h.startsWith('//')) out.add(h.replace(/\/+$/, '') || '/')
    }
    return out
}

async function reachabilityForRole(roleCode, base, mkSession) {
    const cookie = await mkSession(roleCode)
    const get = async (path) => {
        const r = await fetch(base + path, { headers: { cookie }, redirect: 'manual' })
        const body = r.status === 200 ? await r.text() : ''
        // CSV 导出之类的 Route Handler 不是页面 —— 谈不上"有没有入口"
        const isHtml = (r.headers.get('content-type') ?? '').includes('text/html')
        return { status: r.status, body, isHtml }
    }

    // ① 从 / 出发,只跟着【真的渲染出来的】链接走
    //
    // 【逐条打印,这不是装饰】本段一个角色要抓 200~330 个页面、跑好几分钟,
    // 而它此前【整段沉默、只在角色跑完才吐一行】—— 于是"还在跑"与"已经挂了"
    // 在屏幕上长得一模一样,人就会去轮询日志(2026-08-10 就是这么绕开
    // db/wait_for.sh 的)。start-and-leave 这个用法【依赖日志自己回答"活着吗"】,
    // 所以逐条进度是它的前提条件,不是可有可无的体贴。
    const seen = new Set(['/'])
    const queue = ['/']
    let visited = 0
    while (queue.length) {
        const cur = queue.shift()
        visited++
        console.log(`  [${roleCode} 走 ${visited}/${seen.size}] ${cur}`)
        const { status, body } = await get(cur)
        if (status !== 200) continue
        if (body.includes(DENIED_MARK)) continue   // 进不去的页面不往下走
        for (const h of hrefsIn(body)) {
            if (!seen.has(h)) { seen.add(h); queue.push(h) }
        }
    }

    // ② 静态路由里,他【打得开】哪些(200 且不是拒绝页)
    const staticRoutes = routes.filter((r) => !r.includes('[') && !r.startsWith('/api'))
    const openable = []
    let scanned = 0
    for (const r of staticRoutes) {
        scanned++
        console.log(`  [${roleCode} 试开 ${scanned}/${staticRoutes.length}] ${r}`)
        const { status, body, isHtml } = await get(r)
        if (status === 200 && !body.includes(DENIED_MARK) && isHtml) openable.push(r)
    }

    // ③ 打得开却走不到
    const unreachable = openable.filter((r) => !seen.has(r))
    const dynamicCount = routes.length - staticRoutes.length
    return { role: roleCode, reached: seen.size, openable: openable.length, unreachable, dynamicCount }
}


// ── 开跑之前的静态预检:每条动态路由都取得到 id 吗 ──────────────────────────
//
// 【一条正确的检查放错了相位,就是一条慢检查】
// 2026-08-11:新加的 /finance/freight/[id] 没有 ID_SOURCES 映射,冒烟在【走了几分钟
// 之后】才中止。中止本身是对的(它拒绝把"没有映射"当成"没有数据"),但它回答的是
// 一个【静态】问题 —— 而那时 dev server 已经起来、会话已经建好、临时行已经扫过,
// 于是那次失败花掉的不只是时间,还有一轮清理,以及重跑那三十分钟。
// 同一个形状出现过两次:check_mirrors 把 14,000 行重放推过连接池(40+ 分钟、
// 死在 DNS 与套接字上),改成本地重建;--reach 曾经是默认,每次提交都要等它,
// 于是改成显式开启(一条慢到不能每次跑的检查,最后会变成从来不跑)。
// 【规矩】能在开跑前回答的问题,就在开跑前回答,而且在【还什么都没启动】的时候回答。
//
// 两个分支【分开报】,因为修法不同:
//   A 段在 ID_SOURCES 里、但没有前缀命中该路由 → srcs[undefined] → 响亮中止(上面那次)
//   B 段【压根不在】ID_SOURCES 里 → 循环不触发,字面量原样留在 URL 里去请求,
//     于是它【不中止】,而是在跑到一半时报成一次普通的路由失败 —— 看起来像页面坏了,
//     不像映射漏了,诊断起来严格地更糟。B 至今没有触发过,而这正是它值得被检查的理由。
function preflightIdSources(routes) {
    const idSegs = Object.keys(ID_SOURCES)
    const problems = []
    for (const route of routes.sort()) {
        const segs = route.match(/\[[a-zA-Z]+\]/g)
        if (!segs) continue
        // 这三类另有取 id 的路子,不走 ID_SOURCES
        if (STATUS_GUARDS[route] || SPECIAL_ID_ROUTES.has(route) || EXPECTED_SKIPS.has(route)) continue
        for (const seg of segs) {
            if (!idSegs.includes(seg)) {
                problems.push({ route, seg, branch: 'B' })
                continue
            }
            const srcs = ID_SOURCES[seg]
            const hit = Object.keys(srcs).some((p) => route.startsWith(p) || p === '')
            if (!hit) problems.push({ route, seg, branch: 'A' })
        }
    }
    if (problems.length === 0) return
    console.error(`\n✗ 预检不通过:${problems.length} 条动态路由取不到 id —— 【还没起 dev server,现在改还不费什么】`)
    for (const { route, seg, branch } of problems) {
        if (branch === 'A') {
            console.error(`  ✗ ${route}`)
            console.error(`      段 ${seg} 在 ID_SOURCES 里,但没有任何前缀命中这条路由 → srcs[undefined]`)
            console.error(`      修:往 ID_SOURCES['${seg}'] 加一条前缀 → 表名;或写进 EXPECTED_SKIPS(并说明为什么没数据)`)
        } else {
            console.error(`  ✗ ${route}`)
            console.error(`      段 ${seg} 【不在】 ID_SOURCES 里 —— 循环不会触发,字面量会原样进 URL,`)
            console.error(`      于是它不中止,而是跑到一半报成一次普通的路由失败(看起来像页面坏了)`)
            console.error(`      修:在 ID_SOURCES 里加 '${seg}' 这一段,给它前缀 → 表名`)
        }
    }
    process.exit(1)
}

async function main() {
    // FIX-3:整段冒烟期间持有 live-lock —— 它与 gate 共用同一把,
    // 于是"gate 在跑就别单独跑 check_mirrors"从一条要记住的规矩变成一道门。
    // 释放接在正常退出、异常与 SIGINT/SIGTERM 上(见 scripts/liveLock.mjs)。
    acquireOrExit('scripts/smoke-routes.mjs')
    const reachFailures = []
    // 【最先跑,而且在 sweepStalePort / next dev 之前】—— 见 preflightIdSources 抬头:
    // 这是一个静态问题,不该等到起了服务器、建了会话、扫过临时行之后才回答。
    PROGRESS.phase = '静态预检(ID_SOURCES)'
    preflightIdSources(routes)
    // 【临时行体检:报告,不动手】就在这里跑一次 —— 正要再造一批临时行之前,
    // 是最该知道"上一次留下了什么"的时刻。
    // 它【不中止冒烟】:滞留的临时行是家务,不是路由的正确性问题,
    // 而把家务做成拦路的门,只会让人学会跳过这道门(--reach 那一课)。
    try {
        const { execSync } = await import('node:child_process')
        execSync('node scripts/check-scratch-rows.mjs', { cwd: ROOT, stdio: 'inherit' })
    } catch {
        console.log('  (临时行体检报了滞留行 —— 见上;冒烟继续,处置由人决定)')
    }
    PROGRESS.phase = '清扫端口与临时行'
    sweepStalePort()   // 端口先扫:库里的行扫干净了,端口被占住照样开不了跑
    await sweepScratch()

    // ── 一次性 admin 会话 ────────────────────────────────────────────────────
    PROGRESS.phase = '建一次性会话'
    const stamp = Date.now()
    const email = `smoke-${stamp}@test.local`
    const cu = await (await restOk('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email, password: 'smoke-pass-1', email_confirm: true }) }, '建 admin 账号')).json()
    const roleRows = await restRows('/rest/v1/roles?select=id&code=eq.admin', 'roles ← admin')
    await restOk('/rest/v1/user_roles', { method: 'POST',
        body: JSON.stringify({ user_id: cu.id, role_id: roleRows[0].id }) }, '授 admin 角色')
    const adminSession = await signInSession(email, 'smoke-pass-1')
    const cookie = adminSession.cookie

    // ── 第二个一次性会话:评估人视角 ─────────────────────────────────────────
    // /my-reviews/[id] 对 admin 是 404 契约,等于那页从未真正渲染 —— 而它正是
    // 部门经理实际用的页。自己不能评自己(CHECK not_self_review),所以受评人、
    // 评估人两名临时员工;评估人不授任何角色:RLS 'select as reviewer' 只看
    // reviewer_employee_id,这同时也验证了"无角色的经理也能看自己的评估任务"。
    const email2 = `smoke-${stamp}-reviewer@test.local`
    const cu2 = await (await restOk('/auth/v1/admin/users', { method: 'POST',
        body: JSON.stringify({ email: email2, password: 'smoke-pass-2', email_confirm: true }) }, '建评估人账号')).json()
    const mkEmp = async (n, extra) => (await (await restOk('/rest/v1/employees', { method: 'POST',
        headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ code: `${SCRATCH_EMP_PREFIX}${n}`, legal_name: `${SCRATCH_NAME} ${n}`,
            employment_type: 'full_time', work_category: 'office', hire_date: '2026-01-01', ...extra }) },
        `建临时员工 ${n}`)).json())[0]
    // ★【PROBATION-1:这里【曾经】直接 POST 到 REST 造那一行评估】★
    // 那不是图省事 —— 当时【产品里没有任何一条路造得出一份试用期评估】:
    // open_review_cycle 只造 annual 且排除试用期员工,cycle_shape 让它结构上
    // 也造不出,app 里一处 INSERT performance_reviews 都没有。
    // **测试绕过产品,正是"产品没有那条路"最尖锐的证据** —— 而一个绕过产品的
    // 测试,产品坏掉时它不会知道。
    //
    // 现在它走 `open_probation_review`,也就是【屏幕上那个按钮按下去的同一支函数】。
    // 于是这一段从"造一行数据"变成了【一次真的端到端断言】:门在不在、
    // 期间取的是不是员工档案上的两个日期、评估人解不解析得出来。
    const reviewee = await mkEmp(1, {
        employment_status: 'probation',
        // 到期日必须填 —— 不填 open_probation_review 会按名拒(那是它的本分)。
        // 入职日在 mkEmp 里是 2026-01-01,而 employees_probation_cap 要求
        // 到期日 ≤ 入职 + 3 个月,所以取 03-31。
        probation_end_date: '2026-03-31',
    })
    const reviewer = await mkEmp(2, { user_id: cu2.id })

    // 【负臂先跑】一个没有到期日的人必须被【按名】拒。
    // 只跑正臂的话,一个"从不拒绝、缺日期就拿今天顶上"的实现照样全绿 ——
    // 而那正是这扇门最要防的那件事(替人编一个试用期终点)。
    const noDate = await mkEmp(3, { employment_status: 'probation' })
    const refused = await rpcAs(adminSession.token, 'open_probation_review', { p_employee_id: noDate.id })
    const refusedBody = await refused.text()
    if (refused.ok || !refusedBody.includes('PROBATION_END_DATE_NOT_SET')) {
        throw new Error(`open_probation_review 没有按名拒绝【缺到期日】的员工:`
            + `HTTP ${refused.status} ${refusedBody.slice(0, 200)}`)
    }

    // 【正臂】走产品自己的路造出那份评估
    const raisedRes = await rpcAs(adminSession.token, 'open_probation_review', { p_employee_id: reviewee.id })
    if (!raisedRes.ok) {
        throw new Error(`发起试用期评估失败:HTTP ${raisedRes.status} ${(await raisedRes.text()).slice(0, 300)}`)
    }
    const raised = await raisedRes.json()
    if (!raised?.review_id) {
        throw new Error(`open_probation_review 没有返回 review_id:${JSON.stringify(raised).slice(0, 200)}`)
    }
    if (raised.period_start !== '2026-01-01' || raised.period_end !== '2026-03-31') {
        throw new Error(`试用期评估的期间应当取自员工档案(2026-01-01 → 2026-03-31),`
            + `实得 ${raised.period_start} → ${raised.period_end}`)
    }
    // 评估人由函数从部门解析;这套临时员工没有部门,所以解析不出来是【预期】的,
    // 而 /my-reviews/[id] 那一页要的正是"这个人是评估人"。所以显式指派一次 ——
    // 走的仍是产品自己的那支函数(set_review_reviewer),不是直连改表。
    const assigned = await rpcAs(adminSession.token, 'set_review_reviewer',
        { p_review_id: raised.review_id, p_reviewer_employee_id: reviewer.id })
    if (!assigned.ok) {
        throw new Error(`指派评估人失败:HTTP ${assigned.status} ${(await assigned.text()).slice(0, 300)}`)
    }
    const review = { id: raised.review_id }
    const cookie2 = await signIn(email2, 'smoke-pass-2')

    // ── dev server ───────────────────────────────────────────────────────────
    const logChunks = []
    const dev = spawn('npx', ['next', 'dev', '-p', String(PORT)], { cwd: ROOT })
    dev.stdout.on('data', (d) => logChunks.push(d.toString()))
    dev.stderr.on('data', (d) => logChunks.push(d.toString()))
    // 【等待要有上限,而且到了上限要报名字】原先这里 for 60 次、每次 1 秒,
    // 到点【无论服务器起没起来都往下走】—— 服务器没起来时,后面 131 条路由
    // 全部连接失败,屏幕上是一百多条 fetch 错误,而真正的原因(dev server 没起来)
    // 一个字都没有。有上限不等于会报错:没有失败分支的等待,和没有上限的等待
    // 一样难查。同一形状让一个壳等过 2 小时 47 分钟,见 db/wait_for.sh 的抬头。
    const READY_TIMEOUT_MS = 90_000
    const readyStart = Date.now()
    let ready = false
    while (Date.now() - readyStart < READY_TIMEOUT_MS) {
        await new Promise((r) => setTimeout(r, 1000))
        if (logChunks.join('').includes('Ready in')) { ready = true; break }
        if (dev.exitCode !== null) break          // 进程死了就不必等满
    }
    if (!ready) {
        const why = dev.exitCode !== null
            ? `next dev 退出了(code ${dev.exitCode})`
            : `${Math.round((Date.now() - readyStart) / 1000)}s 内没有看到 "Ready in"`
        dev.kill()
        console.error(`✗ dev server 没起来:${why}`)
        console.error(logChunks.join('').split('\n').slice(-30).join('\n'))
        process.exit(1)
    }

    const failures = []
    let ok = 0
    // SESSION-1:认证够不着时【每一条】路由都会 503,于是失败清单会有一百多行,
    // 而它们说的是同一件事。总结那里要把它讲成一句,不是一百句。
    let sawAuthIndeterminate = false
    const skipped = new Set()
    const serverStack = async (before) => {
        await new Promise((r) => setTimeout(r, 500))
        const errLog = logChunks.slice(before).join('')
        return [...errLog.matchAll(/⨯[\s\S]{0,600}?digest[^\n]*\n?\}/g)].map((m) => m[0]).join('\n')
            || errLog.split('\n').filter((l) => /Error|error|⨯/.test(l)).slice(0, 8).join('\n')
    }
    try {
        PROGRESS.phase = '逐条走路由'
        for (const route of routes.sort()) {
            let url = route
            let skip = null
            // 父子路由的 id 必须【配套】:先取子行,再用它的外键定父段
            // (assay_results 也有 deleted_at —— 不过滤的话,软删行 404 会在
            // 已经烧过一次的这条路由上原样复发)
            // PROC-1:化验有两种父,这条路由只认进料父 —— 不过滤的话,取到一份
            // 产出化验就把字面量 "null" 塞进 [id] 段,报成一次普通路由失败
            if (route === '/inbound/[id]/assays/[assayId]') {
                const rows = await restRows(
                    '/rest/v1/assay_results?select=id,inbound_batch_id&deleted_at=is.null&inbound_batch_id=not.is.null&limit=1',
                    `${route} ← assay_results`)
                if (!rows[0]) { skipped.add(route); console.log(`  SKIP ${route}  (no data in assay_results)`); continue }
                url = route.replace('[id]', rows[0].inbound_batch_id).replace('[assayId]', rows[0].id)
            }
            // PROC-1b:产出化验 —— 同一张表的另一个父;不按父过滤就会把另一侧的
            // NULL 当成 id 塞进段里(与上面那条互为镜像)
            if (route === '/output/[id]/assays/[assayId]') {
                const rows = await restRows(
                    '/rest/v1/assay_results?select=id,output_batch_id&deleted_at=is.null&output_batch_id=not.is.null&limit=1',
                    `${route} ← assay_results`)
                if (!rows[0]) { skipped.add(route); console.log(`  SKIP ${route}  (no data in assay_results)`); continue }
                url = route.replace('[id]', rows[0].output_batch_id).replace('[assayId]', rows[0].id)
            }
            // FIN-DRILL:科目明细 —— 段是科目号,而且要一个【有分录】的科目。
            // 从 journal_lines 反查,拿到的科目按构造至少有一行明细。
            if (route === '/finance/ledger/[account]') {
                const rows = await restRows(
                    '/rest/v1/journal_lines?select=accounts(code)&limit=1',
                    `${route} ← journal_lines`)
                const code = rows[0]?.accounts?.code
                if (!code) { skipped.add(route); console.log(`  SKIP ${route}  (no data in journal_lines)`); continue }
                // 资产负债表口径(累计、含年结)—— 与它的入口链接同形
                url = `${route.replace('[account]', encodeURIComponent(code))}?mode=bs`
            }
            // IMPORT-1:模板路由 —— 段是表名,不是 id。用一个固定的、一定存在的表。
            if (route === '/settings/import/template/[table]') {
                url = route.replace('[table]', 'suppliers')
            }
            // 状态门路由:取同一行的 id 和 status,预期值算出来、精确断言
            let exact = null
            const guard = STATUS_GUARDS[route]
            if (guard) {
                const rows = await restRows(
                    `/rest/v1/${guard.table}?select=id,status&deleted_at=is.null&limit=1`,
                    `${route} ← ${guard.table}`)
                if (!rows[0]) { skipped.add(route); console.log(`  SKIP ${route}  (no data in ${guard.table})`); continue }
                url = route.replace('[id]', rows[0].id)
                exact = [guard.redirects(rows[0].status) ? 307 : 200]
            }
            for (const [seg, srcs] of Object.entries(ID_SOURCES)) {
                if (!url.includes(seg)) continue
                const prefix = Object.keys(srcs).filter((p) => route.startsWith(p) || p === '')
                    .sort((a, b) => b.length - a.length)[0]
                const id = await firstId(srcs[prefix], route)
                if (!id) { skip = `no data in ${srcs[prefix]}`; break }
                url = url.replace(seg, id)
            }
            if (skip) { skipped.add(route); PROGRESS.skipped.push(route); console.log(`  SKIP ${route}  (${skip})`); continue }
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}${url}`, {
                headers: { cookie }, redirect: 'manual' })
            const allow = EXPECTED[route] ?? []
            const pass = exact ? exact.includes(res.status)
                : (res.status >= 200 && res.status < 300) || allow.includes(res.status)
            // 【内容断言在状态码之后跑】只有 2xx 的页面才谈得上"内容对不对";
            // 一个 500 已经失败了,再报一次内容缺失只是噪音。
            let contentMiss = null
            if (pass && MUST_CONTAIN[route]) {
                const missing = await contentMisses(route, await res.text())
                if (missing.length) contentMiss = missing.join(' | ')
            }
            if (pass && !contentMiss) { ok++; PROGRESS.ok.push(route) }
            else if (contentMiss) {
                PROGRESS.failed.push(`${route} → 200 但内容缺失:${contentMiss}`)
                failures.push({ route, url, status: res.status, expected: exact?.[0],
                    stack: `内容断言未通过:${contentMiss}` })
                console.log(`  FAIL ${route} → 200 但内容缺失:${contentMiss}`)
            }
            else {
                // 【一次正确的红,也可能把人送去找错东西】(SESSION-1,2026-08-23)
                // 中间件在【判断不出会话】时回 503 + data-auth-indeterminate(它拒绝
                // 把"问不到答案"说成"你没登录",见 lib/supabase/middleware.ts)。
                // 那个 503 让本脚本变红,而那是【对的】—— 那时确实有东西坏了。
                // 但屏幕上它与"这一页崩了"长得一模一样,于是读的人会去查这一刀改了什么。
                // **一次把人送去打猎的正确的红,花掉的时间与一次错误的红一样多。**
                // 所以这一行当场点名:坏的是认证,不是这一页。
                const authDown = res.status === 503
                    && (await res.clone().text()).includes('data-auth-indeterminate')
                const tag = authDown ? '  ←【认证够不着,不是这一页坏了】' : ''
                if (authDown) sawAuthIndeterminate = true
                PROGRESS.failed.push(`${route} → ${res.status}${exact ? ` (expected ${exact[0]})` : ''}${tag}`)
                failures.push({ route, url, status: res.status, authDown,
                    expected: exact?.[0], stack: await serverStack(before) })
                console.log(`  FAIL ${route} → ${res.status}${exact ? ` (expected ${exact[0]})` : ''}${tag}`)
            }
        }

        // ════════════════════════════════════════════════════════════════
        // ★【带查询串的探针 —— 本脚本此前【从不发查询串】】★(GST-FIX-1,2026-08-26)
        //
        // 上面那个主循环只 GET 光秃秃的路由路径。于是**任何住在查询参数后面的
        // 行为,对每一次跑(过去的和将来的)都是结构性不可见的** —— 不是没测到,
        // 是这台机器没有那个器官。
        //
        // 【它藏住了什么】F5 的钻取整个住在 ?box= 后面。GST-2 把它从"钻回分录"
        // 改成"钻回单据"(换了返回类型、换了列名、换了整段渲染),而那一改
        // 【没有任何自动检查看得见】—— 同一页又恰好因为线上没有 gst_periods 行
        // 而一直被跳过。两个盲区叠在一起,一直到人手走查才被发现。
        //
        // 【断言的是"那一段在不在",不是"好不好看"】data-box-detail 是页面上
        // 专门给这里留的机器标记;data-box-detail-error 出现则说明 RPC 炸了。
        // ════════════════════════════════════════════════════════════════
        for (const probe of QUERY_PROBES) {
            const target = await probe.resolve()
            if (!target) {
                // 【找不到可断言的数据 = 失败,不是跳过】这一条是 GST-FIX-2 的全部教训:
                // 第一版在这里会安静地变绿,而它证明的只是"空集里没有东西"。
                PROGRESS.failed.push(`${probe.name} → 找不到【非空】的格可断言`)
                failures.push({ route: probe.name, url: '-', status: 0,
                    stack: '找不到一张【在册的、带 SR 税码、落在某个 GST 期间里】的发票 —— '
                         + '于是这条探针没有可断言的非空对象。**这不是通过。** '
                         + '一个对着空集变绿的断言什么都没证明(GST-FIX-2)。' })
                console.log(`  FAIL ${probe.name}  (找不到非空的格 —— 这不是通过)`)
                continue
            }
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}${target.url}`, { headers: { cookie }, redirect: 'manual' })
            const body = res.status >= 200 && res.status < 300 ? await res.text() : ''
            const hasCode = body.includes(target.invoiceCode)
            const hasBad = body.includes(probe.mustNot)
            if (res.status >= 200 && res.status < 300 && hasCode && !hasBad) {
                ok++
                console.log(`  ok   ${target.url}  (钻取列出了 ${target.invoiceCode})`)
            } else {
                const why = res.status < 200 || res.status >= 300 ? `HTTP ${res.status}`
                    : hasBad ? `钻取报错(${probe.mustNot})`
                    : `钻取里没有 ${target.invoiceCode} —— 而那一格【不是空的】`
                PROGRESS.failed.push(`${probe.name} → ${why}`)
                failures.push({ route: probe.name, url: target.url, status: res.status,
                    stack: `带查询串的探针未通过:${why}\n${await serverStack(before)}` })
                console.log(`  FAIL ${target.url} → ${why}`)
            }
        }

        // ── 评估人视角:以真正的评估人会话请求 /my-reviews/[id],精确 200 ——
        // 404 意味着守卫误伤、RLS 收紧过头或会话装配坏了,而 admin 那一遍看不见
        {
            const target = `/my-reviews/${review.id}`
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}${target}`, {
                headers: { cookie: cookie2 }, redirect: 'manual' })
            if (res.status === 200) { ok++ }
            else {
                failures.push({ route: '/my-reviews/[id] (as reviewer)', url: target,
                    status: res.status, expected: 200, stack: await serverStack(before) })
                console.log(`  FAIL /my-reviews/[id] (as reviewer) → ${res.status} (expected 200)`)
            }
        }

        // ── LOGIN-1-fu1:【没有会话】时登录页仍然画得出表单,而且没有应用外壳 ──
        // 【为什么这条必须存在】上面 EXPECTED 把 /login 钉成了 307,而那是【带会话】
        // 的答案。登录页真正的观众是【没有会话】的人,那一半状态门一个字都说不上。
        // 少了这条探针,一个彻底坏掉的登录页(500、空白、或者把所有人都重定向走)
        // 照样能让整轮冒烟绿着 —— 而它是十三个账号见到的第一屏。
        //
        // 三件事一起断言,因为它们分别对应三种坏法:
        //   ① 200 + 有 password 输入框 —— 页面还在,表单还在;
        //   ② 【没有】 <header> —— 应用外壳不该套在"还没进系统"那一屏上;
        //   ③ 干净来访【什么都不说】—— SESSION-1 那条刻意的沉默没有被弄丢。
        {
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}/login`, { redirect: 'manual' })
            const html = res.status === 200 ? await res.text() : ''
            const hasForm = /name="password"/.test(html)
            const hasChrome = /<header/.test(html)
            const silent = html.includes('data-login-state="clean"') && !/role="alert"/.test(html)
            if (res.status === 200 && hasForm && !hasChrome && silent) { ok++ }
            else {
                const why = res.status !== 200 ? `HTTP ${res.status}(无会话时应当是 200)`
                    : !hasForm ? '页面里没有密码输入框 —— 登录表单没画出来'
                    : hasChrome ? '登录页上出现了应用外壳(<header>)'
                    : '干净来访不再是"什么都不说"(SESSION-1 的沉默丢了)'
                PROGRESS.failed.push(`/login (no session) → ${why}`)
                failures.push({ route: '/login (no session)', url: '/login',
                    status: res.status, expected: 200,
                    stack: `无会话登录页探针未通过:${why}\n${await serverStack(before)}` })
                console.log(`  FAIL /login (no session) → ${why}`)
            }
        }

        // ── PROBATION-1:那扇门【真的画在屏幕上】,不只是路由 200 ────────────
        // 【为什么这条断言值得存在】这一刀的全部内容就是"一条路没有入口"。
        // 而路由冒烟只断言 2xx —— 一张【渲染成功但按钮没画出来】的页面照样 200。
        // 员工页那一节原本包在 `{empReviews.length > 0 && ...}` 里,
        // 也就是说【一份评估都没有时整节不渲染】,而那正是唯一需要这扇门的时候:
        // **那个 length > 0 本身就是这扇门缺席的一部分。**
        // 所以这里请求一个【在试用期、有到期日、且此刻已经有一份评估】的员工页,
        // 以及一个【在试用期、没有任何评估】的员工页,两边都必须看得见那个按钮。
        // 这就是 AGENTS.md 说的「[id] 页要人手确认入口」那一条,做成了机制。
        {
            // 两个分支各断言一次:
            //   · 有到期日 → 那个【按钮】必须在;
            //   · 没有到期日 → 必须是一句【说得出为什么】的话,而不是一个变灰的按钮,
            //     也不是一片空白(命名的缺席,不是空白)。
            const cases = [
                ['有到期日 → 按钮在', reviewee.id, MSG_RAISE_PROBATION],
                ['无到期日 → 说得出为什么', noDate.id, MSG_RAISE_BLOCKED],
            ]
            for (const [who, empId, needle] of cases) {
                const target = `/hr/employees/${empId}`
                const before = logChunks.length
                const res = await fetch(`http://localhost:${PORT}${target}`, {
                    headers: { cookie }, redirect: 'manual' })
                const html = res.status === 200 ? await res.text() : ''
                if (res.status === 200 && html.includes(needle)) { ok++ }
                else {
                    const why = res.status !== 200
                        ? `HTTP ${res.status}`
                        : `页面 200,但找不到「${needle}」—— 入口又没了,而 200 看不出这件事`
                    failures.push({ route: `/hr/employees/[id] (试用期入口 · ${who})`, url: target,
                        status: res.status, expected: 200, stack: `${why}\n${await serverStack(before)}` })
                    console.log(`  FAIL /hr/employees/[id] 试用期入口(${who}) → ${why}`)
                }
            }
        }

        // ── STATEMENT-1:对账单那扇门【真的画在客户档案页上】────────────────
        // 【为什么这条断言值得存在,逐字同 PROBATION-1 那一条】
        // 这一刀的正文是一个【区间的计算结果】,它不挂在任何一条既有单据上 ——
        // 也就是说这条路的入口是【发明出来的】,而不是从哪里长出来的。
        // 路由冒烟只断言 2xx,一张【渲染成功但那一节没画出来】的客户页照样 200;
        // 而 --reach 那一半对 [id] 页结构性地失明(AGENTS.md 已经为此记过一次账:
        // SAL-B6 的客户页当初就是【一个入口都没有】地上了线,检查报的是绿)。
        // 所以这里请求一个【真的客户】的档案页,断言那一段的标题印在 HTML 里。
        {
            const rows = await restRows(
                '/rest/v1/customers?select=id&deleted_at=is.null&order=created_at.asc&limit=1',
                'customers ← 对账单入口')
            // 【空集不是"还没到"】没有客户 = 这条断言【问不出来】,不是它通过了。
            if (rows.length === 0) {
                throw new Error('线上一个未删除的客户都没有 —— 对账单入口这条断言无从下手。'
                    + '这不是"没数据所以跳过":这条断言的主语不见了,而它守的正是那一页。')
            }
            const custId = rows[0].id
            const target = `/customers/${custId}`
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}${target}`, {
                headers: { cookie }, redirect: 'manual' })
            const html = res.status === 200 ? await res.text() : ''
            // CHASE-1:同一次渲染回答【两个】入口问题 —— 对账单那一段与催收那一段。
            // 分两次请求要多付一次服务端渲染,而它们问的是同一页上的同一件事:
            // 这一页上该有的门,还在不在。
            const needles = [
                ['对账单入口', MSG_STATEMENT_SECTION],
                ['催收入口',   MSG_CHASE_SECTION],
            ]
            for (const [what, needle] of needles) {
                if (res.status === 200 && html.includes(needle)) { ok++ }
                else {
                    const why = res.status !== 200
                        ? `HTTP ${res.status}`
                        : `页面 200,但找不到「${needle}」—— 入口没了,而 200 看不出这件事`
                    failures.push({ route: `/customers/[id] (${what})`, url: target,
                        status: res.status, expected: 200, stack: `${why}\n${await serverStack(before)}` })
                    console.log(`  FAIL /customers/[id] ${what} → ${why}`)
                }
            }
        }

        // ── CASHFLOW-1：现金预测页【真的画出来了】，而且它的标题在 ──────────
        // 【为什么值得一条内容断言】这是一张新页面，而路由冒烟只断言 2xx ——
        // 一张渲染成功但内容没画出来的页面照样 200。这一页的内容全部来自一支
        // 新函数（cash_forecast_data）：它抛错，页面 500（冒烟抓得住）；
        // 它返回一个形状不对的东西，页面渲染成一片空白而仍然 200（只有这条抓得住）。
        {
            const target = '/finance/cash-forecast'
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}${target}`, {
                headers: { cookie }, redirect: 'manual' })
            const html = res.status === 200 ? await res.text() : ''
            // ★【可达性：直接问那一页的 HTML 里有没有这条链接】★
            // --reach 会回答同一个问题，但它要两小时以上（本机隧道退化时实测），
            // 而且它是 opt-in 的 —— 一条每一跑都在的断言，比一次偶尔跑的走查更能
            // 守住「页面上线却走不到」这件事（这个仓库为它付过两次账）。
            const navRes = await fetch(`http://localhost:${PORT}/finance`, {
                headers: { cookie }, redirect: 'manual' })
            const navHtml = navRes.status === 200 ? await navRes.text() : ''
            if (!navHtml.includes('/finance/cash-forecast')) {
                failures.push({ route: '/finance (子导航里没有现金预测)', url: '/finance',
                    status: navRes.status, expected: 200,
                    stack: '财务子导航的 HTML 里找不到 /finance/cash-forecast —— '
                         + '这一页打得开却走不到,而这正是本仓库上过两次当的那件事。'
                         + 'Subnav.tsx 里有【两份】清单(ITEMS 与 ordered),两份都要有。' })
                console.log('  FAIL /finance 子导航里没有现金预测的入口')
            } else { ok++ }

            if (res.status === 200 && html.includes(MSG_FORECAST_TITLE)) { ok++ }
            else {
                const why = res.status !== 200
                    ? `HTTP ${res.status}`
                    : `页面 200，但找不到「${MSG_FORECAST_TITLE}」—— 预测没画出来，而 200 看不出这件事`
                failures.push({ route: '/finance/cash-forecast (内容)', url: target,
                    status: res.status, expected: 200, stack: `${why}\n${await serverStack(before)}` })
                console.log(`  FAIL /finance/cash-forecast 内容 → ${why}`)
            }
        }

        // ── EQP-PAY-1:设备单上,质保金那一栏【说了话】────────────────────
        // ★【为什么这条断言值得存在】★ 「没有质保金」与「0% 质保金」是两个不同的
        //   事实。库里那一半已经是结构性的(0% 存不进去);而屏幕这一半是**一句话**,
        //   而一句话消失了【不会有任何东西变红】—— 页面照样 200,只是那一栏变成空白,
        //   而空白读起来像"还没填"。这正是本仓库反复付账的那种缺陷。
        //
        // 【为什么不写进 MUST_CONTAIN】那张表按【路由】给针,而 /purchasing/orders/[id]
        //   的 id 是从库里随手挑的一张单 —— 挑到材料单时这一栏【正当地】不出现。
        //   所以这里自己按条件挑:那张【带设备行】的单。
        // 【零行也要具名】线上没有设备单时跳过而不是变绿 —— 一个没有主语的断言
        //   恒真,而恒真的断言与不存在的断言一样(README 那条"空集不是通过")。
        {
            const eqpLines = await restRows(
                '/rest/v1/purchase_order_lines?select=purchase_order_id&asset_id=not.is.null&limit=1',
                'EQP-PAY-1 设备单')
            if (eqpLines.length === 0) {
                console.log('  SKIP 质保金栏内容断言(线上没有任何设备采购单)')
                skipped.add('/purchasing/orders/[id] (retention)')
            } else {
                const poId = eqpLines[0].purchase_order_id
                // 这张单今天有没有质保金 —— 断言要跟着事实走,不是跟着今天的样子写死。
                const rets = await restRows(
                    `/rest/v1/purchase_order_line_retentions?select=id&purchase_order_line_id=in.(${
                        (await restRows(`/rest/v1/purchase_order_lines?select=id&purchase_order_id=eq.${poId}`,
                            'EQP-PAY-1 设备单的行')).map((r) => r.id).join(',')})`,
                    'EQP-PAY-1 质保金行')
                const target = `/purchasing/orders/${poId}`
                const before = logChunks.length
                const res = await fetch(`http://localhost:${PORT}${target}`, {
                    headers: { cookie }, redirect: 'manual' })
                const html = res.status === 200 ? await res.text() : ''
                // 没有质保金 → 必须印那一句明说的话;有质保金 → 必须印标题。
                const needle = rets.length === 0 ? MSG_RETENTION_NONE : MSG_RETENTION_TITLE
                if (res.status === 200 && html.includes(needle)) { ok++ }
                else {
                    const why = res.status !== 200
                        ? `HTTP ${res.status}`
                        : `页面 200,但找不到「${needle}」—— 质保金那一栏没有说话。`
                          + (rets.length === 0
                             ? '一片空白读起来是"还没填",而事实是"这张单没有质保金条款"'
                             : '这张单有质保金,而那一栏没画出来')
                    failures.push({ route: '/purchasing/orders/[id] (质保金栏)', url: target,
                        status: res.status, expected: 200, stack: `${why}\n${await serverStack(before)}` })
                    console.log(`  FAIL 质保金栏内容 → ${why}`)
                }
            }
        }

        // ── PARTY-1:重叠报告【走得到吗】────────────────────────────────
        // ★【这一条是把"我记得加了链接"换成一条机制】★
        //   `/customers/overlap` 是一条【静态】路由,`--reach` 查得到它 ——
        //   但 --reach 要跑两个多小时,而这件事本仓库已经付过两次账
        //   (SAL-B6 的客户详情页、FIX-1 的入库收货,两次都是人点出来的)。
        //   实测:这一页写完时【一个入口都没有】,是收尾时按名查出来的。
        //   一条每一跑都在的断言,比一次偶尔跑的走查更守得住这件事。
        {
            const before = logChunks.length
            const listRes = await fetch(`http://localhost:${PORT}/customers`, {
                headers: { cookie }, redirect: 'manual' })
            const listHtml = listRes.status === 200 ? await listRes.text() : ''
            if (listHtml.includes('/customers/overlap')) { ok++ }
            else {
                failures.push({ route: '/customers (没有重叠报告的入口)', url: '/customers',
                    status: listRes.status, expected: 200,
                    stack: '客户列表的 HTML 里找不到 /customers/overlap —— '
                         + '那一页打得开却走不到,而这正是本仓库上过两次当的那件事。\n'
                         + await serverStack(before) })
                console.log('  FAIL /customers 上没有重叠报告的入口')
            }
        }

        // ── CLAIM-1：两个听众，两条内容断言，外加一条可达性断言 ──────────
        // 【为什么不只断言 2xx】审批页与自助面板的内容都来自新对象；
        // 它们抛错页面 500（冒烟抓得住），返回形状不对则渲染成一片空白
        // 而仍然 200（只有内容断言抓得住）。
        {
            // ★【/me 必须用【绑了员工】的那个会话去问】★
            // /me 在会话用户没有员工档案时【提前返回】一句"还没关联到员工"的提示，
            // 于是那一页上的面板【一个都不渲染】—— 包括本来就有的医疗报销那一块。
            // 冒烟那个一次性 admin 没有员工档案，所以用它去断言自助面板，
            // 问的是一个那个会话【答不出来】的问题（第一版就是这么红的，
            // 而红得对：它告诉我断言站错了人）。评估人会话(cookie2)绑着一名
            // 临时员工，正是这条断言需要的主语。
            const targets = [
                ['/finance/claims', MSG_CLAIMS_TITLE, '审批页',   cookie],
                ['/me',             MSG_MY_CLAIMS,    '自助面板', cookie2],
            ]
            for (const [target, needle, what, ck] of targets) {
                const before = logChunks.length
                const res = await fetch(`http://localhost:${PORT}${target}`, {
                    headers: { cookie: ck }, redirect: 'manual' })
                const html = res.status === 200 ? await res.text() : ''
                if (res.status === 200 && html.includes(needle)) { ok++ }
                else {
                    const why = res.status !== 200
                        ? `HTTP ${res.status}`
                        : `页面 200，但找不到「${needle}」—— ${what}没画出来，而 200 看不出这件事`
                    failures.push({ route: `${target} (CLAIM-1 ${what})`, url: target,
                        status: res.status, expected: 200, stack: `${why}\n${await serverStack(before)}` })
                    console.log(`  FAIL ${target} CLAIM-1 ${what} → ${why}`)
                }
            }
            // 【可达性：直接问财务页的 HTML 里有没有这条链接】
            // --reach 回答同一个问题，但它要两小时以上且是 opt-in 的；
            // 一条每一跑都在的断言更能守住「页面上线却走不到」（本仓库栽过两次）。
            const navRes = await fetch(`http://localhost:${PORT}/finance`, {
                headers: { cookie }, redirect: 'manual' })
            const navHtml = navRes.status === 200 ? await navRes.text() : ''
            if (!navHtml.includes('/finance/claims')) {
                failures.push({ route: '/finance (子导航里没有报销)', url: '/finance',
                    status: navRes.status, expected: 200,
                    stack: '财务子导航的 HTML 里找不到 /finance/claims —— 这一页打得开却走不到。'
                         + 'Subnav.tsx 里有【两份】清单(ITEMS 与 ordered),两份都要有。' })
                console.log('  FAIL /finance 子导航里没有报销的入口')
            } else { ok++ }
        }

        // ── ATTEND-1：两个听众，两条内容断言，外加一条可达性断言 ──────────
        // 【它跑在零行数据上，而这是被承认的一半】线上一个考勤期间都没有，
        // 所以这里守住的是「两页画得出来、走得到」，**不是**「表格里的数字对」——
        // 后者由 fixture 141 的十二条臂与 14 格故障注入守。
        // 【/hr/attendance/[id] 这一跑够不着】没有期间就没有 id，而冒烟不会
        //  在线上建一个。AGENTS.md 已经为「--reach 对 [id] 页结构性失明」记过账，
        //  这里是同一个洞的同一侧，照直写出来而不是假装覆盖到了。
        {
            const targets = [
                ['/hr/attendance', MSG_ATTENDANCE_SUB,  '考勤底稿页', cookie],
                ['/me',            MSG_MY_ATTENDANCE,   '自助面板',   cookie2],
            ]
            for (const [target, needle, what, ck] of targets) {
                const before = logChunks.length
                const res = await fetch(`http://localhost:${PORT}${target}`, {
                    headers: { cookie: ck }, redirect: 'manual' })
                const html = res.status === 200 ? await res.text() : ''
                if (res.status === 200 && html.includes(needle)) { ok++ }
                else {
                    const why = res.status !== 200
                        ? `HTTP ${res.status}`
                        : `页面 200，但找不到「${needle}」—— ${what}没画出来，而 200 看不出这件事`
                    failures.push({ route: `${target} (ATTEND-1 ${what})`, url: target,
                        status: res.status, expected: 200, stack: `${why}\n${await serverStack(before)}` })
                    console.log(`  FAIL ${target} ATTEND-1 ${what} → ${why}`)
                }
            }
            // 【可达性：直接问 HR 页的 HTML 里有没有这条链接】
            const navRes = await fetch(`http://localhost:${PORT}/hr`, {
                headers: { cookie }, redirect: 'manual' })
            const navHtml = navRes.status === 200 ? await navRes.text() : ''
            if (!navHtml.includes('/hr/attendance')) {
                failures.push({ route: '/hr (子导航里没有考勤)', url: '/hr',
                    status: navRes.status, expected: 200,
                    stack: 'HR 子导航的 HTML 里找不到 /hr/attendance —— 这一页打得开却走不到,'
                         + '而这正是本仓库上过两次当的那件事。' })
                console.log('  FAIL /hr 子导航里没有考勤的入口')
            } else { ok++ }

        // ── WHT-1：预提税页的两条内容断言 + 一条可达性断言 ──────────────────
        // 【为什么是两条】第一条问「这一页画出来了吗」，第二条问「它说的是
        //  那句具名的缺席，还是一张空表」。第二条是 4.2 的执行者:一张什么都
        //  不说的空表与一张坏掉的页面在屏幕上是同一样东西。
        {
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}/finance/wht`, {
                headers: { cookie }, redirect: 'manual' })
            const html = res.status === 200 ? await res.text() : ''
            for (const [needle, what] of [
                [MSG_WHT_SUB,  '预提税页'],
                [MSG_WHT_NONE, '「还没有代扣过任何税」那句具名的缺席'],
            ]) {
                if (res.status === 200 && html.includes(needle)) { ok++ }
                else {
                    const why = res.status !== 200
                        ? `HTTP ${res.status}`
                        : `页面 200，但找不到「${needle}」—— ${what}没画出来，而 200 看不出这件事`
                    failures.push({ route: `/finance/wht (WHT-1 ${what})`, url: '/finance/wht',
                        status: res.status, expected: 200, stack: `${why}\n${await serverStack(before)}` })
                    console.log(`  FAIL /finance/wht WHT-1 ${what} → ${why}`)
                }
            }
            // 【可达性：财务子导航的 HTML 里有没有这条链接】
            // 一个没有入口的页面，路由冒烟照样 200(SAL-B6 的客户页就是这么无门上线的)。
            const navRes = await fetch(`http://localhost:${PORT}/finance`, {
                headers: { cookie }, redirect: 'manual' })
            const navHtml = navRes.status === 200 ? await navRes.text() : ''
            if (!navHtml.includes('/finance/wht')) {
                failures.push({ route: '/finance (子导航里没有预提税)', url: '/finance',
                    status: navRes.status, expected: 200,
                    stack: '财务子导航的 HTML 里找不到 /finance/wht —— 这一页打得开却走不到。'
                         + 'Subnav.tsx 里有【两份】清单(ITEMS 与 ordered),两份都要有。' })
                console.log('  FAIL /finance 子导航里没有预提税的入口')
            } else { ok++ }
        }

        // ── GLEXPORT-1：报表包两条内容断言 + 两条可达性断言 ──────────────────
        // 【为什么两条内容】第一条问「这一页画出来了吗」，第二条问「它有没有说出
        //  存档的含义」—— 后者是这一刀的裁定,而一个没有把裁定说出来的页面,
        //  会让人以为存下来的包和预览是同一种东西。
        {
            const before = logChunks.length
            const res = await fetch(`http://localhost:${PORT}/finance/packs`, {
                headers: { cookie }, redirect: 'manual' })
            const html = res.status === 200 ? await res.text() : ''
            for (const [needle, what] of [
                [MSG_PACK_SUB,           '报表包页'],
                [MSG_PACK_STORED_MEANS,  '「一份存档的包意味着那个月当时已经关账」那句裁定'],
            ]) {
                if (res.status === 200 && html.includes(needle)) { ok++ }
                else {
                    const why = res.status !== 200
                        ? `HTTP ${res.status}`
                        : `页面 200，但找不到「${needle}」—— ${what}没画出来，而 200 看不出这件事`
                    failures.push({ route: `/finance/packs (GLEXPORT-1 ${what})`, url: '/finance/packs',
                        status: res.status, expected: 200, stack: `${why}\n${await serverStack(before)}` })
                    console.log(`  FAIL /finance/packs GLEXPORT-1 ${what} → ${why}`)
                }
            }
            // 【可达性①：财务子导航里有没有报表包】
            const navRes = await fetch(`http://localhost:${PORT}/finance`, {
                headers: { cookie }, redirect: 'manual' })
            const navHtml = navRes.status === 200 ? await navRes.text() : ''
            if (!navHtml.includes('/finance/packs')) {
                failures.push({ route: '/finance (子导航里没有报表包)', url: '/finance',
                    status: navRes.status, expected: 200,
                    stack: '财务子导航的 HTML 里找不到 /finance/packs —— 这一页打得开却走不到。'
                         + 'Subnav.tsx 里有【两份】清单(ITEMS 与 ordered),两份都要有。' })
                console.log('  FAIL /finance 子导航里没有报表包的入口')
            } else { ok++ }
            // ★【可达性②：总账导出的入口】★ 导出是一条 Route Handler,
            //   它【永远】不会出现在路由冒烟的 2xx 名单里以外的任何地方 ——
            //   一条没有入口的导出路由,冒烟照样绿。所以这里直接问分录页的 HTML:
            //   带着日期区间时,那个链接在不在。
            //   (不带区间时页面故意不给链接、而是说出为什么,所以这里必须带上区间。)
            const jRes = await fetch(
                `http://localhost:${PORT}/finance/journal?date_from=2026-07-01&date_to=2026-07-31`,
                { headers: { cookie }, redirect: 'manual' })
            const jHtml = jRes.status === 200 ? await jRes.text() : ''
            // ★【判据在 & 之前收尾 —— 服务端渲染把 & 转义成 &amp;】★
            //   第一版写的是完整 URL(...from=2026-07-01&to=2026-07-31),
            //   而 HTML 属性里它是 ...from=2026-07-01&amp;to=2026-07-31 ——
            //   于是这条断言【永远不可能成立】,红的是判据不是页面。
            //   一个永远满足不了的判据是坏判据(smoke 自己为 name="supplier_id"
            //   那次记过同一条)。收尾在 & 之前,既够唯一又与转义无关。
            if (!jHtml.includes('/finance/journal/export?from=2026-07-01')) {
                failures.push({ route: '/finance/journal (没有总账导出的入口)', url: '/finance/journal',
                    status: jRes.status, expected: 200,
                    stack: '分录页筛了日期区间,而 HTML 里找不到那条导出链接 —— '
                         + '导出路由因此无门可走,而路由冒烟对这种情况是绿的(SAL-B6 / FRT-FIX 的形状)。' })
                console.log('  FAIL /finance/journal 没有总账导出的入口')
            } else { ok++ }
        }
        }

        // ── 按角色的可达性(REACH-1)────────────────────────────────────────
        // admin 一遍是对照(他什么都有);operations 与 finance 是 /margin 那道题的
        // 两边 —— 一个只有加工、一个只有财务,而没有任何 live 角色同时持有两者。
        const reachUsers = []
        if (RUN_REACH) console.log(`\n== 按角色的可达性(打得开却走不到)· 本跑 ${REACH_ROLES.length} 个角色:${REACH_ROLES.join('、')} ==`)
        const mkSession = async (roleCode) => {
            const em = `smoke-${stamp}-${roleCode}@test.local`
            const u = await (await restOk('/auth/v1/admin/users', { method: 'POST',
                body: JSON.stringify({ email: em, password: 'smoke-pass-3', email_confirm: true }) },
                `建 ${roleCode} 账号`)).json()
            const rr = await restRows(`/rest/v1/roles?select=id&code=eq.${roleCode}`, `roles ← ${roleCode}`)
            if (!rr.length) throw new Error(`角色 ${roleCode} 不存在 —— 可达性检查不能对着一个空角色跑`)
            await restOk('/rest/v1/user_roles', { method: 'POST',
                body: JSON.stringify({ user_id: u.id, role_id: rr[0].id }) }, `授 ${roleCode}`)
            reachUsers.push(u.id)
            return signIn(em, 'smoke-pass-3')
        }
        if (!RUN_REACH) {
            console.log('\n== 按角色的可达性:【跳过】(默认关闭)——'
                + ' 改了导航/守卫/新增页面之后,跑你动过的那个角色:--reach=finance'
                + '(三个全跑用 --reach,约 100 分钟,留给推送前的整轮)')
        }
        for (const roleCode of RUN_REACH ? REACH_ROLES : []) {
            const r = await reachabilityForRole(roleCode, `http://localhost:${PORT}`, mkSession)
            const unexpected = r.unreachable.filter((x) => !EXPECTED_UNREACHABLE[r.role].has(x))
            const gone = [...EXPECTED_UNREACHABLE[r.role]].filter((x) => !r.unreachable.includes(x))
            console.log(`  ${r.role}: 走到 ${r.reached} · 打得开 ${r.openable} 条静态路由 · ` +
                `其中走不到 ${r.unreachable.length}(动态路由 ${r.dynamicCount} 条不在断言范围,见文件头第 2 条)`)
            for (const x of unexpected) {
                reachFailures.push(`${r.role} 打得开但从首页走不到:${x}`)
                console.log(`  ✗ ${r.role} 打得开却走不到:${x}`)
            }
            for (const x of gone) {
                reachFailures.push(`${r.role} 预期走不到的 ${x} 现在走得到了 —— 把它移出 EXPECTED_UNREACHABLE`)
                console.log(`  ✗ ${r.role} 预期走不到的 ${x} 现在走得到了`)
            }
        }
        for (const id of reachUsers) {
            await restCleanup(`/rest/v1/user_roles?user_id=eq.${id}`, { method: 'DELETE' },
                `reach:收回角色授权 ${id}`)
            await restCleanup(`/auth/v1/admin/users/${id}`, { method: 'DELETE' },
                `reach:删账号 ${id}`)
        }
    } finally {
        dev.kill('SIGTERM')
        await rest(`/rest/v1/performance_reviews?id=eq.${review.id}`, { method: 'DELETE' })
        // ★ PROBATION-1 的清理【漏了 noDate】★ 那一刀新造了第三名临时员工
        // (ZZ-SMOKE-3,负臂用的"没有到期日的人"),却没有把它加进这一行,
        // 于是每一跑都在 HR 屏幕上多留一名幽灵试用期员工。STATEMENT-1 补上。
        // 记在这里而不是默默改掉:**新造一行临时数据,和删掉它,是同一件事的两半**,
        // 而漏掉的那一半不会报错 —— 它只是慢慢堆起来。
        await rest(`/rest/v1/employees?id=in.(${reviewee.id},${reviewer.id},${noDate.id})`,
            { method: 'DELETE' })
        // cu2(评估人)【没有被授任何角色】,所以它只有账号那一半要删。
        await restCleanup(`/auth/v1/admin/users/${cu2.id}`, { method: 'DELETE' }, '收尾:删评估人账号')
        // cu 持【真的 admin 角色】—— 这两行的顺序与成败就是幽灵授权的来源。
        await restCleanup(`/rest/v1/user_roles?user_id=eq.${cu.id}`, { method: 'DELETE' },
            '收尾:收回一次性 admin 授权')
        await restCleanup(`/auth/v1/admin/users/${cu.id}`, { method: 'DELETE' }, '收尾:删一次性 admin 账号')
    }

    // 【总结行把带查询串的探针【单独数出来】】把它们混进 routes 的计数里,
    // 等于让"这一类到底测没测"重新变得看不见 —— 而它们存在的理由正是那件事。
    // PROBATION-1:总结这一行要把【每一个计进 ok 的探针】都点出来,否则
    // 标签念的是一件事、数字数的是另一件 —— 本仓库对这个形状记过好几次账。
    console.log(`\n== ${routes.length} routes + 1 reviewer-view check + ${QUERY_PROBES.length} query-string probe(s) + 2 probation-entry probes + 2 customer-page entry probes + 2 cash-forecast probes (nav + content) + 3 claim probes (2 content + nav) + 3 attendance probes (2 content + nav) + 3 WHT probes (2 content + nav) + 4 pack/GL-export probes (2 content + 2 nav) + 1 overlap-entry probe + 1 retention-panel probe + 1 signed-out /login probe: ${ok} ok, ${skipped.size} skipped (no data), ${failures.length} FAILED`)
    // SESSION-1:这一行排在所有失败之前,因为它改变【怎么读】下面那一百行。
    if (sawAuthIndeterminate) {
        const n = failures.filter((f) => f.authDown).length
        console.log('')
        console.log(`   ⚠ 其中 ${n} 条是 503 + data-auth-indeterminate ——`)
        console.log('     **认证服务够不着,不是这些页面坏了。** 中间件拒绝把"问不到答案"')
        console.log('     说成"你没登录"(lib/supabase/middleware.ts),所以它回 503,而本脚本')
        console.log('     断言 2xx,于是变红 —— 这次红是对的。先查认证,不要查这一刀改了什么。')
    }
    // 【被跳过的内容判据要说出来】一条静默跳过的断言与一条不存在的断言,
    // 在输出里长得一模一样 —— 而这套东西刚刚为这件事付过两次代价。
    if (contentSkips.length) {
        console.log(`   内容判据跳过 ${contentSkips.length} 条(探针无数据,不算失败):`)
        for (const c of contentSkips) console.log(`     · ${c}`)
    }
    for (const f of failures) {
        console.log(`\n✗ ${f.route} (${f.url}) → HTTP ${f.status}${f.expected ? ` (expected ${f.expected})` : ''}`)
        if (f.stack) console.log(f.stack.split('\n').map((l) => '    ' + l).join('\n'))
    }
    const extraSkips = [...skipped].filter((r) => !EXPECTED_SKIPS.has(r))
    const goneSkips = [...EXPECTED_SKIPS].filter((r) => !skipped.has(r))
    if (extraSkips.length)
        console.log(`\n✗ 预期之外的 SKIP —— 覆盖回归,查数据源,别默认"没数据": ${extraSkips.join(', ')}`)
    if (goneSkips.length)
        console.log(`\n✗ 预期会 SKIP 的路由跑起来了 —— 数据到位了,把它移出 EXPECTED_SKIPS: ${goneSkips.join(', ')}`)
    if (reachFailures.length) {
        console.log(`\n✗ 可达性 ${reachFailures.length} 处 —— "打得开却走不到"就是一个没有入口的页面:`)
        for (const r of reachFailures) console.log('   ' + r)
    }
    // ★【清理失败是一次失败,不是一条日志】★ 没删掉的那一半可能是一条
    //   【认不到人的 admin 授权】—— 它不会让任何一条路由变红,而它会一直躺在库里,
    //   让"admin 有几个持有人"这个会被人据以行动的数字说假话(ACCOUNTS-CLEAN:66 条;
    //   一周后又 21 条)。一个报告了却不拦的判词不是闸。
    if (cleanupFailures.length) {
        console.log(`\n✗ 一次性账号/授权没有清理干净 ${cleanupFailures.length} 处 —— ` +
            `其中任何一条如果是 user_roles,留下的就是一条认不到人的授权:`)
        for (const c of cleanupFailures) console.log('   ' + c)
        console.log('   处置:node scripts/check-scratch-rows.mjs 会把幽灵授权按名报出来。')
    }
    process.exit(failures.length || extraSkips.length || goneSkips.length
        || reachFailures.length || cleanupFailures.length ? 1 : 0)
}
main().catch((e) => {
    console.error(`\n✗ 冒烟中止(脚本自身的查询炸了,不是路由失败):\n${e.message ?? e}`)
    printProgress()
    process.exit(1)
})

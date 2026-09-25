#!/usr/bin/env node
// scripts/check-document-registry.mjs
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-4 · 一张新表【是不是一张单据表】—— 今天没有任何东西管,于是这里管
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么这道闸是承重的,而不是锦上添花】
// SEARCH-4 的关联搜索把【节点集】绑在 document_types 上:非单据表只当边,不当
// 端点(裁定 ③)。**于是一张没有登记的新单据表,不只是搜不到它自己 —— 所有指向
// 它的关联边会一起安静地消失。** 漏登记一次,漏掉的不是一条结果,是一片边。
//
// 而「漏登记会被别的东西抓到」这句话今天只对一半:
//   `document_type_prefix('<key>')` 读不到就 RAISE(SEARCH-2b §5.1),所以一张
//   **会铸码**的新单据表若没登记,生产上第一次开单就响。**但它管不到 code 由
//   应用层 TypeScript 填的那种新表** —— 那一种今天一路绿。
//
// ── 判据(照 SEARCH-1 收紧后的 check-nav-routes 判据 ② 的形状)──────────────
//   ① `db/tables/` 的镜像里,每一张有 `code` 列的表,**要么在 document_types
//      的种子里,要么在 document_type_exceptions 的种子里【带一句理由】**。
//   ② 例外表里没有死条目:一条例外指的表若【没有 code 列】或【其实已登记】,
//      那条例外要么过期了,要么本脚本瞎了 —— 两种都红(assertAllowlistLive)。
//   ③ 每一条例外的理由非空。(库里那条 CHECK 是同一句话的另一半;这里查镜像,
//      因为构建时够不到线上。)
//   ④ 覆盖本身是断言:表的条数与带 code 的条数,各用【两条独立的路】数一遍。
//
// ★【为什么例外表是一张【库表】而不是本文件里的一个常量】
//   check-nav-routes 的 EXCEPTIONS 写在脚本里,因为路由只活在文件系统上。
//   这一条的主语是【表】,而表的真相在库里 —— 把例外写进库,check_mirrors.py
//   的 SEED_TABLES 就会逐行盯着它,于是例外名单本身也不许悄悄漂。
//
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :`db/tables/*.sql` 里 `CREATE TABLE public.X (…)` 的**文本**
//                   (一个文件可以定义多张表 —— 实测 216 个文件 / 218 张表,
//                   freight_allocations 住在 freight_documents.sql 里),
//                   以及 document_types / document_type_exceptions 两段种子 INSERT。
//   我声称管的是   :**线上 public 里每一张有 code 列的表都被裁过一次** ——
//                   它要么是单据(在册),要么不是(在例外表里,带理由)。
//   两者不同之处   :★ 我读的是【镜像】,不是线上。「镜像 ≡ 线上」由
//                   `db/check_mirrors.py` 负责(它同时报覆盖缺口:线上有而镜像
//                   没有 = 缺镜像)。**它若被摘掉,我会对着一份过期的目录报绿,
//                   而我自己看不出来。**
//                   ☞ 第二处:我只问「有没有 code 列」,不问这张表**该不该**
//                   是单据 —— 那是一句人话,写在例外表的 reason 里,不在我这儿。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { assertPopulation, assertPinned, assertAllowlistLive } from './lib/selfproof.mjs'

const SCRIPT = 'check-document-registry'
const ROOT = new URL('..', import.meta.url).pathname
const TABLES_DIR = join(ROOT, 'db/tables')

// ★ 声明的表数。改了这个数就是改了一次口径 —— 这个摩擦是刻意的
//   (同 check-search-registry 的 EXPECTED_ROWS = 40)。
// FA-HIST-1(2026-09-20):220 → 221。新增 `fixed_asset_history`(固定资产台账的
// 变更留痕),见 db/tables/fixed_asset_history.sql。**它没有 code 列**,所以
// EXPECTED_CODE_TABLES 不动 —— 两个数各自对着一件事,一起改才是可疑的。
// APR-1(2026-09-22):221 → 222。新增 `finance_settings_history`(审批策略那四列的
// 变更留痕),见 db/tables/finance_settings_history.sql。**它没有 code 列**
// (它记的是一张单行配置表的变更,没有单据号),所以 EXPECTED_CODE_TABLES 不动。
// APR-ROUTE-1 Batch B(2026-09-23):222 → 224。新增 `employee_accounts`(一个人的额外账号)
// 与 `employee_account_history`(链接与解除的只增不改留痕),见 db/tables/ 同名文件。
// **两张都没有 code 列**(它们记的是"账号属于谁",不是单据),所以 EXPECTED_CODE_TABLES 不动。
// PAY-REQ-1(2026-09-23):224 → 225,75 → 76。新增 `payment_requests`(付款申请),
// 见 db/tables/payment_requests.sql。**它有 code 列**(PREQ-YYYY-NNNN,登记在
// document_types 的 'payment_request'),所以两个数一起动 —— 这一次一起动是对的。
// AP-RECON-1 Batch B(2026-09-24):225 → 226。新增 `list_ledger_residue`(清单 ↔ 总账的逐单据残留,
// 只有迁移能写),见 db/tables/list_ledger_residue.sql。**它没有 code 列**(单据编号列叫 doc_code,
// 它记的是"哪一张单据的哪一笔差",不是一张单据),所以 EXPECTED_CODE_TABLES 不动。
// ROLE-1 Batch 2a(2026-09-24):226 → 227。新增 `supplier_status_history`(供应商状态每一步的
// 只增不改留痕,Tim 的 Q3),见 db/tables/supplier_status_history.sql。**它没有 code 列**
// (它记的是"哪一家从什么状态到什么状态",不是一张单据),所以 EXPECTED_CODE_TABLES 不动。
// PAYROLL-APR-1(2026-09-24):227 → 228。新增 `payroll_requests`(工资过账 / 撤销过账的申请,CFO 批),
// 见 db/tables/payroll_requests.sql。**它没有 code 列**(它是对一个工资期的一次请求,人读的名字是 label:
// 期间编号 · 种类 · 第几次;不进 document_types),所以 EXPECTED_CODE_TABLES 不动。
// ROLE-1 Batch 4b(2026-09-25):228 → 229。新增 `receipt_price_requests`(收货定价申请,CFO 批,批准
// 当场过账),见 db/tables/receipt_price_requests.sql。**它没有 code 列**(它是对一张收货的一次请求,
// 人读的名字是 label:收货编号 · price #n;不进 document_types),所以 EXPECTED_CODE_TABLES 不动。
// ROLE-1 Batch 3a(2026-09-25):229 → 230。新增 `stocktake_counts`(每一次录数与重录连同录数的人,只增不改;
// 过账时"录过数的人不能过账"读它),见 db/tables/stocktake_counts.sql。**它没有 code 列**(它记的是"谁在哪张
// 盘点单上数成了多少",不是一张单据),所以 EXPECTED_CODE_TABLES 不动。
// APR-5a(2026-09-25):230 → 231。新增 `invoice_requests`(贷项 / 作废发票的申请,CFO 批,批准当场过账),
// 见 db/tables/invoice_requests.sql。**它没有 code 列**(它是对一张发票的一次请求,人读的名字是 label:
// 发票编号 · credit note #n / void #n;不进 document_types),所以 EXPECTED_CODE_TABLES 不动。
// APR-5b(2026-09-25):231 → 233。新增 `shipping_releases`(发货放行,cco 提、CFO 批,批准就是放行)与
// `shipping_release_lines`(放行点名的发票行),见 db/tables/shipping_releases.sql / shipping_release_lines.sql。
// **两张都没有 code 列**(放行的人读名字是 label:订单编号 · release #n;不进 document_types),
// 所以 EXPECTED_CODE_TABLES 不动。
const EXPECTED_TABLES = 233
const EXPECTED_CODE_TABLES = 76

const files = readdirSync(TABLES_DIR).filter((f) => f.endsWith('.sql'))
assertPopulation(SCRIPT, 'db/tables/ 里的镜像文件', files.length, 2)

// ── 解析:一个文件可以定义多张表,所以按 CREATE TABLE 切块,不按文件名 ───────
const tables = []            // { name, hasCode, file }
let rawCreateCount = 0       // 独立计数 ①:整个语料里 CREATE TABLE 行的条数
let rawCodeColCount = 0      // 独立计数 ②:整个语料里 `code <type>` 列声明的条数

for (const f of files) {
    const sql = readFileSync(join(TABLES_DIR, f), 'utf8')
    rawCreateCount += (sql.match(/^CREATE TABLE /gm) ?? []).length
    rawCodeColCount += (sql.match(/^\s+code\s+[a-z]/gm) ?? []).length

    // 按 CREATE TABLE public.X ( 切块,块止于下一条 CREATE TABLE 或文件末尾。
    const re = /^CREATE TABLE (?:IF NOT EXISTS )?public\.([a-z0-9_]+)\s*\(/gm
    const starts = []
    let m
    while ((m = re.exec(sql)) !== null) starts.push({ name: m[1], at: m.index })
    for (let i = 0; i < starts.length; i += 1) {
        const body = sql.slice(starts[i].at, i + 1 < starts.length ? starts[i + 1].at : sql.length)
        // 列声明 `    code text …` —— 前导空白 + 词边界,否则 bank_account_code /
        // subject_code / org_code 会一起被算进来(那正是「切词」那一层的老毛病)。
        tables.push({ name: starts[i].name, file: f, hasCode: /^\s+code\s+[a-z]/m.test(body) })
    }
}

// ── 判据 ④ · 覆盖断言,先跑 ─────────────────────────────────────────────────
// 一份干净的目录和一支瞎掉的解析器都印 EXIT 0,所以先说出这一次到底看了多少。
assertPopulation(SCRIPT, '解析出的 CREATE TABLE 块', tables.length, 2)
assertPinned(SCRIPT, 'public 表的条数', tables.length, rawCreateCount,
    '按块切与按行数,两条路数出来必须一样多 —— 不一样就是切块规则漏了一种写法。')
assertPinned(SCRIPT, 'public 表的条数(对着声明的数)', tables.length, EXPECTED_TABLES,
    '表真的增减了,就把 EXPECTED_TABLES 与切次报告一起改掉;这个摩擦是刻意的。')
const codeTables = tables.filter((t) => t.hasCode)
assertPinned(SCRIPT, '带 code 列的表', codeTables.length, rawCodeColCount,
    '按块判与按行数,两条路必须一样多 —— 不一样就是有一张表声明了两次 code,或块切错了。')
assertPinned(SCRIPT, '带 code 列的表(对着声明的数)', codeTables.length, EXPECTED_CODE_TABLES,
    '带 code 的表真的增减了,就把 EXPECTED_CODE_TABLES 与切次报告一起改掉。')

// ── 两段种子 ────────────────────────────────────────────────────────────────
// ★ 返回 { rows, raw } —— raw 是一条【不经过判据正则】的粗计数。
//   两者不等 = 行正则漏了一种写法,而那是【量具瞎了】(exit 2),不是
//   【种子里少一行】(exit 1)。这两种在屏幕上分不开,而处置完全相反:
//   前者改正则,后者改种子。本判据开工当天就踩了一次 —— 种子最后一行结尾是
//   `')` 而不是 `'),`,于是它少读一行、把 wht_natures 报成"没登记也没例外"。
function seedRows(file, insertHead, rowRe) {
    const sql = readFileSync(join(TABLES_DIR, file), 'utf8')
    const at = sql.indexOf(insertHead)
    if (at < 0) {
        console.error(`✗ ${SCRIPT}:${file} 里找不到 \`${insertHead}\` —— 判据瞎了,不是种子干净了`)
        process.exit(2)
    }
    const block = sql.slice(at)
    const out = []
    for (const line of block.split('\n')) {
        const m = line.match(rowRe)
        if (m) out.push(m)
    }
    return { rows: out, raw: (block.match(/^\s*\('/gm) ?? []).length }
}

// document_types:第 3 个字段是 table_name
const regSeed = seedRows(
    'document_types.sql',
    'INSERT INTO public.document_types',
    /^\s*\('[^']+',\s*'[^']+',\s*'([a-z0-9_]+)'/,
)
assertPopulation(SCRIPT, 'document_types 种子里的行', regSeed.rows.length, 2)
assertPinned(SCRIPT, 'document_types 种子的行数', regSeed.rows.length, regSeed.raw,
    '行正则与粗计数不一样多 —— 种子里有一种写法这条正则不认。')
const registered = new Set(regSeed.rows.map((m) => m[1]))

// document_type_exceptions:(table_name, reason)
const excSeed = seedRows(
    'document_type_exceptions.sql',
    'INSERT INTO public.document_type_exceptions',
    /^\s*\('([a-z0-9_]+)',\s*'(.*)'\)[,;]?\s*$/,
)
const exceptionRows = excSeed.rows.map((m) => ({ table: m[1], reason: m[2] }))
assertPopulation(SCRIPT, 'document_type_exceptions 种子里的行', exceptionRows.length, 2)
assertPinned(SCRIPT, 'document_type_exceptions 种子的行数', exceptionRows.length, excSeed.raw,
    '行正则与粗计数不一样多 —— 最后一行没有尾逗号是最常见的那一种。')

const excepted = new Map(exceptionRows.map((r) => [r.table, r.reason]))
assertPinned(SCRIPT, '例外表的行数(去重后)', excepted.size, exceptionRows.length,
    '同一张表写了两次例外 —— 两句理由里有一句是没人读的。')

const problems = []

// ── 判据 ③ · 理由非空 ───────────────────────────────────────────────────────
for (const r of exceptionRows) {
    if (r.reason.trim() === '') {
        problems.push({
            arm: '③ 每一条例外都要写明理由',
            msg: `${r.table} 的 reason 是空的 —— 一张塞得进空理由的例外表就是一张"不要红"的名单。`,
        })
    }
}

// ── 判据 ① · 要么在册,要么在例外表里 ───────────────────────────────────────
for (const t of codeTables) {
    if (registered.has(t.name)) continue
    if (excepted.has(t.name)) continue
    problems.push({
        arm: '① 有 code 列的表要么登记,要么例外',
        msg: `public.${t.name}(${t.file})有 code 列,而它既不在 document_types 里,`
            + `也不在 document_type_exceptions 里。\n`
            + `      ☞ 它若是一张单据:登记它 —— 否则搜索搜不到它,而且**所有指向它的关联边`
            + `会一起消失,安静地**(SEARCH-4 裁定 ③)。\n`
            + `      ☞ 它若不是:往 db/tables/document_type_exceptions.sql 里加一行,`
            + `连同一句为什么。`,
    })
}

// ── 判据 ② · 例外表里不许有死条目 ───────────────────────────────────────────
const codeNames = new Set(codeTables.map((t) => t.name))
assertAllowlistLive(
    SCRIPT,
    'document_type_exceptions 的每一条今天都该指着一张【有 code 列、且没登记】的表',
    exceptionRows,
    (r) => codeNames.has(r.table) && !registered.has(r.table),
    (r) => `${r.table} —— ${codeNames.has(r.table)
        ? '它已经在 document_types 里登记了,这条例外是假的'
        : '这张表没有 code 列(或者已经不在镜像里了)'}`,
)

// ── 判词 ────────────────────────────────────────────────────────────────────
if (problems.length > 0) {
    console.error(`✗ ${SCRIPT}:${problems.length} 处`)
    for (const p of problems) console.error(`  [${p.arm}] ${p.msg}`)
    console.error(`\n  读到:${tables.length} 张表 · 其中带 code 列 ${codeTables.length} 张 · `
        + `已登记 ${registered.size} 条 · 例外 ${excepted.size} 条`)
    process.exit(1)
}

console.log(`✓ ${SCRIPT}:${tables.length} 张表,其中带 code 列 ${codeTables.length} 张 —— `
    + `${codeTables.filter((t) => registered.has(t.name)).length} 张在册、`
    + `${codeTables.filter((t) => excepted.has(t.name)).length} 张在例外表里【各带一句理由】,`
    + `没有第三种。`)

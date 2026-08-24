// scripts/gen-masked-tables.mjs
// 从 lib/database.types.ts 生成 lib/maskedTables.ts。
//
// 【为什么要生成,而不是手写一张清单】(IDLE-DRAFT,2026-08-24)
// 草稿留存要回答一个问题:**这张表带不带受限数据?** 而这个问题系统里【已经有
// 答案】—— 一张表有没有 `<表>_masked` 伴生视图,正是"它有列被从 authenticated
// 手里收回了"的意思。scripts/check-masked-reads.mjs 早就是这么判的。
//
// 手写第二张"哪些表算受限"的清单,就是把一条系统已经陈述过的规矩再陈述一遍 ——
// 而两处陈述必然漂开:线上加一张遮蔽表,清单不会自己跟上,于是某张带薪资的
// 表单会安静地开始留存草稿。生成 + 校验,让它跟得上。
import { readFileSync, writeFileSync } from 'node:fs'

const src = readFileSync('lib/database.types.ts', 'utf8')
const views = [...src.matchAll(/^ {6}(\w+_masked):/gm)].map((m) => m[1])
const tables = [...new Set(views.map((v) => v.replace(/_masked$/, '')))].sort()

if (tables.length === 0) {
    console.error('✗ gen-masked-tables:解析出 0 张遮蔽表 —— 解析器坏了,不是没有遮蔽表。')
    process.exit(1)
}

const out = `// lib/maskedTables.ts
// 【生成的文件,不要手改】由 scripts/gen-masked-tables.mjs 从 lib/database.types.ts 生成,
// 由 scripts/check-masked-reads.mjs 校验是否同步(不同步则构建失败)。
//
// 一张表出现在这里,意思是它【有列被从 authenticated 手里收回】—— 也就是它带着
// 受限数据(薪资 / 身份 / 银行 / 价格 / 评估正文之类)。这是数据库自己的说法,
// 不是另一张需要有人记得更新的清单。
//
// 草稿留存据此决定【不为哪些表留草稿】:见 lib/useFormDraft.ts。
export const MASKED_TABLES: ReadonlySet<string> = new Set([
${tables.map((t) => `    '${t}',`).join('\n')}
])
`
writeFileSync('lib/maskedTables.ts', out)
console.log(`✓ gen-masked-tables:${tables.length} 张遮蔽表 → lib/maskedTables.ts`)

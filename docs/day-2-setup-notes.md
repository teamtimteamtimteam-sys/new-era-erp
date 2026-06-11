# Day 2 开发笔记 — Suppliers 模块上线

> 记录 Week 1 第 2 天的开发进度、关键技术决策、踩坑经验和下次的起点。

---

## 一、今天完成了什么

Week 1 主线目标:**Master Data 第一张表 — Suppliers**。今天**全部跑通**。

### 1.1 数据库层(Supabase / PostgreSQL)

- **`suppliers` 主表**(16 个字段)
  - 主键 `id`(UUID)
  - 业务编码 `code`(`SUP-2026-NNNN`,触发器自动生成)
  - 法人名、简称、国家、地址、税号
  - 供应商类型 `supplier_types`(text 数组,支持多选)
  - 商务条款:`payment_terms`、`incoterm`、`credit_rating`
  - 状态字段 `status`(枚举,7 个值)
  - 关联人 `owner_id`(为未来权限模型预留)
  - 软删除 `deleted_at`
  - 审计字段 `created_at` / `created_by` / `updated_at` / `updated_by`
- **`supplier_compliance` 合规子表**(预留,本周还没接 UI)
- **`supplier_status` 枚举类型**:`draft / pending_review / approved / rejected / active / suspended / blacklisted / archived`
- **`supplier_code_seq` 序列**(自增 1,4 位补 0)
- **触发器 3 个**
  - `generate_supplier_code()`:INSERT 时自动填 code
  - `update_updated_at()`:UPDATE 时自动更新时间戳
  - `validate_supplier_status_transition()`:**状态机校验,守护合法流转**
- **6 个索引**(status / country / owner_id / code / supplier_id / valid_until)
- **RLS 策略**(开发模式,见技术债清单)

### 1.2 应用层(Next.js 16 + @supabase/ssr)

| 页面 / 文件 | 功能 |
|---|---|
| `/suppliers` | 列表页(列表 + "+ 新增"按钮 + Code 跳转编辑 + 软删除按钮) |
| `/suppliers/new` | 新增页(Server Action + 必填校验) |
| `/suppliers/[id]/edit` | 编辑页(动态路由,字段预填,带状态机面板) |
| `app/suppliers/actions.ts` | 软删除 Server Action |
| `app/suppliers/[id]/edit/statusActions.ts` | 状态流转 Server Action |
| `app/suppliers/[id]/edit/statusMachine.ts` | 状态机常量(纯数据) |
| `app/suppliers/[id]/edit/StatusPanel.tsx` | 状态面板组件(只显示合法操作) |

### 1.3 双层防御验证通过

| 防御 | 内容 | 验证方法 |
|---|---|---|
| **UI 层** | 已拉黑状态下只显示「归档」一个按钮,「激活」根本不存在 | 浏览器走完整路径,观察按钮变化 |
| **数据库层** | 触发器拒绝非法状态跳转,直接 RAISE | 跑邪恶 SQL:`UPDATE … SET status='active' WHERE status='blacklisted'`,得到 `ERROR: P0001: 非法状态跳转: blacklisted → active` |

---

## 二、关键技术决策

下次设计新模块时可以复用的思路:

### 2.1 "先重复,后抽象"

新增表单和编辑表单代码 90% 一样,但**没有合并**。理由:
- 现在只有 2 处,合并会引入抽象层,反而难懂
- 等出现第 3、4 处相似表单(比如批次、订单),再看清差异点再合并
- 抽象错的代价远高于重复的代价

### 2.2 状态机 + 触发器,而不是应用层校验

业务规则(`draft` 必须经审核才能 `active`)写在**数据库触发器**里,不是 Next.js 代码里。原因:
- 一旦绕过 UI(直接 SQL、其他工具、未来其他系统),规则照样生效
- 数据库是最终防线
- 多个应用接入时不会有"这个应用忘了校验"的问题

### 2.3 `code` 用业务编码 + UUID 作主键

`code = SUP-2026-0003` 给人看,`id = UUID` 给系统用。URL 用 `id` 不用 `code`,因为 `code` 理论上可能因为某些业务原因改写(虽然我们现在禁止),但 `id` 永远不变。

### 2.4 软删除而非硬删除

ERP 系统的供应商可能被订单、合规记录引用,**永远不能真删**。`deleted_at IS NULL` 过滤 + 数据真实保留在表里,可恢复。

### 2.5 owner_id 字段提前埋好

现在只有一个用户(我自己),不需要权限,但 `owner_id` 字段已在 schema 里。这样 Week 3+ 加同事账号时,**改 RLS 策略一行就行**,不用改表结构。

---

## 三、关键链接

| 项目 | 地址 |
| --- | --- |
| GitHub 仓库 | https://github.com/teamtimteamtimteam-sys/new-era-erp |
| Vercel 生产环境 | https://new-era-erp.vercel.app |
| 本地 | `~/Documents/projects/new-era-erp` |
| Supabase 项目 ID | `<TODO: 填入,Day 1 笔记里也漏了>` |

---

## 四、Day 2 新踩的坑(继 Day 1 的 4 个之后)

### 4.1 `'use server'` 文件不能 export 非函数

**症状**:Status Panel 显示 `当前状态: draft (draft)`(英文)而非 `草稿 (draft)`,且 `当前状态没有可执行的操作`(应该有 2 个按钮)。

**根因**:Next.js 16 规则 —— 标记了 `'use server'` 的文件,所有 export 必须是异步函数。我当时图省事把 4 个常量(`STATUS_LABELS`、`ALLOWED_TRANSITIONS` 等)和 `changeSupplierStatus` 函数写在同一个 `statusActions.ts` 文件里,常量被剥离,import 进来全是 undefined。

**修复**:拆成两个文件
- `statusMachine.ts` 普通文件,放常量
- `statusActions.ts` 顶部 `'use server'`,只放函数

**通用原则**:**Server Action 的纯函数和它依赖的数据要分开放**。以后做批次、订单的状态机,同样三段式:
```
{thing}Machine.ts     ← 纯常量
{thing}Actions.ts     ← 'use server' 函数
{Thing}Panel.tsx      ← 'use client' UI 组件,from 两个文件分别 import
```

### 4.2 macOS 文件名大小写不敏感,Linux(Vercel)敏感

**症状**:编辑器里建文件叫 `statusPanel.tsx`(小写 s),代码里 import `'./StatusPanel'`(大写 S)—— Mac 上能跑,推到 Vercel 立刻报 `Module not found`。

**修复**:文件名严格按代码 import 的写法。

**通用原则**:所有 React 组件文件用 PascalCase(`StatusPanel.tsx`、`DeleteButton.tsx`),所有非组件 ts 文件用 camelCase(`statusMachine.ts`、`actions.ts`)。

### 4.3 多个 AI 同时写代码会撞车

**症状**:我(主对话 Claude)、Claude Code(终端 AI)、Antigravity 编辑器内置的 Gemini Agent 都能动文件夹。今天发生过 3 次"我还没说建,Claude Code 已经替我建了"的事。

**修复**:跟 Claude Code 明确设了规则 ——"读取随时可以,写入要等用户明说"。Antigravity Agent 没设规则,但今天没主动捣乱。

**通用原则**:**每周确认一次 AI 协作规则**。每个新模块开始前,问一句"现在你的规则还在吗?",避免规则被遗忘。

### 4.4 RLS 默认会挡掉未登录请求,看到的是"空"而非报错

**症状**:数据库里有 1 条 Acme,Next.js 页面显示"共 0 条"。没有任何报错,只是默默没数据。

**根因**:RLS 策略`authenticated only`,Next.js 从浏览器发的请求是 anon 身份,被挡掉。Supabase 返回的不是 `error`,而是空数组 —— 看起来像"没数据"。

**临时修复**:RLS 改成 `anon + authenticated 全权访问`(开发模式,**技术债**)。

**正确修复**:本周内做认证 + 收紧 RLS。

---

## 五、技术债清单(必须本周内修)

按优先级:

### 🔴 高 — 安全风险

- [ ] **RLS 收紧** —— 现在是 `anon + authenticated 全权`,等同没有权限。必须做 Supabase Auth 登录页,然后 RLS 改回 `authenticated only`,owner_id 字段才有意义。**在此之前,绝对不要把 .env.local 换成生产密钥,不要公开分享 Vercel URL。**

### 🟡 中 — UX / 一致性

- [ ] **编辑页副标题徽章用了英文 status**(显示 `blacklisted` 而非 `已拉黑`)。`page.tsx` 直接显示 `supplier.status`,没过 `STATUS_LABELS` 映射。1 分钟能修。
- [ ] **列表页 Status 列同样问题** —— 显示 `draft` 不是 `草稿`。
- [ ] **错误显示安全性** —— 出错时把 Supabase 完整 error 对象 JSON.stringify 显示在网页上。开发期 OK,**上生产前必须改成只显示 `error.message`**,否则会泄露表名、列约束、RLS 提示等内部信息。
- [ ] **生成 TypeScript types from Supabase** —— 跑 `npx supabase gen types typescript --project-id <ref> > types/database.ts`,然后 `.from<Database>()`。这样字段名拼错 TS 会立刻报错(现在拼错会静默返回 undefined)。

### 🟢 低 — 代码清洁

- [ ] **删除 Day 1 留下的旧 `lib/supabase.ts`** —— 跟 `lib/supabase/server.ts` 并存,虽然现在没冲突,但 `import '@/lib/supabase'` 会拿到旧版本,埋雷。
- [ ] **缩进风格统一** —— 部分文件用 4 空格,大部分用 2 空格。挑一种,跑一遍 Prettier。
- [ ] **新增 / 编辑表单代码 90% 一样** —— 等做第 3 个相似表单(Week 2 的合规子表?)时再合并,**别现在就抽象**。

---

## 六、Week 2 起点

Master Data 模块还差:

### 直接接着做(优先)
1. **`supplier_compliance` 子表 CRUD** —— 在编辑页下方加一块"合规资质"区域,列出该供应商所有证书,能新增 / 编辑 / 删除。
2. **认证 + RLS 收紧** —— 上面 🔴 高优先级技术债。

### 之后做
3. **Master Data 第 2 张表 — 客户(Customers)** —— Day 1 的练习表存在,但还没正式做 ERP 客户。结构跟 Suppliers 很像,可以参考。
4. **Materials 物料表** —— 这是 SWM 业务的核心,EV battery pack / module / cell / production scrap / black mass / cathode foil 等,**batch-centric** 思维体现在这里。

---

## 七、Day 2 状态总结

- ✅ Suppliers 完整 CRUD(C / R / U / D 全到位)
- ✅ 状态机 8 个状态 + 触发器双层防御验证通过
- ✅ 编码自动生成(`SUP-2026-NNNN`)
- ✅ 软删除安全网(数据保留 + 列表过滤)
- 🚧 技术债 9 项,已分类排优先级
- 🎯 Week 1 主线目标:**100% 完成**

**真正的 ERP 第一个业务模块上线**。明天起进入 Week 2。

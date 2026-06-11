# Day 1 搭建笔记 — 2026-05-11

新的 ERP 项目 `new-era-erp` 第一天的搭建总结、踩坑记录与下一步计划。

## 1. 技术栈概览

| 层 | 选型 |
|---|---|
| 框架 | Next.js 16.2.6（App Router、Turbopack、TypeScript） |
| 样式 | Tailwind CSS（`@tailwindcss/postcss`,无 `src/` 目录) |
| 数据 | Supabase(`@supabase/supabase-js` 2.105.4) |
| 运行时 | Node.js 24.15.0(通过 nvm 0.40.4 管理) |
| 代码托管 | GitHub |
| 部署 | Vercel —— `git push origin main` 自动构建并发布 |

数据库与认证均托管在 Supabase；前端不直连数据库,而是通过 Server Component 在服务端调用 Supabase JS SDK。

## 2. 关键链接

| 资源 | 地址 |
|---|---|
| GitHub 仓库 | https://github.com/teamtimteamtimteam-sys/new-era-erp |
| Vercel 生产环境 | `<待填:首次部署完成后补上 vercel.app 地址>` |
| Supabase 项目 ID | `<待填:Project Settings → General → Reference ID>` |
| 本地开发 | http://localhost:3000(`npm run dev`) |

## 3. 请求流转

```
浏览器
  │
  │  HTTP GET /
  ▼
Vercel Edge / Serverless(Next.js Server Component)
  │
  │  app/page.tsx → import { supabase } from '@/lib/supabase'
  │  await supabase.from('customers').select('*')
  ▼
Supabase PostgREST(HTTPS,带 anon key)
  │
  ▼
Postgres(受 RLS 策略保护)
  │
  ▼ JSON 响应
Server Component 渲染 HTML
  │
  ▼
浏览器收到完整 HTML(无客户端二次请求)
```

要点:
- 表格页是 **Server Component**(`async function Home()`),数据在服务端取,首屏直出 HTML,SEO 与首屏速度都更好。
- 当前没有缓存;Next.js 14+ 已不再自动缓存第三方 fetch,supabase-js 的请求每次都会真正打到 Supabase。如需缓存可包一层 `unstable_cache`。
- `NEXT_PUBLIC_*` 前缀的变量会被打进客户端 bundle。anon key 暴露在前端是 Supabase 的设计前提,**安全性完全靠数据库 RLS 策略**,不是靠 key 的保密性。

## 4. 调试踩坑记录

### 4.1 `<>` 包裹陷阱

从渲染过的 Markdown(聊天工具、文档页)复制 URL 时,经常会把外层的尖括号也带过来:

```
NEXT_PUBLIC_SUPABASE_URL=<https://xxxxxxxxxxxxxxxx.supabase.co>
NEXT_PUBLIC_SUPABASE_ANON_KEY=<eyJhbGciOi...
>
```

报错顺序:
1. `Invalid supabaseUrl: Must be a valid HTTP or HTTPS URL.` —— URL 多了 `<`,无法解析。
2. 修了 URL 后又出现 `Invalid API key` —— anon key 同样有前导 `<`(后面的 `>` 此前作为孤立行被一并删掉了,导致前导 `<` 被遗留)。

不暴露密钥的诊断命令:

```sh
awk -F= '/SUPABASE_URL/ {val=$2; print "starts:" substr(val,1,8); print "ends:" substr(val,length(val)-15); print "len:" length(val)}' .env.local

awk -F= '/SUPABASE_ANON_KEY/ {val=$2; print "first 3:[" substr(val,1,3) "]"; print "last 3:[" substr(val,length(val)-2) "]"; print "len:" length(val)}' .env.local
```

健康值:
- URL 以 `https://` 开头、`.supabase.co` 结尾。
- Anon key 以 `eyJ`(JWT)或 `sb_`(新格式)开头。

### 4.2 始终点官方 "Copy" 按钮

直接选中页面文字时,几乎所有渲染层(Slack/Discord/GitHub/Notion/Markdown)都可能把链接装饰、引号、零宽字符一并带走。Supabase Dashboard、Vercel Dashboard、GitHub 等界面上的 **Copy** 按钮拿到的才是裸值。

规则:**任何 URL、Token、JWT,只复制官方 Copy 按钮给的版本。** 必须手敲/手贴时,先跑一遍上面的形状诊断。

### 4.3 环境变量不会热更新

Next.js 仅在**进程启动时**加载 `.env*` 文件,HMR 不重读环境变量。改完 `.env.local` 必须:

```sh
# 杀掉旧 dev server,然后:
npm run dev
```

服务端启动日志里会出现一行 `- Environments: .env.local`,确认成功加载。

### 4.4 `.env.local` 永远不入库

CNA 默认生成的 `.gitignore` 第 34 行:

```
.env*
```

验证:

```sh
git check-ignore -v .env.local
# 输出:.gitignore:34:.env*    .env.local
git status   # .env.local 不应出现在任何列表里
```

提交时尽量 `git add <具体文件>`,不要 `git add .` —— 一旦 `.gitignore` 失误或临时文件混进来,具名 staging 是最后一道防线。

## 5. Day 1 状态

- 脚手架、依赖、Supabase 客户端、首屏 Server Component 全部到位。
- `customers` 仅用作连通性练习表 —— 用于跑通"前端 → Supabase → Postgres → 渲染"的整条链路,**不是业务数据**。
- 真正的业务模块从 **Week 1 的 Suppliers(供应商)模块**开始。

下一步预告(Week 1):
- 设计 Suppliers 表结构与 RLS 策略
- 列表 / 新增 / 编辑 / 删除四个基础视图
- 开始引入 Server Actions 处理写操作

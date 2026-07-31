// app/purchasing/page.tsx
// /purchasing 本身没有独立内容 —— 直接落到采购单列表(子导航里再去模板)。
import { redirect } from 'next/navigation'

export default function PurchasingPage() {
    redirect('/purchasing/orders')
}

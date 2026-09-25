'use server'

// ★ APR-5b(Tim 2026-09-25,APR-5 grilling Q7 · 5b Q8):仓库在发货队列里发货 —— ship_order,门 action.ship_goods。
//   发货仍是选项 C 的第二半(借 2500 释放负债 / 贷 4000 收入 + COGS),由系统过账;按按钮的人看不见那笔钱:
//   ship_order 的返回值里没有任何金额(5b Q5),这里也只带回发货单号与 id。
//   错误走销售那一族(抛错的是 ship_order,它的码登记在 SALES_ORDER_ERROR_CODES)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeSalesOrderError } from '@/app/sales/orders/salesOrderErrorCodes'

export async function shipFromQueue(
    orderId: string,
    reservationId: string,
    qty: string,
    shipDate: string
): Promise<{ error?: string; shipmentId?: string; code?: string }> {
    const supabase = await createClient()
    const trimmed = qty.trim()
    const { data, error } = await supabase.rpc('ship_order', {
        p_sales_order_id: orderId,
        // 【空串不是日期】空着就让服务端按名拒(SHIP_DATE_REQUIRED)
        p_ship_date: (shipDate.trim() === '' ? null : shipDate) as unknown as string,
        // 【数量留空 = 整条预留】—— 不传 qty,函数就整条消耗
        p_lines: [
            trimmed === ''
                ? { reservation_id: reservationId }
                : { reservation_id: reservationId, qty: Number(trimmed) },
        ],
    })
    if (error) return { error: await localizeSalesOrderError(error.message) }
    revalidatePath('/logistics/shipping')
    revalidatePath(`/sales/orders/${orderId}`)
    revalidatePath('/inventory')
    const r = data as { shipment_id?: string; code?: string } | null
    return { shipmentId: r?.shipment_id, code: r?.code }
}

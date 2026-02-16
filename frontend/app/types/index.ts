// Global type definitions

export interface User {
  id: string
  email: string
  role: 'admin' | 'operator'
  created_at: string
}

export interface Machine {
  id: string
  name: string
  location: string
  status: 'online' | 'offline' | 'error'
  last_seen: string
  assigned_to?: string
}

export interface Slot {
  id: string
  machine_id: string
  slot_number: number
  product_name: string
  product_price: number
  current_stock: number
  max_capacity: number
}

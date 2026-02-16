# Requirements - Vending Machine Management UI

## Traceability Matrix

| Requirement | Phase | Phase Name | Status |
|-------------|-------|------------|--------|
| USER-01 | 1 | Foundation & Auth | Pending |
| USER-02 | 1 | Foundation & Auth | Pending |
| USER-03 | 1 | Foundation & Auth | Pending |
| USER-04 | 1 | Foundation & Auth | Pending |
| MACH-01 | 2 | Machine Dashboard | Pending |
| MACH-02 | 2 | Machine Dashboard | Pending |
| MACH-03 | 2 | Machine Dashboard | Pending |
| MACH-04 | 2 | Machine Dashboard | Pending |
| MACH-05 | 2 | Machine Dashboard | Pending |
| STOCK-01 | 3 | Stock Management | Pending |
| STOCK-02 | 3 | Stock Management | Pending |
| STOCK-03 | 3 | Stock Management | Pending |
| STOCK-04 | 3 | Stock Management | Pending |
| STOCK-05 | 3 | Stock Management | Pending |
| SALES-01 | 4 | Sales & Reporting | Pending |
| SALES-02 | 4 | Sales & Reporting | Pending |
| SALES-03 | 4 | Sales & Reporting | Pending |
| SALES-04 | 4 | Sales & Reporting | Pending |
| SALES-05 | 4 | Sales & Reporting | Pending |
| SALES-06 | 4 | Sales & Reporting | Pending |
| PRICE-01 | 5 | Price Management | Pending |
| PRICE-02 | 5 | Price Management | Pending |
| PRICE-03 | 5 | Price Management | Pending |
| PRICE-04 | 5 | Price Management | Pending |
| MACH-06 | 6 | Real-time & Polish | Pending |
| MACH-07 | 6 | Real-time & Polish | Pending |

**Coverage**: 25/25 v1 requirements mapped ✓

---

## Machine Management (MACH)

### MACH-01: View machine list with status
**Priority**: P0
**Description**: Display all vending machines in a list/grid view with current online/offline status indicator.
**Acceptance Criteria**:
- List shows machine name, location, and status
- Status clearly indicates online (green) or offline (red)
- List updates when status changes
- Pagination for 10-100 machines

### MACH-02: Group machines by location
**Priority**: P0
**Description**: Organize machines by physical location (building, floor, region).
**Acceptance Criteria**:
- Location filter/grouping available
- Visual separation of different locations
- Expandable/collapsible location groups
- Quick stats per location (total machines, online count)

### MACH-03: View machine details
**Priority**: P0
**Description**: Detailed view of individual machine showing telemetry and configuration.
**Acceptance Criteria**:
- Machine ID, name, location, last seen timestamp
- Current status and connection quality
- Recent activity log
- Link to stock and sales views

### MACH-04: Restart machines remotely
**Priority**: P1
**Description**: Send restart command to ESP32-S3 device via MQTT.
**Acceptance Criteria**:
- Restart button in machine details
- Confirmation dialog before action
- Status feedback (command sent, acknowledged)
- Error handling for offline machines

### MACH-05: Enable/disable machines
**Priority**: P1
**Description**: Toggle machine operational state (accept payments or not).
**Acceptance Criteria**:
- Enable/disable toggle in UI
- Status persists across sessions
- Visual indication of disabled state
- Confirmation for state changes

### MACH-06: Real-time status updates
**Priority**: P0
**Description**: Live online/offline status via Supabase Realtime.
**Acceptance Criteria**:
- Status updates without page refresh
- Connection status indicator for realtime
- Visual animation on status change
- Timestamp of last status update

### MACH-07: Error/alert notifications
**Priority**: P1
**Description**: Display machine errors and alerts with acknowledgment capability.
**Acceptance Criteria**:
- Alert badge on machines with issues
- Error details viewable
- Acknowledge/clear alert action
- Alert history log

---

## Stock Management (STOCK)

### STOCK-01: Visual slot grid (6×8)
**Priority**: P0
**Description**: Display machine inventory as 6 trays × 8 slots grid visualization.
**Acceptance Criteria**:
- Grid shows all 48 slots
- Empty vs filled slots visually distinct
- Tray/Slot numbering clear
- Responsive layout for different screen sizes

### STOCK-02: View stock levels
**Priority**: P0
**Description**: Show current quantity for each slot.
**Acceptance Criteria**:
- Stock count displayed per slot
- Visual indicator for stock level (full/medium/low/empty)
- Last updated timestamp
- Quick view of total items in machine

### STOCK-03: Force inventory
**Priority**: P1
**Description**: Reset/clear inventory counts (e.g., after manual restocking).
**Acceptance Criteria**:
- "Force Inventory" button
- Confirmation dialog
- Sets all slots to configured max capacity
- Audit log entry created

### STOCK-04: Product catalog
**Priority**: P1
**Description**: Manage product definitions (name, image, category).
**Acceptance Criteria**:
- Add/edit/delete products
- Product name, description, image URL
- Category assignment
- Products assignable to slots

### STOCK-05: Low stock alerts
**Priority**: P1
**Description**: Notify when slot inventory falls below threshold.
**Acceptance Criteria**:
- Configurable low stock threshold per slot
- Visual alert on machine overview
- Alert list view
- Dismiss/clear alert action

---

## Sales & Reporting (SALES)

### SALES-01: Real-time sales feed
**Priority**: P0
**Description**: Live feed of sales transactions as they occur.
**Acceptance Criteria**:
- Sales appear in real-time without refresh
- Shows machine, product, price, timestamp
- Filterable by machine/location
- Recent sales count/badge

### SALES-02: Periodic reports
**Priority**: P0
**Description**: Daily, weekly, and monthly sales summaries.
**Acceptance Criteria**:
- Date range selection
- Summary metrics (total sales, revenue, transactions)
- Breakdown by machine and location
- Comparison to previous period

### SALES-03: Bestsellers view
**Priority**: P1
**Description**: Identify top-selling products across machines.
**Acceptance Criteria**:
- Ranked list of products by sales volume
- Filterable by time period and location
- Revenue and quantity metrics
- Visual indicators (trending up/down)

### SALES-04: CSV export
**Priority**: P1
**Description**: Export sales data to CSV for external analysis.
**Acceptance Criteria**:
- Export filtered/sorted data
- Date range selection
- Downloadable CSV file
- Include all relevant fields (timestamp, machine, product, price)

### SALES-05: Transaction details
**Priority**: P1
**Description**: View individual sale transaction information.
**Acceptance Criteria**:
- Full transaction record
- Machine, slot, product, price, timestamp
- Payment method (if available)
- Link to related telemetry

### SALES-06: Revenue metrics
**Priority**: P1
**Description**: Track revenue trends and totals.
**Acceptance Criteria**:
- Total revenue by period
- Revenue by machine/location
- Trend charts/graphs
- Projected revenue (optional)

---

## Price Management (PRICE)

### PRICE-01: View prices
**Priority**: P0
**Description**: Display current prices for all slots in a machine.
**Acceptance Criteria**:
- Price shown per slot in grid view
- Currency formatting
- Last price update timestamp

### PRICE-02: Change prices
**Priority**: P0
**Description**: Edit prices for individual slots.
**Acceptance Criteria**:
- Inline or modal price editing
- Validation (positive numbers, reasonable range)
- Immediate sync to machine via MQTT
- Success/error feedback

### PRICE-03: Bulk price updates
**Priority**: P1
**Description**: Update prices across multiple slots or machines.
**Acceptance Criteria**:
- Select multiple slots for update
- Percentage or fixed amount adjustment
- Preview changes before apply
- Apply to single machine or multiple

### PRICE-04: Price history
**Priority**: P2
**Description**: Audit log of price changes.
**Acceptance Criteria**:
- Timestamped price change records
- Who made the change (user)
- Old vs new price
- Filterable by machine/slot/date

---

## User Management (USER)

### USER-01: Authentication
**Priority**: P0
**Description**: Login via Supabase Auth with email/password.
**Acceptance Criteria**:
- Login page with email/password
- Session persistence
- Logout functionality
- Password reset capability

### USER-02: Role-based access
**Priority**: P0
**Description**: Different permissions for Admin vs Operator roles.
**Acceptance Criteria**:
- Admin: Full access to all features
- Operator: Read-only access (view machines, stock, sales)
- Operators cannot restart machines, change prices, or manage users
- Role visible in UI

### USER-03: User management (Admin only)
**Priority**: P1
**Description**: Admins can create and manage user accounts.
**Acceptance Criteria**:
- Add new users
- Assign roles (Admin/Operator)
- Assign machine access (for Operators)
- Deactivate/delete users

### USER-04: Machine assignment
**Priority**: P1
**Description**: Operators only see machines assigned to them.
**Acceptance Criteria**:
- Admin assigns machines to Operators
- Operator dashboard shows only assigned machines
- Filtering/grouping works within assigned set
- No access to unassigned machines

---

## Out of Scope (v2+ Considerations)

- Native mobile app (iOS/Android)
- Machine learning for demand prediction
- Multi-language internationalization
- White-label/custom branding per client
- Advanced analytics (cohort analysis, ML insights)
- Integration with external POS systems
- Maintenance scheduling and tracking
- Refund and dispute management
- Customer loyalty program integration

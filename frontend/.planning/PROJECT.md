# Vending Machine Management UI

## Project Overview

Web-based management interface for controlling and monitoring 10-100 vending machines via ESP32-S3 MDB cashless devices. Provides real-time visibility into machine status, stock levels, sales data, and remote control capabilities.

**Core Value**: Enable operators to efficiently manage vending machine fleets from a single dashboard with real-time insights and remote control capabilities.

**Target Users**:
- **Admin**: Full access to all machines, settings, and user management
- **Operator**: View-only access to assigned machines, stock, and sales data

**Tech Stack**:
- Nuxt 3 + Vue 3 + TypeScript
- shadcn-vue UI components
- Tailwind CSS
- Supabase (Auth, Database, Realtime)
- ESP32-S3 MDB integration (hardware layer)

## Requirements Summary

### Machine Management (MACH)
- MACH-01: View list of all machines with status (online/offline)
- MACH-02: Group machines by location
- MACH-03: View individual machine details and telemetry
- MACH-04: Restart machines remotely
- MACH-05: Enable/disable machines
- MACH-06: Real-time online/offline status updates
- MACH-07: View and acknowledge error/alert notifications

### Stock Management (STOCK)
- STOCK-01: Visualize machine slots (6 trays × 8 slots = 48 slots)
- STOCK-02: View current stock levels per slot
- STOCK-03: Force inventory reset/clearance
- STOCK-04: Product catalog management (add/edit products)
- STOCK-05: Low stock alerts and notifications

### Sales & Reporting (SALES)
- SALES-01: Real-time sales feed with live updates
- SALES-02: View daily/weekly/monthly sales reports
- SALES-03: View bestsellers by machine and overall
- SALES-04: Export sales data to CSV
- SALES-05: View POS/sales transaction details
- SALES-06: Revenue metrics and trends

### Price Management (PRICE)
- PRICE-01: View current prices per slot
- PRICE-02: Change prices remotely
- PRICE-03: Bulk price updates across machines
- PRICE-04: Price change history/audit log

### User Management (USER)
- USER-01: User authentication via Supabase Auth
- USER-02: Role-based access control (Admin/Operator)
- USER-03: Admin can manage user accounts
- USER-04: Operators only see assigned machines

## Constraints

**Technical Constraints**:
- ESP32-S3 MDB protocol compatibility
- Supabase Realtime for live updates
- Responsive design for desktop/tablet use

**Scale Constraints**:
- 10-100 machines in v1
- 48 slots per machine (6 trays × 8 slots)
- Real-time updates for sales and status

**Out of Scope (v1)**:
- Mobile native app
- AI/ML predictions
- Multi-language support
- White-label customization
- Advanced analytics (beyond basic reporting)

## Phase Overview

| Phase | Name | Goal | Key Deliverables |
|-------|------|------|------------------|
| 1 | Foundation & Auth | Project setup with authentication and basic layout | Nuxt 3 setup, shadcn-vue, Supabase auth, role-based access |
| 2 | Machine Dashboard | Machine list, status, and basic control | Machine grid, location grouping, online/offline status, restart/enable/disable |
| 3 | Stock Management | Visual slot management and inventory control | 6×8 slot grid, stock levels, force inventory, product catalog |
| 4 | Sales & Reporting | Sales visibility and reporting capabilities | Real-time sales feed, reports, bestsellers, CSV export |
| 5 | Price Management | Remote price configuration | Price viewing, editing, bulk updates, audit log |
| 6 | Real-time & Polish | Live updates and final refinements | Supabase Realtime integration, notifications, error handling, UI polish |

## Success Criteria (Project Level)

**When v1 is complete, users can:**
1. Log in as Admin or Operator with appropriate permissions
2. View all machines grouped by location with real-time status
3. Restart, enable, or disable machines remotely
4. See 48-slot inventory visualization with stock levels
5. Receive low stock alerts and force inventory resets
6. Monitor real-time sales with live feed updates
7. Generate daily/weekly/monthly reports and export CSV
8. Change prices remotely with audit trail
9. View error/alert notifications in real-time

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-16 | Nuxt 3 over Vite | Better routing, SSR options, file-based routing for admin panel |
| 2026-02-16 | shadcn-vue over Vuetify | Modern component library, better Tailwind integration |
| 2026-02-16 | Supabase over Firebase | PostgreSQL, realtime subscriptions, better Vue/Nuxt integration |
| 2026-02-16 | 6 phases for comprehensive UI | Balance between coverage and delivery speed |

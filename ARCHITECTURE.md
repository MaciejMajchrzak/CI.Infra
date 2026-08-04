# CodingInnovators Platform — Architecture

> Last updated: 2026-08-04 (session 6)

---

## Naming — decided forever

| Concept | Name | Why |
|---|---|---|
| Workspace / namespace | **Tenant** | Party model uses "Organization" and "Individual" — tenant is the platform layer above that |
| System operator | **system-admin** | Keycloak role, only CodingInnovators company emails |
| External integration | **Connector** | Industry standard (Kafka Connect, MuleSoft, HubSpot, Zapier) |

---

## Repository Layout

Repo names use dots, matching C# namespace prefixes exactly — zero mental mapping.

```
CI.Kernel                       ← shared contracts NuGet only, everything references this

Platform/
  CI.Platform.Gateway           ← YARP proxy, JWT, tenant-role injection
  CI.Platform.Identity          ← Keycloak adapter, JWT validation, scope middleware
  CI.Platform.Tenants           ← tenant CRUD, module registry, tier config, system-admin endpoints
  CI.Platform.Billing           ← us ↔ tenants: Stripe subscriptions, tier enforcement, usage metering
  CI.Platform.Workflow          ← business process orchestration (see below)
  CI.Platform.DevTools          ← dev bar, API keys, webhook config, event log, event replay
  CI.Platform.CountryConfig     ← country law matrix — taxes, legal forms, identifiers (see below)
  CI.Platform.Notifications     ← delivery: SMTP, SMS, push — all modules publish send commands, this delivers
  CI.Platform.Documents         ← PDF generation + email/document template rendering (used by Invoicing, Booking, Legal)
  CI.Platform.Search            ← OpenSearch abstraction, index management (see below)
  CI.Platform.PublicDiscovery   ← aggregated read-only DB for public booking search (see below)

Modules/  (business domains — per-tenant, each has own DB)
  CI.Module.Parties             ← Organization, Individual, Branch, roles, relationships
  CI.Module.Invoicing           ← invoices, credit notes, numbering series
  CI.Module.Legal               ← contracts, signatures, compliance tasks
  CI.Module.Payments            ← Stripe / Stripe Connect / Tap to Pay
  CI.Module.Booking             ← services, resources, appointments, bundles, subscriptions
  CI.Module.Catalog             ← goods, products, services catalog (different entity types)
  CI.Module.Warehouse           ← stock, movements, reservations
  CI.Module.HR                  ← employees, payroll (contracts live in Legal)
  CI.Module.Tasks               ← work tasks, projects, backlog, time logs
  CI.Module.Accounting          ← chart of accounts, double-entry ledger, KPiR, bank reconciliation, fixed assets, depreciation
  CI.Module.Marketing           ← loyalty points, promo codes, gift vouchers, campaigns, staff commissions

Connectors/  (no own DB — consume module events, talk to external APIs)
  CI.Connector.Slack
  CI.Connector.ComarchOptima
  CI.Connector.KSeF             ← PL mandatory e-invoicing (KSeF government API)
  CI.Connector.OpenBanking      ← bank feed / statement import (adapters per bank/provider)
  ...

CI.Infra                        ← Docker Compose, Helm, k8s, reusable GitHub Actions
```

**Clients (removed from scope):** Portal (Angular), Mobile (Flutter), Public (Astro) — not built.

---

## Service Pattern (every platform service and module)

```
CI.Platform.<Name>/
  src/
    CI.Platform.<Name>.Domain/         — entities, enums, value objects (no EF, no external deps)
    CI.Platform.<Name>.Core/           — command/query handlers, DTOs, interfaces
    CI.Platform.<Name>.Infrastructure/ — DbContext, migrations, repository implementations
    CI.Platform.<Name>.API/            — controllers, Program.cs, DI wiring
  tests/
    CI.Platform.<Name>.Tests/          — in-memory EF, xUnit, inherits ModuleArchitectureTests
  Dockerfile
  CI.Platform.<Name>.slnx
```

---

## Stack Decisions

| Concern | Choice | Notes |
|---|---|---|
| Runtime | .NET 10 | Not 9 |
| API style | Minimal APIs + controllers | |
| DB | PostgreSQL + PostGIS | Free, geo support |
| ORM | EF Core + Npgsql | |
| Search | OpenSearch | Geo + full-text (see CI.Platform.Search) |
| Messaging | MassTransit → RabbitMQ (start) | Kafka later if needed |
| Auth | Keycloak | Two roles: `system-admin`, `tenant-user` |
| Cache | IMemoryCache (L1) + Valkey/Redis (L2) | L1 invalidated via Redis pub/sub |
| Object storage | SeaweedFS (dev) / MinIO-compatible | S3-compatible |
| Secrets | OpenBao (Vault-compatible) | All connection strings pulled at boot |
| Observability | OpenTelemetry → Grafana + Jaeger | Trace every command across modules |
| API docs | Scalar | Replaces Swagger |
| Real-time push | SignalR (in CI.Platform.Workflow) | Workflow step updates, notifications |
| i18n | Keys from day 1 | Zero hardcoded user-facing strings anywhere |

---

## Handler Pattern — one handler, five trigger types

Business logic never knows how it was called.

```
HTTP Controller        ──┐
RabbitMQ Consumer      ──┤
Webhook Receiver       ──┼──► Command ──► CommandHandler ──► Result + Event
Workflow (any step)    ──┘   ← includes timer steps — there is no separate Scheduler service
```

**Rule:** If it changes state → `ICommand` → handler publishes an event OR carries `[NoEvent("reason")]`.
If it only reads → `IQuery` → synchronous, returns data, no event, never queued.

---

## No JSON in Domain Entities

**Rule: no JSON/JSONB columns on domain entities.** Everything is proper relational tables.

Exceptions where storing serialized text is correct:
- Webhook/event delivery payloads — outbound HTTP body, never queried inside, only replayed
- Workflow step input/output — debug snapshot, read as opaque blob

For everything else: proper child tables or typed EAV (see CountryConfig extended fields).

---

## Transport Abstraction

```csharp
// In CI.Kernel — all business code uses these
public interface IEventBus   { Task PublishAsync<T>(T evt, CancellationToken ct = default) where T : IEvent; }
public interface ICommandBus { Task<Result> SendAsync<T>(T cmd, CancellationToken ct = default) where T : ICommand; }
public interface IQueryBus   { Task<Result<T>> QueryAsync<T>(IQuery<T> query, CancellationToken ct = default); }

// Kafka-only — opt-in, for replay
public interface IEventLog   { IAsyncEnumerable<T> ReplayAsync<T>(DateTimeOffset from) where T : IEvent; }
```

**RabbitMQ vs Kafka:** RabbitMQ messages are consumed and gone. Kafka messages persist and can be replayed.
Switch to Kafka when: need event replay for new modules, audit log with retention, or > ~5M messages/day.

---

## Cross-Service Read Pattern

| Situation | Approach |
|---|---|
| Handler reads own module data | Repository direct |
| Handler reads another module — simple, fast | HTTP GET to that service |
| Handler reads another module — decoupling matters | RabbitMQ request/reply (MassTransit IRequestClient) |
| Frequently-read reference data | Redis projection |

---

## L1/L2 Cache — Kubernetes Pattern

```
Pod A writes → DB → publishes "cache:invalidate:{key}" to Redis pub/sub
All pods (A, B, C, D) subscribe → each evicts own IMemoryCache
Next read on any pod → L1 miss → L2 (Redis) hit → or DB if L2 also cold
```

---

## Events

**Cross-boundary events** (consumed by another service) → live in `CI.Kernel/Events/`.
**Internal domain events** (consumed within same service) → live in that service's `Domain/Events/`.

Connectors only reference a module's Domain NuGet package — never Core or Infrastructure.
They cannot touch the module's database.

Every command handler **must** publish an event OR carry `[NoEvent("reason")]`.
Architecture test enforces this.

---

## Concurrency — ETag, RowVersion, Distributed Lock

```
Layer 1 — Redis distributed lock        pessimistic, workflow/job level
  Key: lock:{module}:{entity-type}:{id}

Layer 2 — PostgreSQL xmin (RowVersion)  optimistic, DB level
  BaseEntity.RowVersion maps to the PostgreSQL xmin system column.
  DbUpdateConcurrencyException → Result.Failure(ErrorCodes.RECORD_LOCKED)

Layer 3 — ETag                          HTTP level, caching + UI conflict detection
  ETag = xmin as 8-digit lowercase hex in quotes: "0000001a"
  GET  → ETag: "0000001a"
  GET  → If-None-Match: "0000001a" → 304 Not Modified
  PUT  → If-Match: "0000001a"      → 412 Precondition Failed if stale
```

**CRITICAL: Child collection update pattern in handlers.**
Never call `entity.Children.Clear()` — causes `DbUpdateConcurrencyException` in EF InMemory.
Always use a repository method that calls `RemoveRange` + `AddRange` on the DbSet directly,
and compute aggregates from the new list (not from the navigation collection):

```csharp
var newLines = cmd.Lines.Select(l => new InvoiceLine { ... }).ToList();
repo.ReplaceLines(entity.Lines.ToList(), newLines);  // RemoveRange + AddRange on DbSet
entity.Total = newLines.Sum(l => l.Amount);          // NOT entity.Lines.Sum()
```

---

## Module Manifest

Every module publishes a manifest on startup to the manifest registry in CI.Platform.Workflow.
The manifest is auto-generated from available events, commands, and queries.

Workflow designer reads all manifests → shows available nodes.
Module starts → its nodes appear. Module stops → they grey out.

---

## CI.Platform.CountryConfig  ← NEW PLATFORM DOMAIN

**Rule: zero Polish-law-specific code anywhere in business modules.**
No hardcoded VAT%, PLN, NIP, REGON, ZUS, or any country-specific constant in domain entities.
All country-specific rules live in CI.Platform.CountryConfig and are referenced by code strings only.

### Entity model — named child tables, no JSON

```
CountryConfig
  ├── LegalForm[]                — code, name, description
  │                                 e.g. PL: JDG, sp. z o.o., SA | DE: GmbH, AG, UG | FR: SARL, SAS
  │
  ├── TaxIdentifierType[]        — code, name, validationPattern, isRequired, appliesTo (Org/Individual/Both)
  │                                 e.g. PL: NIP, REGON, KRS, PESEL | DE: Steuernummer, USt-IdNr
  │
  ├── ConsumptionTaxRate[]       — name, ratePercent, validFrom, validTo, isReduced, status (Past/Current/Planned)
  │                                 jurisdictionLevel? (National/State/County/City), jurisdictionCode? (e.g. "US-CA")
  │                                 temporal — past rates stored for invoice history, planned for forward-dating
  │                                 what countries call it: VAT (EU), GST (AU/NZ/CA/IN), Sales Tax (US), TVA (FR)
  │                                 jurisdictionLevel/Code nullable — EU/PL/GB national-only; US needs per-state
  │
  ├── IncomeTaxScheme[]          — code, name, type (Progressive|Flat|LumpSum|Other)
  │     └── IncomeTaxSchemeRate[]
  │           activityCode?, minIncome?, maxIncome?, ratePercent, description
  │           Progressive: income bracket bands (ThresholdAmount + RatePercent per band)
  │           Flat: single rate entry, no activityCode
  │           LumpSum (ryczałt): one rate per activity/PKD code — e.g. IT=12%, catering=3%, rental=8.5%
  │           A sole trader can operate under TWO LumpSum rates simultaneously (two activities)
  │
  ├── TaxObligation[]            — code, name, type (Income/Social/Health/VAT/Customs/Other), description
  │     └── TaxObligationComponent[]
  │           name, ratePercent, validFrom, validTo, paidBy (Employee/Employer/Both), isMandatory, description
  │           e.g. ZUS: emerytura, renta, wypadkowe, chorobowe, zdrowotne, FP, FGŚP — each is one component
  │
  ├── TaxDeductionCategory[]     — code, name, description, maxAmount?, validFrom, validTo
  │                                 e.g. PL: koszty uzyskania przychodu, ulga na dzieci
  │
  ├── AddressFormat[]            — fieldName, label, isRequired, sortOrder
  │                                 drives address entry forms per country
  │
  ├── EntityFieldDefinition[]    — entityType (Invoice/Party/Contract/...), fieldKey, label,
  │                                 dataType (String/Decimal/Date/Boolean), isRequired, validationPattern
  │                                 drives country-specific fields on entities via typed EAV
  │
  ├── CountryFilingCapability[]  — filingType (JPK_V7/SAF-T/MTD/1099/...), isMandatory, mandatoryFrom?, description
  │                                 which tax export formats this country requires → drives which connectors to activate
  │
  └── CountryEInvoiceCapability[]— systemName (KSeF/FatturaPA/MakingTaxDigital/...), isMandatory, mandatoryFrom?
                                     whether structured e-invoicing is mandatory and from when
```

### Country Plugin — computation that cannot be generic

Rates and legal forms are **data** (CountryConfig). Calculation logic and filing formats are **code** (ICountryPlugin).

```csharp
// In CI.Kernel — all modules can reference this interface
public interface ICountryPlugin
{
    string CountryCode { get; }
    Task<IReadOnlyList<TaxObligationAmount>> CalculateMonthlyObligationsAsync(TenantContext ctx, YearMonth period, CancellationToken ct);
    Task SubmitEInvoiceAsync(Invoice invoice, CancellationToken ct);
    Task<FilingExport> ExportFilingAsync(string filingType, DateRange period, CancellationToken ct);
}
```

Implementations: `PolandCountryPlugin`, `GermanyCountryPlugin`, `UKCountryPlugin`, etc.
Registered in DI as `IEnumerable<ICountryPlugin>`, resolved by `CountryCode` at call time.
**Adding a new country = seed CountryConfig rows + write one country plugin class.**
Generic code never references specific countries — only `CountryCode` strings.

### Country-specific entity fields — typed EAV (no JSON)

Domain entities (Invoice, Party, Contract) do NOT have country-specific typed properties.
Instead each module has an `ExtendedField` child table:

```
InvoiceExtendedField  (InvoiceId, TenantId, CountryCode, FieldKey, StringValue, DecimalValue, DateValue, BoolValue)
PartyExtendedField    (PartyId,   TenantId, CountryCode, FieldKey, ...)
ContractExtendedField (ContractId, TenantId, CountryCode, FieldKey, ...)
```

`FieldKey` matches `EntityFieldDefinition.fieldKey` in CountryConfig.
UI reads the definitions → builds the form dynamically → stores typed values in the EAV table.
Queryable, no JSON, schema-driven, country-agnostic at the entity level.

### What this means for specific fields

- **SKU** — NOT a typed property on catalog items or invoice lines.
  Goes in `CatalogItemExtendedField` / `InvoiceLineExtendedField` with key `"sku"` if the country/business needs it.
- **VAT rate** — stored as `VatRateCode` (string FK to CountryConfig.VatRate) + `VatRateSnapshot` (decimal % at time of invoice).
  Never a hardcoded `decimal VatPercent` property.
- **NIP/REGON** — stored in `PartyIdentifier[]` (TypeCode + Value), not as typed properties on Organization.
- **KSeF number** — `InvoiceExtendedField` with key `"pl-ksef-number"` for Polish invoices only.

---

## CI.Module.Parties — Organization, Individual, Branch

### Three entity types, no shared base table

Organization and Individual are **separate tables** (not table-per-hierarchy). They share no DB table because they will accumulate different columns over time.

```
Organization
  Id, TenantId, TradeName, CountryCode, LegalFormCode, IsActive, RowVersion
  + Identifiers[], Addresses[], Contacts[], BankAccounts[], ExtendedFields[]

Individual
  Id, TenantId, FirstName, LastName, DateOfBirth?, NationalityCode, IsActive, RowVersion
  + Identifiers[], Addresses[], Contacts[], BankAccounts[], ExtendedFields[]
```

Shared child tables use a polymorphic FK (`OwnerType: Organization|Individual`, `OwnerId: Guid`):
- `PartyIdentifier[]` — TypeCode + Value (NIP, REGON, passport, PESEL…)
- `PartyAddress[]` — TypeCode + full address fields + lat/lng
- `PartyContact[]` — Type (Phone/Email/Instagram/Facebook/TikTok/Website/LinkedIn/Other) + Value — **unbounded list**
- `PartyBankAccount[]` — IBAN, BIC, BankName, TypeCode
- `PartyExtendedField[]` — typed EAV for country-specific fields

### Branch — the bookable/operative unit

A Branch is a direct child of either an Organization or an Individual.
**Branch has its own name** — it is NOT the legal name. One Organization can have branches with completely different trading names.

```
Branch
  Id, TenantId, OwnerType, OwnerId (FK to Org or Individual)
  BranchName          — "Downtown Barber", "Airport Location", "Studio B"
  Description?
  IsActive
  Address             — street, city, postal, country, lat (double), lng (double)  ← PostGIS point too
  OpeningHours[]      — DayOfWeek, OpenTime, CloseTime, IsClosed, ExceptionDate?
  Contact[]           — same unbounded polymorphic list as party contacts
  Image[]             — Url, AltText, SortOrder, IsPrimary
  MaxBookingHorizonDays?
  AutoAcceptBookings  (bool)
  RowVersion
```

Branch is the entity that gets **published to PublicDiscovery** for public search.

### Roles — what role a Party plays in YOUR tenant context

```
PartyRole
  PartyId, OwnerType (Organization|Individual), TenantId
  Role: Client | Contractor | Supplier | OwnEntity | Partner
```

A party can hold multiple roles simultaneously (law firm = Client AND Contractor).

### Relationships — structural ownership/governance links between parties

```
PartyRelationship
  FromId, FromType, ToId, ToType, TenantId
  Type: IsShareholderOf | IsDirectorOf | IsSubsidiaryOf | IsMemberOf | IsAgentOf
  SharePercent? (for IsShareholderOf)
  ValidFrom, ValidTo?
```

### Module isolation rule

Other modules store `OrganizationId: Guid` or `IndividualId: Guid` as foreign references only.
Legal documents snapshot name/address at creation. Display reads via HTTP.

---

## CI.Module.Booking — Full Architecture

### BookingProfile — the entity people actually book with

A Branch can have one BookingProfile. BookingProfile holds booking-specific configuration that doesn't belong on the core Branch entity:

```
BookingProfile
  Id, TenantId, BranchId (FK)
  Currency (3-char, from CountryConfig)
  DefaultBookingMode
  RequiresDeposit (bool), DepositPercent?
  CancellationPolicyHours?    — free cancellation window
  MaxConcurrentBookings?
  RowVersion
```

### Service — what customers book

```
Service
  Id, TenantId, BranchId
  Name, Description?
  Category (ServiceCategoryId?)
  DurationMinutes?            — null if "from-to" style
  DurationFrom?, DurationTo?  — for flexible duration services
  BasePrice, Currency
  IsActive
  RequiresConfirmation (bool)
  AutoAccept (bool)           — overrides branch setting per service
  MaxParticipants (int, default 1)
  MaxDaysAhead?               — overrides branch setting per service
  RowVersion

ServiceVariant[]
  ServiceId, Name, PriceOverride?, DurationOverride?, Description?
  e.g. "Coupe" / "SUV" / "Limo" under "Car Detailing"

ServiceAcceptance[]
  ServiceId, Title, AcceptanceText, IsRequired
  MustSignBefore: Booking | Confirmation
  e.g. "Tattoo consent", "Medical disclaimer"

ServiceCategory
  Id, TenantId, Name, SortOrder, ParentCategoryId?
```

### Resource — who or what performs the service

```
Resource
  Id, TenantId, BranchId
  Name, Type (Staff | Room | Equipment)
  BookingUnit: BySlot | ByHour | ByDay
  BookingMode: FullOnly | ByPersonOnly | Mixed
  Capacity (int)              — max concurrent bookings (persons or sessions)
  IsAvailable (bool)
  EmployeeId?: Guid?          — nullable link to CI.Module.HR Employee (seniority, skills live there)
  RowVersion

ResourceServiceConfig[]       — override per (Resource × Service) combination
  ResourceId, ServiceId
  PriceOverride?, DurationOverride?
  e.g. Senior stylist charges +20% for same haircut service
```

### Booking modes explained

| BookingMode | Rule |
|---|---|
| `FullOnly` | One booking fills the resource regardless of capacity |
| `ByPersonOnly` | Multiple bookings allowed up to `Capacity`, each counts as 1 person |
| `Mixed` | First booking in a slot sets the mode: if Full → blocks all; if ByPerson → others can join up to capacity |

### Concurrent booking scenarios

- **Two people, same room, same time** → Room has `BookingMode=ByPersonOnly`, `Capacity=2`. Two separate appointments, same room, same slot.
- **Manicure + pedicure simultaneously** → Two separate resources (nail_station_1, nail_station_2). No conflict — availability checked independently per resource.
- **Sequential massages** → Two appointments, same resource, consecutive slots.
- **Spa double massage** → Two appointments, same room, same slot, ByPersonOnly capacity=2.

### Appointment

```
Appointment
  Id, TenantId, BranchId
  CustomerId (Guid, refs Parties), CustomerName (snapshot), CustomerEmail (snapshot)
  Status: Draft | AwaitingPayment | AwaitingConfirmation | Confirmed | InProgress | Completed | Cancelled | NoShow | Disputed
  Notes?, CancelReason?
  DepositPaidAt?, PaidAt?, StripePaymentIntentId?
  RowVersion

AppointmentLine[]             — services/variants booked (aggregate child)
  AppointmentId, ServiceId, ServiceVariantId?, ResourceId?
  ServiceNameSnapshot, VariantNameSnapshot
  StartAt, EndAt
  UnitPrice (snapshot), Qty, TotalPrice

AppointmentProduct[]          — goods sold alongside (aggregate child)
  AppointmentId, CatalogItemId, Name (snapshot), Qty, UnitPrice (snapshot)

AppointmentAcceptance[]       — signed consent forms (aggregate child)
  AppointmentId, ServiceAcceptanceId, Title (snapshot), SignedAt, SignerName
```

### Stay — grouping multiple appointments under one visit

A `Stay` links any number of independent `Appointment` records together. Used for hotel stays (room + spa + breakfast), multi-day retreat bookings, or any scenario where a guest makes multiple appointments that should be billed and managed together.

```
Stay
  Id, TenantId, BranchId
  CustomerId (Guid), CustomerName (snapshot), CustomerEmail (snapshot)
  CheckIn (date), CheckOut (date)
  Notes?
  Status: Active | CheckedOut | Cancelled
  RowVersion
```

`Appointment` gets a nullable `StayId: Guid?` FK. A standalone appointment (beauty salon, barber) has `StayId = null`. A hotel room appointment and a spa appointment during the same visit both have the same `StayId`. Payment links to `StayId` (single bill for the whole stay) or to individual `AppointmentId` (pay per service).

### Bundle booking

```
Bundle
  Id, TenantId, BranchId, Name, Description?, TotalPrice, Currency, IsActive

BundleItem[]
  BundleId, ServiceId, ServiceVariantId?, Qty
```

Booking a bundle creates N `AppointmentLine` rows from the bundle definition. Price is snapshotted from the bundle total.

### Subscription / recurring booking

```
BookingSubscription
  Id, TenantId, CustomerId, BranchId
  Status: Active | Paused | Cancelled | Expired
  RecurrenceRule              — iCalendar RRULE string: "FREQ=WEEKLY;BYDAY=MO;COUNT=12"
  ServiceId, ResourceId?, ServiceVariantId?
  StartDate, EndDate?
  MaxInstances?
  NextOccurrenceAt
  RowVersion

SubscriptionAppointment[]     — join table: subscription → generated appointments
  SubscriptionId, AppointmentId
```

Subscription generates appointments ahead (up to `MaxDaysAhead` on the service/branch). Cancelling one instance cancels that `Appointment` only. Cancelling the subscription marks all future instances.

### PublicDiscovery projection

On booking changes, `BranchPublishedEvent` / `BranchUpdatedEvent` / `BranchRemovedEvent` flow to `CI.Platform.PublicDiscovery`. That service maintains a denormalized `PublishedBranch` with embedded service/availability data and an OpenSearch document for geo+text queries.

---

## CI.Module.Payments — Generic Payment Provider Architecture

No provider-specific fields in domain entities. The provider is a plugin — swap Stripe for Mollie, Przelewy24, or Adyen by changing one registration.

```csharp
// In CI.Kernel — all modules can reference this
public interface IPaymentProvider
{
    string ProviderName { get; }  // "stripe" | "mollie" | "przelewy24" | "adyen" | ...
    Task<PaymentResult>    CreatePaymentAsync(PaymentRequest req, CancellationToken ct);
    Task<PaymentResult>    CreateMarketplacePaymentAsync(MarketplacePaymentRequest req, CancellationToken ct);
    Task<PaymentResult>    CreateTerminalPaymentAsync(TerminalPaymentRequest req, CancellationToken ct);
    Task<RefundResult>     RefundAsync(string providerTransactionRef, decimal amount, string reason, CancellationToken ct);
    Task                   HandleWebhookAsync(string payload, string signature, CancellationToken ct);
}
```

Three modes are always available regardless of provider (Standard, Marketplace, InPerson). Each provider exposes all three — if a provider doesn't support one mode, it throws `NotSupportedException`.

```
PaymentTransaction
  Id, TenantId
  Amount, Currency
  Status: Pending | Processing | Completed | Failed | Refunded | Disputed
  Method: Card | BankTransfer | Cash | Terminal | Voucher | LoyaltyPoints | Other
  Mode: Standard | Marketplace | InPerson
  ProviderName               — "stripe", "mollie", "przelewy24", "adyen", ...
  ProviderTransactionRef     — provider's own ID (PaymentIntent ID, order ID, etc.)
  ProviderAccountRef?        — for Marketplace: sub-account / connected merchant ID
  PlatformFeeAmount?         — platform cut in Marketplace mode
  TransferAmount?            — amount going to the merchant in Marketplace mode
  LinkedAppointmentId?
  LinkedStayId?              — for hotel-style: link to Stay instead of one appointment
  LinkedInvoiceId?
  FailureReason?
  RowVersion

  -- DB CHECK constraint (enforced at migration level):
  -- CHECK (num_nonnulls(LinkedAppointmentId, LinkedStayId, LinkedInvoiceId) <= 1)
  -- A payment is for exactly one primary subject. Invoice links back via Invoice.LinkedPaymentId.

Refund[]                     — aggregate child
  PaymentTransactionId
  Amount, Reason
  Status: Pending | Approved | Rejected
  ProviderRefundRef?         — provider's own refund ID

MerchantAccount              — per-branch provider account (Marketplace mode)
  Id, TenantId, BranchId
  ProviderName               — matches PaymentTransaction.ProviderName
  ProviderAccountRef         — e.g. Stripe Connect account ID, Mollie org ID
  IsActive, ChargesEnabled, PayoutsEnabled
  RowVersion
```

**FinancialDaySummary and multi-currency:** one row per `(TenantId, Date, Currency)` — never sum across currencies. Tenants operating in EUR and PLN get two rows per day, one per currency.

---

## CI.Platform.Workflow — Redesign

### Instance model

```
WorkflowDefinition
  Graph of nodes + edges, trigger, compensation map, version

WorkflowInstance
  Status: Pending | Running | Paused | Completed | Failed | Cancelling | Cancelled | Compensating | Compensated
  StartedAt, CompletedAt, TotalDurationMs
  TimeoutAt?
  CancelledAt?, CancelReason?
  CurrentNodeId, TriggerPayload (text — not queried, only replayed)

WorkflowStepExecution         — one row per node execution
  NodeId, NodeName
  Status: Waiting | Running | Succeeded | Warning | Failed | Skipped | TimedOut | Compensated
  StartedAt, CompletedAt, DurationMs
  TimeoutAt?
  RetryCount, MaxRetries, NextRetryAt?
  WarningMessage?
  InputPayload (text), OutputPayload (text)   — debug snapshot, opaque blob
  ErrorMessage?
  CompensationStepId?         — FK to the step that compensates this one

WorkflowSignal                — human approval / external resume
  InstanceId, NodeId
  ExpectedSignalKey
  ReceivedAt?, ReceivedBy?
  Status: Waiting | Received | TimedOut

CompensationLog               — rollback audit trail
  InstanceId, StepId, CompensationAction, ExecutedAt, Result
```

### Operations

- **Cancel** → `Cancelling`, running steps finish current unit then stop, then `Cancelled`
- **Rerun whole** → new Instance from same Definition, preserves original TriggerPayload
- **Rerun step** → only on Failed steps; resets that StepExecution, re-executes from that node
- **Rollback (saga)** → walks backwards through `Succeeded` steps, runs each `CompensationStep` in reverse order, records in `CompensationLog`

### Node types — parallel execution and fire-and-forget

```
WorkflowNode.Type:
  Task          — call a handler, HTTP endpoint, or publish an event
  Condition     — if/else branch based on step output
  Timer         — WaitUntil(datetime) or WaitFor(duration)
  Signal        — wait for external input: human approval or webhook callback
  ParallelFork  — split into N concurrent branches, each runs independently
  ParallelJoin  — wait for branches before continuing; WaitFor: All | Any | N-of-M
```

```
WorkflowNode (additional fields)
  IsFireAndForget (bool)  — failure → Warning status; workflow continues regardless
  ContinueOnWarning (bool)— ParallelJoin does not block on fire-and-forget branches
```

How it works — like GitHub Actions jobs:
```
  Task: charge payment
    → ParallelFork (3 branches)
        Branch A: send email      IsFireAndForget=true  ← failure = Warning, never blocks
        Branch B: send SMS        IsFireAndForget=true
        Branch C: update PublicDiscovery
    → ParallelJoin (WaitFor=All, skips fire-and-forget branches)
  → Task: mark appointment Confirmed
```

Fan-in with partial wait — `ParallelJoin(WaitFor=Any)` continues as soon as the first branch completes; `WaitFor=N` requires N of M. Useful for: "wait for payment confirmation OR manual override signal, whichever comes first."

### Timer steps — no separate Scheduler service

Time-based triggers are Workflow steps. There is no `CI.Platform.Scheduler`.

Supported timer step types:
- **WaitUntil(datetime)** — pause instance until an absolute moment (e.g. `appointment.StartAt − 24h`)
- **WaitFor(duration)** — pause for a relative duration (e.g. 90 days to detect lapsed clients)

```
WorkflowTimer                 — one row per waiting timer step
  InstanceId, StepId
  FireAt (datetime, indexed)
  Status: Waiting | Fired | Cancelled
```

A background poller queries `WHERE FireAt <= now AND Status = Waiting`, fires each due timer, and resumes the workflow instance from that step. Persists across service restarts — no in-memory timers, no cron.

Examples of what this replaces a separate scheduler with:
- Appointment reminder → `AppointmentConfirmed` starts workflow → `WaitUntil(StartAt − 24h)` → send notification
- Lapsed client → `AppointmentCompleted` starts workflow → `WaitFor(90 days)` → check if rebooked → if not, send campaign
- Birthday voucher → `CustomerCreated` starts workflow → `WaitUntil(nextBirthday − 7 days)` → send voucher

### Real-time UI — SignalR

`WorkflowStepStatusChanged` event → SignalR hub → client receives live node updates.
Same SignalR connection reused for notifications, booking updates.

---

## CI.Platform.DevTools — Stripe-style Developer Mode

Not a separate page — a collapsible drawer at the bottom of any screen.
Visible only when the tenant has dev mode enabled.

### Drawer content (live feed)
- Last N API calls: method, path, status code, latency
- Events fired: name, payload
- Workflow runs triggered
- Active webhook deliveries

### Dedicated pages
- **API Keys** — public/secret key pair, scoped (`invoicing:read`, `booking:write`, etc.), revocable
- **Webhooks** — register URL, choose event types, HMAC signing secret (private key shown once only), delivery log with response body + retry button
- **Event log** — every domain event, filterable by type/time, replayable to any webhook endpoint
- **Workflow runs** — graph with live step status (same visualization as workflow engine)

### Entity model

```
WebhookEndpoint
  Id, TenantId, Name, Url, SigningSecretHash, SigningSecretPrefix (first 8 chars, shown in UI)
  EventTypeFilter[]   — which event types to deliver
  IsActive, RowVersion

WebhookDelivery       — append-only
  EndpointId, TenantId, EventType
  Payload (text — outbound HTTP body, replayed as-is, not queried inside)
  Status: Sent | Failed | Retrying
  AttemptedAt, ResponseCode?, ResponseBodyPreview?, DurationMs?, FailureReason?
  RetryCount

ApiEventLog           — append-only, powers the dev bar feed
  TenantId, ActorId, Method, Path, StatusCode, DurationMs
  RequestBodyPreview?, ResponseBodyPreview?
  OccurredAt

FeatureFlag
  Id, TenantId, Name, Key (unique per tenant), IsEnabled, Description?

ApiKey
  Id, TenantId, Name, KeyHash, KeyPrefix (first 8), Scopes, ExpiresAt?, IsRevoked
```

---

## CI.Platform.Search — OpenSearch Abstraction

One shared service owns all OpenSearch index definitions and the `ISearchIndexer<T>` abstraction.
Modules push to their index on write events; consumers query via the search service HTTP API.

### Indexes

| Index | Primary use | Geo? |
|---|---|---|
| `branches` | Public discovery — find nearby bookable places | ✅ lat/lng |
| `services` | Search services within a branch/area | ✅ inherited |
| `parties` | CRM search — clients, contractors | ❌ |
| `tasks` | Task search within tenant | ❌ |
| `invoices` | Invoice search, buyer name, number | ❌ |
| `catalog` | Product/service catalog search | ❌ |

### Rule
- Modules publish domain events → CI.Platform.Search consumes → updates index
- Deletes propagate: `BranchDeletedEvent` → remove from `branches` index
- Search service never reads module DBs directly

---

## CI.Platform.PublicDiscovery — Aggregated Public Search DB

Separate service with its own DB. Serves unauthenticated public consumers (booking search widget, public site).

No per-tenant data is ever queried directly for public reads — only PublicDiscovery data.

```
PublishedBranch
  Denormalized: BranchName, Address, lat/lng, OpeningHours, Images,
                IsAvailableToday, AverageRating, ReviewCount
  Embedded services list (top N active services)

PublishedService
  BranchId, Name, DurationMinutes, BasePrice, Currency, CategoryName

PublishedAvailability
  BranchId, ServiceId, Date, AvailableSlots (int)
  Recomputed by AvailabilityWorker (background job)
```

Publish flow: `BranchPublishedEvent` → `PublicDiscoveryConsumer` → upsert `PublishedBranch` + push to OpenSearch `branches` index.
Delete flow: `BranchRemovedEvent` → delete from PublishedBranch + remove from OpenSearch.

### Availability — event-driven primary, scheduled reconciliation

`PublishedAvailability` is **not** maintained only by a background worker. Every booking change updates it immediately via dedicated event consumers:

| Event | Consumer action |
|---|---|
| `BookingCreatedEvent` | Decrement available slots for that service + date |
| `BookingCancelledEvent` | Increment available slots |
| `BookingCompletedEvent` | Mark slot as used (historical) |
| `ServiceUpdatedEvent` | Recalculate affected date range |
| `ResourceBlockedEvent` | Mark resource unavailable for blocked period |
| `OpeningHoursChangedEvent` | Recalculate affected dates |

`AvailabilityWorker` runs as a **reconciliation job** (nightly or on-demand) to catch any drift from missed events or race conditions. It is NOT the primary update path.

---

## CI.Module.Catalog — Goods vs Products vs Services

Three distinct entity types — different shapes, different inventory rules:

```
Good          — physical item with stock (trackable in Warehouse)
              Name, Sku? (ExtendedField), Weight?, Unit, CurrentStock (from Warehouse events)

Product       — manufactured/packaged item, may or may not track stock
              Name, Brand?, Sku? (ExtendedField), Unit

ServiceItem   — time-based, no stock, links to Booking module
              Name, DefaultDurationMinutes, DefaultPrice
```

**SKU is NOT a typed property** on any of these. It goes in `CatalogItemExtendedField` with key `"sku"` when the tenant's country/workflow requires it. Same for barcode, GTIN, etc.

All three share:
- `CatalogItemExtendedField[]` — typed EAV for country/business-specific attributes
- `PriceHistory[]` — validFrom, validTo, price, currency
- `CategoryId?` — shared `CatalogCategory` tree
- `Image[]`

---

## CI.Platform.Notifications — Real Delivery Layer

Notification *modelling* (when to send, to whom) lives per-module or in Workflow timer steps.
CI.Platform.Notifications is the **delivery service** — receives send commands and dispatches to the right channel.

| Channel | Provider |
|---|---|
| Email (SMTP) | Resend / Mailgun / SES — tenant brings own or uses platform default |
| SMS | Twilio / Vonage |
| Push (FCM/APNs) | Firebase (Android), APNs (iOS) |
| In-app | SignalR hub in CI.Platform.Workflow |

```csharp
// Any module publishes this — Notifications service consumes it
record SendNotificationCommand(
    Guid TenantId,
    string Channel,        // "email" | "sms" | "push" | "in-app"
    string Recipient,      // email address, phone number, device token, or userId
    string TemplateKey,    // maps to a template in CI.Platform.Documents
    object TemplateData,   // key-value bag passed to template renderer
    string? IdempotencyKey // prevents duplicates on retry
) : ICommand;
```

```
NotificationLog               — append-only delivery record
  TenantId, Channel, Recipient, TemplateKey
  Status: Queued | Sent | Failed
  SentAt?, FailureReason?, IdempotencyKey?
```

---

## CI.Platform.Documents — PDF Generation + Template Rendering

Used by: Invoicing (invoice PDFs), Booking (confirmation emails), Legal (contract PDFs), Notifications (email bodies).

- Renders Handlebars templates for email subjects and bodies
- Renders HTML → PDF (headless Chromium) for invoices, contracts, reports
- Tenants can override platform default templates with their own branded versions

```
DocumentTemplate
  Id, TenantId? (null = platform default), Key, Type: Email | PDF | Preview
  SubjectTemplate?    — for email channel only (Handlebars)
  BodyTemplate        — Handlebars string
  LanguageCode        — "pl", "en", "de", etc.
  IsDefault           — true on platform defaults, false on tenant overrides
  RowVersion
```

**Rule:** PDF rendering is async (Workflow step) for documents > 1 page; synchronous for previews and confirmation emails.

---

## CI.Module.Marketing — Loyalty, Campaigns, Vouchers, Commissions

Isolated from Booking because these features will also apply to future Catalog/e-commerce.
Booking, Invoicing, and Catalog push events → Marketing consumes them → awards points, triggers campaigns.

### Entity model

```
// Loyalty
LoyaltyProgram
  Id, TenantId, BranchId?
  PointsPerCurrencyUnit   — e.g. 1.0 = 1 point per 1 PLN
  PointsExpiryDays?
LoyaltyTier[]
  ProgramId, Name, MinPoints, BenefitType (DiscountPercent|FreeService|PriorityBooking|FreeCancel), BenefitValue?
CustomerLoyaltyBalance
  TenantId, CustomerId, ProgramId, Points, LifetimePoints, CurrentTierName
LoyaltyTransaction          — append-only
  CustomerId, ProgramId, PointsDelta, Reason (Earned|Redeemed|Expired|Adjusted)
  LinkedAppointmentId?, LinkedInvoiceId?, OccurredAt

// Gift vouchers
Voucher
  Id, TenantId, Code (unique), Type: GiftCard | ServiceCredit | DiscountPercent | DiscountFixed
  Value, Currency, ExpiresAt?, MaxUses?, UsedCount
  Status: Active | Exhausted | Expired | Revoked
  LinkedCampaignId?
VoucherRedemption           — append-only
  VoucherId, CustomerId, RedeemedAt, AmountUsed, LinkedAppointmentId?, LinkedInvoiceId?

// Promo codes
PromoCode
  Id, TenantId, Code, Type: DiscountPercent | DiscountFixed | FreeService
  Value, ValidFrom, ValidTo?, MaxUses?, UsedCount, MinOrderAmount?
  AppliesTo: All | ServiceCategory | SpecificService, AppliesToId?

// Campaigns (orchestrated by Workflow timer steps)
Campaign
  Id, TenantId, BranchId?
  Type: Birthday | LapsedClient | Manual | LastMinuteDiscount
  Status: Draft | Scheduled | Running | Completed | Cancelled
  TargetSegment: AllCustomers | LoyaltyTier | CustomTag, SegmentValue?
  Channel: Email | SMS | Push
  TemplateKey               — → CI.Platform.Documents
  VoucherId?                — optional reward attached
  ScheduledAt?, ExecutedAt?
CampaignRecipient           — append-only
  CampaignId, CustomerId, Status: Queued | Sent | Failed, SentAt?

// Staff commissions
CommissionRule
  Id, TenantId, ResourceId (Staff type only)
  Type: PercentOfRevenue | FixedPerAppointment, Value
  AppliesTo: All | SpecificService, AppliesToId?
CommissionEntry             — append-only
  ResourceId, AppointmentId, Amount, CalculatedAt
  Status: Pending | Approved | Paid
```

---

## CI.Module.Accounting — Scope

The largest domain gap vs Xero and Comarch. Accounting is **separate from Invoicing** — Invoicing is a document store; Accounting reads from it via events.

**Rule:** Accounting never queries Invoicing or Payments DBs directly. It consumes `InvoiceIssuedEvent`, `PaymentCompletedEvent`, etc. and creates its own journal entries.

```
// Chart of accounts
AccountPlan                   — one per tenant
ChartAccount
  Id, TenantId, Code, Name, Type (Asset|Liability|Equity|Revenue|Expense)
  IsSystemAccount, ParentId?

// Double-entry ledger
JournalEntry                  — immutable once posted
  Id, TenantId, PostedAt, Description
  LinkedInvoiceId?, LinkedPaymentId?, LinkedExpenseId?
JournalLine[]                 — two or more; sum(Debit) must equal sum(Credit)
  EntryId, AccountCode, Debit?, Credit?, Description?
  ActivityCode?               — for ryczałt: tags which IncomeTaxSchemeRate applies (e.g. "pl-pkd-6201" → IT 12%)
                                null for non-LumpSum tenants; PolandCountryPlugin reads it for tax calculation

// KPiR (Polish simplified bookkeeping) is NOT a separate entity.
// It is an export format generated on demand:
//   PolandCountryPlugin.ExportFilingAsync("kpir", period) reads JournalEntry rows
//   and formats them per the legal KPiR template. Same pattern as JPK_V7.

// Live analytics — no separate reporting module
FinancialDaySummary           — one row per (TenantId, Date, Currency); never sum across currencies
  TenantId, Date, Currency
  Revenue, Costs, VatCollected, VatPaid, NetIncome
  UpdatedAt
// Hours/days/weeks/months/years = range query on Date, no runtime aggregation.
// Tax simulation (zasady ogólne vs liniowy vs ryczałt) and legal-form comparison
// are pure calculations: PolandCountryPlugin.SimulateTaxScenariosAsync(tenantId, year)
// runs different formulas over FinancialDaySummary — no new storage needed.

// Expenses
ExpenseClaim
  Id, TenantId, SubmittedBy (UserId), Date, Description, Category
  Amount, Currency, VatAmount?
  Status: Draft | Submitted | Approved | Rejected | Reimbursed
  ReceiptUrl?
MileageRecord
  Id, TenantId, UserId, Date, Km (decimal), PurposeDescription
  RatePerKm (snapshot from CountryConfig), Amount

// Fixed assets
FixedAsset
  Id, TenantId, Name, Category, PurchaseDate, PurchaseValue, Currency
  DepreciationMethod: StraightLine | Declining
  UsefulLifeMonths, CurrentBookValue, LastDepreciatedAt
  IsDisposed, DisposedAt?
DepreciationEntry             — append-only
  AssetId, Period (YYYY-MM), Amount, BookValueAfter

// Bank reconciliation
BankAccount
  Id, TenantId, IBAN, BankName, Currency, CurrentBalance, LastSyncedAt?
BankTransaction               — imported, append-only
  AccountId, TenantId, ValueDate, Amount, Currency, Description
  Status: Unmatched | Matched | Ignored
  MatchedInvoiceId?, MatchedPaymentId?
```

---

## CI.Module.Legal — Scope Clarification

Legal owns all signed documents including:
- **Contracts** — this covers HR contracts too (CI.Module.HR references ContractId: Guid in Legal)
- NDA, ToS, Privacy Policy, SLA, Amendments
- Compliance tasks

CI.Module.HR does NOT have a Contract entity. It references Legal's `ContractId` for employment contracts.

---

## CI.Module.Tasks — Scope

Current state: `Project`, `WorkTask`, `TimeLog`, `TaskLabel`. Partial implementation.

**Future scope (not yet built):**
- Backlog management with priority ordering
- Gantt chart data (StartDate, EndDate, Dependencies on WorkTask)
- Party integration: a `Project` can be linked to a `Client` (OrganizationId / IndividualId)
- Client collaboration: invite external party to a project scope (limited view)
- Request exchange: both sides can create tasks/requests within a shared project

---

## Transactional Outbox — Reliable Event Publishing

**Problem:** handler writes to DB, then publishes event to RabbitMQ. If the publish fails after the DB commit, the event is silently lost — `BookingCreatedEvent` vanishes, `PublishedAvailability` never decrements, `FinancialDaySummary` is stale.

**Rule: no handler ever calls `IEventBus.PublishAsync` directly.** Instead it writes to `OutboxMessage` in the same DB transaction. A background publisher reads and delivers.

```
OutboxMessage                 — one table per module DB
  Id (Guid), TenantId
  EventType (string)          — fully-qualified event type name
  Payload (text)              — serialized event, replayed as-is — outbound only, never queried inside
  CreatedAt, ProcessedAt?
  Status: Pending | Delivered | Failed
  RetryCount, LastError?
```

```
OutboxPublisher (BackgroundService per module)
  1. SELECT TOP 50 WHERE Status = Pending ORDER BY CreatedAt  (with row-level lock)
  2. Publish each to RabbitMQ
  3. UPDATE Status = Delivered, ProcessedAt = now
  4. On failure: UPDATE RetryCount++, Status = Failed after MaxRetries
```

**Idempotency on consumers:** RabbitMQ is at-least-once. Every `IEventConsumer<T>` that writes to a projection or fires a side effect must track processed message IDs:

```
ProcessedEvent                — one table per module DB
  MessageId (Guid, unique index)
  ProcessedAt
```

Consumer checks `ProcessedEvent` before acting. If already processed → ack and skip. This prevents double-decrement on `PublishedAvailability`, double-row on `FinancialDaySummary`, etc.

---

## WorkflowDefinition Versioning

```
WorkflowDefinition
  Id, TenantId, Name
  Version (int)               — incremented on every publish
  IsActive (bool)             — only one active version per name per tenant

WorkflowInstance
  DefinitionId, DefinitionVersion   — pins to the version it started on
```

A definition change publishes a new version. Running instances continue on their pinned version. Arch test: `WorkflowInstance.DefinitionVersion` must equal the `WorkflowDefinition.Version` it was started from — enforced at creation, never updated after.

---

## Architecture Rules (enforced by CI.Kernel.ArchTests)

| Rule | Catches |
|---|---|
| Domain → no Core/Infra/API | Service logic in Domain |
| Core → no Infra/API | DB queries from service layer |
| Controllers → no DbContext | Bypassing service layer |
| **Controllers inject only ICommandBus + IQueryBus — no individual handler classes** | N-handler constructor bloat; handlers must be resolved by the bus, not injected directly |
| Events end with `Event` | Missing suffix |
| Commands end with `Command` | Inconsistent naming |
| Queries end with `Query` | Inconsistent naming |
| Handlers are sealed | Inheritance on handlers |
| Services are sealed | Inheritance on services |
| Domain → no other modules | Direct module coupling |
| Controllers have `[Authorize]` or `[AllowAnonymous]` | Accidentally public endpoint |
| Controllers have `[RequireModule]` or `[AllowWithoutModule]` | Endpoint reachable without enabling module |
| AdminControllers have `[RequireSystemAdmin]` | Unprotected admin endpoint |
| Command handlers inject IEventBus OR carry `[NoEvent]` | Write without event |
| Cross-boundary events live in CI.Kernel | Event only in module domain |
| No JSON columns on domain entities | Country/config data serialized into DB |
| No country-specific typed properties on entities | PL/DE/FR hardcoding in domain |
| **No provider-specific field names on PaymentTransaction** | Scan for properties prefixed Stripe/Mollie/Adyen/Paypal — breaks provider abstraction |
| **WorkflowDefinition must have Version (int) property** | Running instances corrupt if definition changes under them |
| **IEventConsumer implementations must reference ProcessedEventId or OutboxMessageId** | At-least-once delivery without idempotency = duplicate side effects |
| **FinancialDaySummary written only from IEventConsumer, never from ICommandHandler** | Projection updated synchronously on write defeats the event-driven model |
| **If XCreatedConsumer exists in PublicDiscovery, XCancelledConsumer must also exist** | Availability decrements on booking but never recovers on cancellation |
| **Entities with IsActive/IsArchived must filter it in every repository query** | Soft-deleted records leaking into results |
| **Cross-module references in billing/legal documents must snapshot name+price at creation** | Legal immutability — price/name changes must not alter past documents |

---

## CI.Platform.Billing — Full Architecture

### Plan tiers

Plans are configurable DB entities — not enums, not constants. They have a stable `Code` slug (`free` / `pro` / `business` / `enterprise`) and can have time-limited overrides (promotional plans) via `ValidFrom` / `ValidTo`.

One global plan tier per tenant. Module-level subscriptions (e.g. "buy Accounting separately") are NOT in scope — plan controls what modules are allowed and what limits apply across the board.

```
Plan
  Id, Code (unique slug), Name, Description?
  IsSystem (bool)      — true = protected from delete; seeded plans are system plans
  IsPublic (bool)      — false = admin-only / enterprise negotiated plan
  IsActive (bool)
  SortOrder (int)
  ValidFrom?, ValidTo? — time-limited promotional plans
  StripeProductId?     — links to Stripe product for self-serve checkout
  RowVersion

PlanPrice             — one row per (Plan, Currency, Period) combination
  Id, PlanId (FK)
  CurrencyCode         — "EUR", "PLN", "USD", …
  Amount (decimal)
  Period: Monthly | Annually
  IsActive (bool)
  StripePriceId?
  → unique index on (PlanId, CurrencyCode, Period)

PlanAllowedModule     — join table: which modules a plan grants access to
  Id, PlanId (FK), ModuleCode (string slug)
  → unique index on (PlanId, ModuleCode)

ModuleFeatureLimit    — per-plan, per-module limit rows
  Id, PlanId (FK), ModuleCode, LimitKey, LimitValue (long? — null = unlimited)
  → unique index on (PlanId, ModuleCode, LimitKey)
```

### Seeded plan limits

| Plan | LimitKey | Value |
|---|---|---|
| free | platform.max_users | 3 |
| free | platform.max_storage_gb | 5 |
| free | booking.max_branches | 1 |
| free | booking.max_resources | 3 |
| free | booking.max_activities | 5 |
| free | booking.transaction_fee_bps | 500 (= 5.00%) |
| free | invoicing.max_invoices_per_month | 0 |
| pro | platform.max_users | 15 |
| pro | platform.max_storage_gb | 50 |
| pro | booking.max_branches | 3 |
| pro | booking.max_resources | 20 |
| pro | booking.transaction_fee_bps | 200 (= 2.00%) |
| pro | invoicing.max_invoices_per_month | 50 |
| business | platform.max_users | 50 |
| business | platform.max_storage_gb | 500 |
| business | booking.transaction_fee_bps | 100 (= 1.00%) |
| business | invoicing.max_invoices_per_month | 500 |
| business | hr.max_employees | 50 |
| business | warehouse.max_locations | 10 |
| enterprise | everything | null (unlimited) |
| enterprise | booking.transaction_fee_bps | 0 (negotiated per deal) |

Limits stored as basis points (`long`): 500 = 5.00%, 200 = 2.00%. Null = unlimited for any limit.

### Enterprise deals

A tenant can request an enterprise deal themselves (self-serve), or a system admin creates one manually after negotiating terms.

```
EnterpriseDeal
  Id, TenantId
  PlanId (FK — usually the "enterprise" plan)
  Status: Pending | Active | Expired | Cancelled
  NegotiatedPrice (decimal, can be 0)
  CurrencyCode, Period: Monthly | Annually
  ContractStart?, ContractEnd?
  Notes?, AssignedByAdminId?
  — infra overrides —
  DbTierOverride?      — "shared" | "own" | "own-server"
  StorageTierOverride? — "shared" | "own" | "own-server"
  RegionOverride?      — e.g. "eu-central-1" | "us-east-1"
  — limit overrides —
  MaxUsers?, MaxModules?, MaxStorageGb?
  AllowedModulesOverride? (CSV) — if set, replaces the plan's PlanAllowedModule list entirely
  RowVersion

EnterpriseDealModuleLimit    — per-deal module limit overrides (same keys as ModuleFeatureLimit)
  Id, EnterpriseDealId (FK), ModuleCode, LimitKey, LimitValue?
```

Enterprise deal lifecycle:
1. `RequestEnterpriseDealCommand` → creates `Status = Pending` (self-serve or admin-initiated)
2. `ConfigureEnterpriseDealCommand` → admin sets price, limits, infra overrides, module limit rows
3. `ActivateEnterpriseDealCommand` → sets `Status = Active`, wires deal to tenant's Subscription (sets `Subscription.EnterpriseDealId`), publishes `EnterpriseDealActivatedEvent`
4. `CancelEnterpriseDealCommand` → `Status = Cancelled`

### Subscription

```
Subscription
  Id, TenantId
  PlanId (FK)
  PlanPriceId? (FK → PlanPrice)   — null for enterprise / manual billing
  EnterpriseDealId? (FK)          — set when an active deal governs this subscription
  Status: Trialing | Active | PastDue | Cancelled
  StripeSubscriptionId?
  TrialEndsAt?, CurrentPeriodEnd?
  RowVersion
```

### Effective limits — merged view

`GetEffectiveLimitsQuery(TenantId)` returns `EffectivePlanLimitsDto`:
- Looks up tenant's active Subscription → Plan → PlanAllowedModules + ModuleFeatureLimits
- If `Subscription.EnterpriseDealId` is set, applies deal overrides on top:
  - `AllowedModulesOverride` CSV replaces plan module list entirely (if set)
  - `MaxUsers` / `MaxStorageGb` from deal override plan "platform" limits (if set)
  - `EnterpriseDealModuleLimit` rows override per-module limit values
- Falls back to the `free` plan when no subscription exists (fail-safe)

```
EffectivePlanLimitsDto
  TenantId, PlanCode, IsEnterprise
  AllowedModules: List<string>
  MaxUsers?: long, MaxStorageGb?: long
  ModuleLimits: Dictionary<string, Dictionary<string, long?>>
    e.g. { "booking": { "max_branches": 3, "transaction_fee_bps": 200 } }
```

Exposed as `GET /api/billing/tenants/{tenantId}/effective-limits` — consumed by other services via `IBillingClient`.

### Cross-service plan check — IBillingClient

`CI.Platform.Tenants` calls `CI.Platform.Billing` when a tenant tries to enable a module:

```csharp
// CI.Platform.Tenants.Core
public interface IBillingClient
{
    Task<EffectiveLimits?> GetEffectiveLimitsAsync(Guid tenantId, CancellationToken ct);
}

// EffectiveLimits — lightweight record (not the full DTO)
record EffectiveLimits(string PlanCode, List<string> AllowedModules, long? MaxUsers, long? MaxStorageGb);
```

`EnableModuleHandler` checks `AllowedModules.Contains(moduleId)` — returns `FORBIDDEN` if not on the plan.
`ModulesController` maps `FORBIDDEN` → HTTP 403 with message "Module not available on your current plan."

Fail-open: `HttpBillingClient` returns `null` on any exception → all modules allowed (prevents billing outage from locking out tenants). `NullBillingClient` used in local dev / tests when `Services:Billing` is not configured.

---

## Infrastructure Tiering — DB and Object Storage

Every tenant starts on **shared** infrastructure. Tier upgrades are gated by `EnterpriseDeal.DbTierOverride` / `StorageTierOverride` (set by admin after negotiating the deal).

### Database tiers

| Tier | Where | Connection string source |
|---|---|---|
| `shared` | Same PostgreSQL instance as all shared tenants | OpenBao: `db/shared/tenants/{tenantId}/{module}` |
| `own` | Own PostgreSQL database on the shared server | OpenBao: `db/own/{tenantId}/{module}` |
| `own-server` | Dedicated PostgreSQL server (separate droplet or managed DB) | OpenBao: `db/server/{tenantId}/{module}` |

**Rule:** Every service fetches its connection string from OpenBao at boot and on reconnect. The string itself encodes which tier is active — no tier-routing code in the application. Changing `DbTierOverride` means migrating data, updating the OpenBao path, and restarting the service.

Core platform DBs (`ci_platform`, `ci_keycloak`, `ci_tenants`, `ci_billing`) are on the shared PostgreSQL instance and are **never metered per-tenant** — they are platform infrastructure.

### Object storage tiers

| Tier | Where | Access pattern |
|---|---|---|
| `shared` | Shared SeaweedFS cluster, namespace prefix `tenants/{tenantId}/` | Platform-managed |
| `own` | Dedicated SeaweedFS bucket (same cluster, isolated namespace) | Platform-managed |
| `own-server` | Dedicated SeaweedFS cluster or external S3-compatible endpoint | Tenant-managed credential in OpenBao |

`IFileStorage` abstraction resolves the correct endpoint + prefix per tenant at runtime from OpenBao. No storage-tier-specific code in business modules.

---

## Resource Metering

`CI.Platform.Billing` is responsible for metering — not individual modules.

### TenantResourceSnapshot

Metering data is collected periodically and stored per tenant:

```
TenantResourceSnapshot      — append-only, one row per collection run per tenant
  Id, TenantId
  SnapshotAt (timestamp)
  StorageUsedBytes (long)   — from SeaweedFS tenant-prefix API or pg_database_size()
  DbSizeBytes? (long)       — for own/own-server tiers: actual DB size; null on shared (platform cost, not tenant)
  ActiveUsers (int)         — count of non-disabled users in this tenant
  ActiveModules (int)       — count of enabled modules
  Notes?                    — e.g. "shared-tier estimate" when exact per-tenant data unavailable
```

Collection: background job in `CI.Platform.Billing` runs nightly (Workflow timer step). Per-tenant DB size queried with `SELECT pg_database_size('db_name')` (Postgres). Storage queried from SeaweedFS collection stats or prefix-level byte count.

**Shared-tier metering note:** `pg_database_size()` on a shared DB returns the full DB size, not the per-tenant slice. On shared tier, `DbSizeBytes` is null and sysadmin P&L estimates tenant cost from total shared DB cost / tenant count. On `own` and `own-server` tiers, `DbSizeBytes` is exact.

### CloudSku — Azure Retail Prices integration

Platform sysadmin can import Azure VM and managed DB SKUs to calculate the true cost of dedicated infrastructure offered to enterprise tenants.

```
CloudSku
  Id, Provider ("azure" | "do" | "aws" | …)
  Region (string)          — e.g. "polandcentral", "westeurope", "eastus"
  SkuName                  — Azure: "Standard_D2s_v5" | DO: "db-s-2vcpu-4gb"
  Type: Compute | ManagedDb | Storage | Bandwidth
  vCpus?, RamGb?, StorageGb?, BandwidthGb?
  PricePerHourUsd (decimal)
  PricePerMonthUsd (decimal)
  Currency ("USD")
  FetchedAt               — last sync from Azure Retail Prices API
  IsActive
```

Azure Retail Prices API: `GET https://prices.azure.com/api/retail/prices?$filter=…` — public, no auth required.
Sync is a background job triggered manually by sysadmin or scheduled weekly. Feature-flagged off by default (`feature_flags.azure_price_sync = false`).

### Sysadmin P&L view

`GET /api/admin/billing/pl-dashboard` returns:
- Total tenants by tier (shared / own / own-server)
- Estimated infra cost per enterprise tenant (from `CloudSku` matched to `EnterpriseDeal.DbTierOverride` / `RegionOverride`)
- MRR (monthly recurring revenue from active Subscriptions × PlanPrice)
- Estimated margin per tenant tier

This is a pure calculation — no separate entity. Reads `Subscription`, `PlanPrice`, `EnterpriseDeal`, `CloudSku`, `TenantResourceSnapshot`.

### Feature flags for future infra options

These are off by default and enabled per-tenant or globally by sysadmin:

| Flag key | Default | Controls |
|---|---|---|
| `infra.dedicated_db` | false | Whether `own` / `own-server` DB tier is offered |
| `infra.dedicated_storage` | false | Whether `own` / `own-server` storage tier is offered |
| `infra.multi_region` | false | Whether `RegionOverride` is honoured during provisioning |
| `billing.azure_price_sync` | false | Whether Azure Retail Prices API sync job runs |
| `billing.transaction_fee_enabled` | true | Whether transaction fees are deducted on Booking payments |

Stored as `FeatureFlag` rows in `CI.Platform.DevTools` (system-admin scope) or tenant-scoped flags for per-tenant enablement.

---

## Configuration Storage Hierarchy

Four layers, each with a strict rule about what belongs there. Never put something in a lower layer when a higher one owns it.

### Layer 1 — appsettings / environment variables

**What:** infrastructure bootstrap only. Must be readable before the DB is up.

| Belongs here | Does NOT belong here |
|---|---|
| DB connection strings | Grace period durations |
| Service-to-service URLs (Services:Billing) | Feature flags |
| Secrets (Keycloak client secret, RabbitMQ password) | Tenant lifecycle timelines |
| OTLP endpoint | Data retention periods |
| Keycloak authority | Any business rule |

**Rule:** if it can change without restarting the service, it doesn't belong in appsettings.

### Layer 2 — PlatformConfig table (sysadmin-managed)

Business rules that the platform operator controls. Stored in `ci_platform` DB, cached in Redis with `config:` prefix, TTL 5 minutes. Sysadmin UI at `/admin/platform-config`.

```
PlatformConfig
  Key   (string, unique)    — e.g. "lifecycle.past_due_days"
  Value (string)            — always stored as string, typed at read time
  Type  (String | Int | Bool | Json)
  Description
  UpdatedAt, UpdatedBy
```

Seeded defaults:

| Key | Default | Meaning |
|---|---|---|
| `lifecycle.past_due_days` | `14` | Days of full access after payment failure |
| `lifecycle.suspended_days` | `30` | Days of read-only access after suspension |
| `lifecycle.pending_termination_days` | `7` | Final warning window before archive |
| `lifecycle.data_export_url_valid_days` | `14` | How long the ZIP download link stays valid |
| `lifecycle.cold_storage_retain_years` | `7` | Years to keep archived tenant blob before hard-delete |
| `billing.retry_payment_attempts` | `3` | Stripe retry attempts during PastDue |
| `billing.retry_payment_interval_days` | `3` | Days between Stripe retry attempts |
| `notifications.past_due_reminder_days` | `[1,7,13]` | Days after PastDue when reminder emails fire |

**Cache pattern:** `GET config:lifecycle.past_due_days` → Redis hit → parse int. Redis miss → read `PlatformConfig` table → write to Redis with 5-minute TTL. Sysadmin update → write DB → publish `config:invalidate:*` to Redis pub/sub → all pods evict their local copies.

### Layer 3 — CountryConfig (seeded legal facts)

Country law is not an operator choice — it is a legal requirement. It lives in `CountryConfig` as seed data, not in `PlatformConfig`. Sysadmin can update it when laws change (e.g. when Poland extends or shortens a retention period), but it is not a tunable business parameter.

**DataRetentionPolicy** — new child of CountryConfig:

```
DataRetentionPolicy
  Id, CountryCode (FK → CountryConfig)
  DocumentTypeCode        — "invoice" | "accounting-book" | "employment-contract" | "payroll" | "personal-data" | "booking" | "general"
  RetentionYears (int)    — mandatory minimum; null = "until erasure request" (GDPR)
  CanBeDeletedOnRequest (bool)  — false for legal documents (invoice must be kept 5y even if GDPR request)
  LegalBasis              — e.g. "Art. 74 UoR", "§ 147 AO", "HMRC VAT Notice 700/21"
  Notes?
```

Seeded values:

| Country | DocumentType | Years | CanDelete | Legal basis |
|---|---|---|---|---|
| PL | invoice | 5 | false | Art. 74 UoR |
| PL | accounting-book | 5 | false | Art. 74 UoR |
| PL | employment-contract | 10 | false | Art. 94 KP (since 2019) |
| PL | payroll | 10 | false | Art. 94 KP |
| PL | personal-data | null | true | GDPR Art. 17 |
| PL | booking | null | true | GDPR Art. 17 |
| PL | general | null | true | GDPR Art. 17 |
| DE | invoice | 10 | false | § 147 AO |
| DE | accounting-book | 10 | false | § 147 AO |
| DE | personal-data | null | true | DSGVO Art. 17 |
| GB | invoice | 6 | false | HMRC VAT Notice 700/21 |
| GB | payroll | 3 | false | HMRC PAYE rules |
| GB | personal-data | null | true | UK GDPR Art. 17 |

**Rule:** when Billing archives a terminated tenant, it reads the tenant's `CountryCode` (from their OwnParty), loads `DataRetentionPolicy` rows for that country, and archives each document type according to its retention rule. Documents where `CanBeDeletedOnRequest = false` go to cold storage and are NOT deleted even on GDPR erasure request — the platform must inform the subject that legal retention overrides the request.

### Layer 4 — Tenant-level overrides

Where the plan explicitly permits it (enterprise deals). Already modelled in `EnterpriseDeal`. Not in scope for standard plans.

---

## Zero-Downtime DB Migrations

**Rule: the startup `MigrateAsync()` pattern is dev-only.** In production, migrations run as a separate step before deployment, not inside the service startup.

### Expand-contract pattern (3-phase deploy)

Every schema change that removes or renames something requires three separate deploys:

```
Phase 1 — Expand (deploy new version):
  Only ADD: nullable columns, new tables, new indexes.
  Old version and new version both work on the schema simultaneously.
  No data loss possible.

Phase 2 — Backfill (background migration job):
  Fill nullable columns with computed or migrated data.
  Run per-tenant for own-DB and own-server tiers (parallel, rate-limited).
  Set ModuleStatus = Migrating during this phase per tenant.
  Set ModuleStatus = Active when done.
  Shared tier: one DB, one job, fast.
  Own-DB tier: one job per tenant DB, runs concurrently up to N workers.
  Own-server tier: same, but may need VPN/tunnel to reach the dedicated server.

Phase 3 — Contract (next deploy, days or weeks later):
  Add NOT NULL constraints, remove old columns, rename columns.
  Safe because no running code reads the old schema anymore.
```

**Rule: additive-only migrations in Phase 1 never require a maintenance window.** Only Phase 3 can cause issues and only if Phase 2 was incomplete — the architecture test enforces that Phase 3 migrations are never deployed to a tenant whose Phase 2 job has not completed (`ModuleStatus = Active`).

### ModuleStatus — module-level health visible to the Gateway

`EnabledModule` in Tenants gets a `Status` field:

```
ModuleStatus: Active | Migrating | Degraded | Suspended
```

| Status | GET requests | POST/PUT/DELETE | Shown to user |
|---|---|---|---|
| Active | ✅ pass | ✅ pass | nothing |
| Migrating | ✅ pass | ❌ 503 + Retry-After | "Module is being updated, try again in a moment" |
| Degraded | ✅ pass | ⚠️ pass with warning header | "Module is experiencing issues" |
| Suspended | ❌ 402 | ❌ 402 | "Module suspended — update billing to restore access" |

Gateway reads `ModuleStatus` from a Redis projection (`module-status:{tenantId}:{moduleCode}`) on every request — no DB hit on the hot path. Migration job writes to DB + invalidates Redis key when it completes.

**Connector health** follows the same model. A connector (KSeF, Slack) sets itself to `Degraded` on startup if its external API is unreachable, `Active` when healthy. No DB involved — it's a heartbeat that writes the Redis key directly.

---

## Tenant Lifecycle After Non-Payment

### Status progression

```
Active
  ↓  PaymentFailedEvent (Stripe webhook)
PastDue  (0–N days, default 14 from PlatformConfig)
  ↓  PastDue timer expires and no payment received
Suspended  (0–M days, default 30)
  ↓  Suspended timer expires
PendingTermination  (0–P days, default 7)
  ↓  PendingTermination timer expires
Terminated
```

At any point, `PaymentSucceededEvent` → resets to `Active`, cancels all timer steps.

### What each status means at the API level

`Subscription.Status` is projected to Redis key `tenant-status:{tenantId}` (same cache pattern as ModuleStatus). Gateway reads it on every authenticated request.

| Status | Reads | Writes | UI |
|---|---|---|---|
| Active | ✅ | ✅ | — |
| PastDue | ✅ | ✅ | In-app banner: "Payment failed — update card to avoid interruption" |
| Suspended | ✅ | ❌ 402 | Banner: "Account suspended — reads only until billing is resolved" |
| PendingTermination | ❌ 410 Gone | ❌ 410 Gone | — (email only) |
| Terminated | ❌ 410 Gone | ❌ 410 Gone | — |

### Notification timeline (driven by Workflow timer steps)

```
PastDue Day 0:   Email "Payment failed, we'll retry in 3 days"
PastDue Day 1:   In-app notification
PastDue Day 7:   Email "Still unpaid — account will be suspended in 7 days"
PastDue Day 13:  Email "Last warning — suspension tomorrow"
PastDue Day 14:  → set Suspended, email "Account is now suspended (read-only)"

Suspended Day 1:  Email "Your data is safe but writes are blocked"
Suspended Day 16: Email "Account will be deleted in 14 days — export your data now"
Suspended Day 16: Auto-generate data export ZIP (background job)
Suspended Day 17: Email data export download link (valid for 14 days)
Suspended Day 29: Email "7 days until deletion"
Suspended Day 30: → set PendingTermination

PendingTermination Day 0: Email "All access blocked. Download link still valid"
PendingTermination Day 7: → archive DBs + S3, set Terminated

Terminated Day 0: Email "Account archived. Download link valid N more days"
```

### Data export ZIP (generated on Suspended Day 16)

Contents:
- All invoices as PDFs (rendered by CI.Platform.Documents)
- Invoices as JSON / CSV
- Appointments as CSV
- Parties (clients, contractors) as JSON
- Bookings as CSV
- Any other tenant-owned data as JSON

Stored in SeaweedFS cold bucket: `terminated/{tenantId}/export-{date}.zip`
Time-limited download URL: signed URL, valid `lifecycle.data_export_url_valid_days` (default 14).

### Archival (Terminated Day 0)

1. For each module DB the tenant has:
   - Export as SQL dump → store as `terminated/{tenantId}/{module}-{date}.sql.gz` in cold storage
   - Drop the tenant's own DB (own-DB tier) or mark their rows for deletion (shared tier)
2. Move SeaweedFS files from `tenants/{tenantId}/` prefix to `cold/{tenantId}/`
3. Read `DataRetentionPolicy` for the tenant's country:
   - Documents where `CanBeDeletedOnRequest = false` (invoices, accounting): kept in cold storage for `RetentionYears`
   - Everything else: scheduled for deletion after `lifecycle.cold_storage_retain_years` (default 7, from PlatformConfig)
4. Set `Tenant.IsTerminated = true`, `TerminatedAt = now`
5. Purge Redis keys for this tenant (`tenant-status:`, `module-status:`, `config:` projections)

### GDPR erasure request during active subscription

A tenant or end-customer can request erasure of personal data at any time:
- Personal data (name, email, phone in Parties, Appointments) → anonymised in-place (replaced with `[deleted]` + hash of original for deduplication)
- Documents where `DataRetentionPolicy.CanBeDeletedOnRequest = false` (invoices): NOT deleted — the platform must respond explaining that legal retention takes precedence, and what the exact legal basis is (from `DataRetentionPolicy.LegalBasis`)
- Booking history, analytics: deleted
- All deletion is logged in an append-only `GdprErasureLog` table

```
GdprErasureLog
  Id, TenantId, RequestedBy, RequestedAt
  SubjectType (Tenant | EndCustomer | Employee)
  SubjectId
  Status: Pending | PartiallyCompleted | Completed
  CompletedAt?
  RetainedDocumentTypes (CSV)  — types kept for legal reasons
  LegalBasisNote               — human-readable explanation sent to the requester
```

---

## GitHub Actions — Reusable Workflows

```yaml
# API services: build → test → Docker → GHCR → deploy
uses: MaciejMajchrzak/CI.Infra/.github/workflows/claude-service.yml@main

# NuGet packages: build → test → pack → push GitHub Packages
uses: MaciejMajchrzak/CI.Infra/.github/workflows/claude-nuget.yml@main
```

---

## System-Admin

Never impersonates. Always uses access-request flow:
1. `POST /admin/access-requests` → tenant owner approves
2. Time-limited access granted
3. Full audit trail of what was done during access window

---

## Module vs Connector

| | Module | Connector |
|---|---|---|
| Own DB | Yes | No |
| Emits domain events | Yes | Rarely |
| Has business logic | Yes | No — thin adapter only |
| References | CI.Kernel | CI.Kernel + target Module's **Domain NuGet only** |
| Example | Invoicing, Booking, HR | Slack, ComarchOptima, KSeF |

---

## Build Order

```
1. CI.Kernel                ← contracts NuGet
2. CI.Infra                 ← Docker Compose + GH Actions
3. CI.Platform.Tenants      ← validates full stack
4. CI.Platform.Users
5. CI.Platform.CountryConfig ← must exist before Invoicing, Parties, Legal
6. CI.Platform.Gateway
7. CI.Module.Parties        ← Organization, Individual, Branch
8. CI.Module.Invoicing      ← first business module
9. Everything else in parallel
```

---

## Live Infrastructure (DigitalOcean droplet 104.248.18.53)

| Service | Port | Notes |
|---|---|---|
| CI.Platform.Gateway | 80 | public entry point |
| Keycloak | 8080 | realm `ci-platform`, client `ci-platform-web` |
| PostgreSQL | 5432 | ci_platform, ci_keycloak, ci_tenants, ci_users, ci_billing |
| CI.Platform.Tenants | 5001 | tenant CRUD, module registry, plan enforcement |
| CI.Platform.Billing | 5006 | plans, subscriptions, enterprise deals, effective limits |
| RabbitMQ | 5672 / 15672 | messaging + management UI |
| Valkey | 6379 | Redis-compatible cache |
| Jaeger | 16686 | distributed tracing |
| Grafana | 3001 | dashboards |
| Prometheus | 9090 | metrics |
| SeaweedFS | 9333 / 8333 / 8888 | object storage |
| OpenBao | 8200 | secrets vault |

Deploy: push to `CI.Infra` main → GitHub Actions → `docker compose` on droplet.
`keycloak-setup.sh` runs on every deploy — idempotent.
Test credentials: `test / test` on `ci-platform` realm.

---

## Key Decisions Log

| Date | Decision | Reason |
|---|---|---|
| 2026-08-02 | `tenant` as top-level naming (not workspace/namespace/org) | "org" conflicts with Party model |
| 2026-08-02 | Repo names match C# namespaces exactly | Zero mental mapping |
| 2026-08-02 | One handler, five trigger types | Business logic never knows how it was called |
| 2026-08-02 | Module manifest auto-generated | Workflow designer gains nodes automatically |
| 2026-08-02 | CI.Platform.Workflow dedicated service | Single observable place for all processes |
| 2026-08-02 | Connectors reference only Domain NuGet | Cannot touch module DB |
| 2026-08-02 | system-admin never impersonates — access-request flow | Security audit trail |
| 2026-08-02 | DevTools = dev drawer at bottom of UI, not a page | Visible on any screen |
| 2026-08-02 | Cross-boundary events in CI.Kernel | No assembly dependency between services |
| 2026-08-02 | Start RabbitMQ, add Kafka via IEventBus swap | One config line to switch transport |
| 2026-08-02 | L1 + L2 cache with Redis pub/sub invalidation | Only correct pattern for K8s horizontal scaling |
| 2026-08-02 | RowVersion = PostgreSQL xmin | No extra column, Postgres manages automatically |
| 2026-08-02 | Three-layer concurrency: Redis lock + xmin + ETag | Each layer catches what the others miss |
| 2026-08-02 | Organization + Individual = separate tables | Will accumulate different columns over time |
| 2026-08-02 | PartyRole + PartyRelationship = separate tables | Roles = business context; Relationships = ownership/governance |
| 2026-08-02 | Other modules store PartyId: Guid only | Module isolation; legal docs snapshot at creation |
| 2026-08-02 | Never call entity.Children.Clear() in handlers | Causes DbUpdateConcurrencyException in EF InMemory |
| 2026-08-03 | CI.Platform.CountryConfig as dedicated platform domain | Country law must be configurable per country, not hardcoded |
| 2026-08-03 | No JSON columns on domain entities | Typed EAV (ExtendedField tables) instead; JSON only for outbound payloads |
| 2026-08-03 | SKU not a typed property — goes in ExtendedField | SKU is business/country-specific, not universal |
| 2026-08-03 | VatRate is a named child of CountryConfig with temporal validity | Past/current/planned rates all stored; needed for invoice history |
| 2026-08-03 | ZUS modelled as TaxObligation with TaxObligationComponent children | ZUS has N components (emerytura, renta, FP, …), each with own rate and payer |
| 2026-08-03 | Branch is direct child of Organization/Individual, has own name | No intermediate BusinessProfile layer; one legal entity → N named branches |
| 2026-08-03 | Contacts are unbounded polymorphic list (Phone/Instagram/TikTok/etc.) | Real businesses have multiple phones, multiple socials |
| 2026-08-03 | BookingMode enum: FullOnly / ByPersonOnly / Mixed | Covers hotel room (Full), capacity room (ByPerson), flex room (Mixed) |
| 2026-08-03 | ResourceServiceConfig for price/duration overrides per resource | Senior stylist charges more for same service; suite room costs more |
| 2026-08-03 | Appointment lines snapshot price and name | Invoice-style immutability; service price changes don't affect past bookings |
| 2026-08-03 | Subscriptions use iCalendar RRULE | Standard, handles weekly/monthly/custom recurrence |
| 2026-08-03 | PublicDiscovery = separate service + DB | Public search never touches per-tenant module DBs |
| 2026-08-03 | OpenSearch via CI.Platform.Search abstraction | Modules push to index on write; search service never reads module DBs |
| 2026-08-03 | Catalog has three entity types: Good, Product, ServiceItem | Physical goods (stock), packaged products, time-based services are genuinely different |
| 2026-08-03 | HR contracts → CI.Module.Legal (HR stores ContractId reference only) | Contract is a legal document; HR is employment administration |
| 2026-08-03 | Payments: Stripe standard + Stripe Connect + Stripe Tap to Pay | Platform-as-marketplace needs Connect; in-person needs Terminal |
| 2026-08-03 | Workflow step states include Warning and Compensated | Real pipelines produce warnings (not just pass/fail); saga pattern needs compensation state |
| 2026-08-03 | WorkflowSignal entity for human-approval steps | External actor resumes the workflow; not a timer — genuinely async wait |
| 2026-08-03 | Frontend clients (Portal/Mobile/Public) removed from scope | User decision |
| 2026-08-03 | No CI.Platform.Scheduler — timer steps live in CI.Platform.Workflow | Workflow already owns instance state; a separate timer service would be a second place to track the same lifecycle |
| 2026-08-03 | WorkflowTimer entity with FireAt index + background poller | Persists timers across restarts; WaitUntil and WaitFor as first-class step types |
| 2026-08-03 | VatRate gets jurisdictionLevel + jurisdictionCode (nullable) | US has state/county/city sales tax; EU countries have national-only rates; same entity covers both |
| 2026-08-03 | ICountryPlugin interface for computation that cannot be generic | Config (CountryConfig) drives UI/validation; plugins drive ZUS calculation, JPK export, KSeF submission — adding a country = seed data + one plugin class |
| 2026-08-03 | CountryFilingCapability + CountryEInvoiceCapability as CountryConfig children | Drives which connectors to activate per country — declarative not hardcoded |
| 2026-08-03 | CI.Platform.Notifications as dedicated delivery service | All modules publish SendNotificationCommand; one service handles SMTP/SMS/push delivery and idempotency |
| 2026-08-03 | CI.Platform.Documents for PDF + Handlebars template rendering | Shared by Invoicing, Booking, Legal, Notifications; tenants can override platform default templates |
| 2026-08-03 | CI.Module.Marketing isolated from Booking | Loyalty/campaigns/vouchers will also apply to Catalog and future e-commerce — not a Booking-specific concern |
| 2026-08-03 | CI.Module.Accounting is double-entry ledger + KPiR + bank reconciliation + fixed assets | Largest domain gap vs Xero/Comarch; reads Invoicing and Payments via events only — never cross-queries their DBs |
| 2026-08-03 | Accounting consumes events from Invoicing and Payments, never queries their DBs | Module isolation rule applied to accounting — InvoiceIssuedEvent → journal entry |
| 2026-08-03 | VatRate renamed to ConsumptionTaxRate; IncomeTaxScheme is a separate entity | VAT/GST and income tax are fundamentally different — one goes on transactions, the other on the tenant's annual tax form |
| 2026-08-03 | IncomeTaxScheme supports Progressive/Flat/LumpSum with per-activity rates | Ryczałt can have two rates simultaneously (e.g. IT 12% + catering 3%) — ActivityCode on JournalLine tags which rate applies |
| 2026-08-03 | KPiRRecord removed — KPiR is a PolandCountryPlugin export of JournalEntry | Not a domain entity; generated on demand from existing accounting data |
| 2026-08-03 | FinancialDaySummary projection replaces a separate reporting module | Event-driven daily row covers hours/days/weeks/months/years with range queries; no runtime aggregation |
| 2026-08-03 | Tax simulation and legal-form comparison are pure calculations, no storage | ICountryPlugin.SimulateTaxScenariosAsync reads FinancialDaySummary and runs multiple formulas |
| 2026-08-03 | SeniorityLevel removed from Resource; EmployeeId? nullable FK to HR added | Seniority, skills, qualifications live in HR — Resource is the bookable slot only |
| 2026-08-03 | Stay entity groups multiple Appointments under one visit | Enables hotel room + spa + breakfast under one stay/bill; standalone appointments have StayId = null |
| 2026-08-03 | PaymentTransaction uses ProviderName + ProviderTransactionRef (no Stripe fields) | IPaymentProvider plugin pattern — swap Stripe for Mollie/Przelewy24/Adyen with one DI change |
| 2026-08-03 | WorkflowNode adds ParallelFork, ParallelJoin (All/Any/N-of-M), IsFireAndForget | Email failure must not cancel a booking — fire-and-forget = Warning, not Failure |
| 2026-08-03 | PublicDiscovery availability is event-driven; AvailabilityWorker is reconciliation only | Every booking change must reflect immediately in public availability — scheduled worker only catches drift |
| 2026-08-03 | Controllers inject only ICommandBus + IQueryBus — never individual handler classes | Adding an endpoint must not require changing the constructor; bus resolves handler from DI |
| 2026-08-03 | Transactional Outbox pattern — no direct IEventBus.PublishAsync from handlers | Events survive DB commit even if RabbitMQ is temporarily unavailable |
| 2026-08-03 | ProcessedEvent table per module for consumer idempotency | At-least-once RabbitMQ delivery means duplicates will happen; idempotency prevents double side effects |
| 2026-08-03 | PaymentTransaction.Linked* fields: CHECK num_nonnulls <= 1 | A payment is for one subject; Invoice links back via Invoice.LinkedPaymentId |
| 2026-08-03 | MerchantAccount entity replaces provider-specific connect account entities | Generic per-branch provider account reference — swap providers without schema change |
| 2026-08-03 | FinancialDaySummary is per (TenantId, Date, Currency) — never sum across currencies | Tenants invoicing in EUR and PLN get two rows per day |
| 2026-08-03 | WorkflowDefinition has Version; WorkflowInstance pins to DefinitionVersion | Running instances must not be affected by definition changes published after they started |
| 2026-08-03 | Entities with IsActive/IsArchived must filter in every repository query | Soft-deleted records must never appear in normal query results |
| 2026-08-03 | Cross-module references in billing/legal documents must snapshot at creation | Price and name changes must not alter past legal documents |
| 2026-08-04 | Plans are configurable DB entities with stable Code slug, not enums/constants | Allows time-limited promotional plans, admin-created plans, enterprise overrides |
| 2026-08-04 | One global plan tier per tenant — not per-module subscriptions | Simpler billing model to start; module access controlled by PlanAllowedModule join table |
| 2026-08-04 | PlanPrice child table: one row per (Plan, CurrencyCode, Period) | Multi-currency pricing without duplicating plan entities |
| 2026-08-04 | ModuleFeatureLimit: per-plan per-module limit rows with null = unlimited | Limits are data, not code; sysadmin can change them without a deploy |
| 2026-08-04 | Transaction fee stored as basis points (long): 500 = 5.00% | Integer arithmetic avoids float precision issues in fee calculations |
| 2026-08-04 | EnterpriseDeal: pending → configure → activate lifecycle with full limit + infra overrides | Admin can set price to 0, null out any limit, override DB tier, storage tier, region |
| 2026-08-04 | GetEffectiveLimits merges plan limits with EnterpriseDeal overrides; falls back to free plan | Billing outage must not lock out tenants — fail-open on null effective limits |
| 2026-08-04 | IBillingClient in Tenants.Core — NullBillingClient fails open | Module enable must not hard-fail if Billing service is temporarily unreachable |
| 2026-08-04 | DB tiering: shared → own → own-server; connection strings in OpenBao | Application code never routes by tier — string from vault determines target |
| 2026-08-04 | Storage tiering: shared SeaweedFS prefix → own bucket → own cluster | IFileStorage abstraction hides tier; credentials in OpenBao |
| 2026-08-04 | Core platform DBs (tenants, billing, keycloak) on shared PG — never metered per-tenant | Platform infra cost is not attributable to any one tenant |
| 2026-08-04 | TenantResourceSnapshot: append-only nightly snapshot of storage + DB + user counts | Metering data stays historical; never mutated, only appended |
| 2026-08-04 | CloudSku table + Azure Retail Prices API sync for sysadmin P&L | Enables margin calculation for dedicated-infra enterprise deals; off by default |
| 2026-08-04 | Feature flags gate infra options (dedicated_db, multi_region, azure_price_sync) | Deploy early, enable late; no code change needed to activate a tier option |
| 2026-08-04 | Four-layer config hierarchy: appsettings (infra) → PlatformConfig (business rules) → CountryConfig (legal facts) → tenant overrides | Each layer has a single owner and a clear rule about what belongs there |
| 2026-08-04 | appsettings/env vars hold infrastructure only — no business rules, no timelines, no feature flags | Business rules in appsettings require a redeploy to change; PlatformConfig changes at runtime |
| 2026-08-04 | PlatformConfig table (sysadmin-managed, Redis-cached) for lifecycle timelines, retry counts, feature flags | Operator can change grace periods without a deploy; Redis cache with pub/sub invalidation across pods |
| 2026-08-04 | DataRetentionPolicy as a child of CountryConfig — legal retention per document type per country | Country law (PL: 5y invoices, DE: 10y, GB: 6y) is a legal fact, not an operator choice; drives archival on termination |
| 2026-08-04 | CanBeDeletedOnRequest = false on legal documents overrides GDPR erasure requests | Platform must retain invoices for legal period even on Art. 17 request; LegalBasis field provides the explanation |
| 2026-08-04 | Expand-contract 3-phase migration pattern — no startup MigrateAsync in production | Additive Phase 1 is zero-downtime; Phase 3 (removal) only after all tenant DBs backfilled |
| 2026-08-04 | ModuleStatus (Active/Migrating/Degraded/Suspended) projected to Redis, read by Gateway on every request | Migration sets Migrating per tenant, blocks writes, unblocks when done — no maintenance window needed |
| 2026-08-04 | Tenant lifecycle: PastDue → Suspended → PendingTermination → Terminated, driven by Workflow timer steps | Each phase has defined access level (full/read-only/none); PaymentSucceededEvent cancels the chain at any point |
| 2026-08-04 | Data export ZIP auto-generated on Suspended Day 16, stored in cold storage, download link valid 14 days | Platform obligation is to offer export with reasonable notice; if tenant ignores it, that is their responsibility |
| 2026-08-04 | Archival on Terminated: SQL dump per module DB + S3 move to cold bucket; legal docs retained per DataRetentionPolicy | Own-DB tier: drop DB after dump. Shared tier: delete rows. Legal retention wins over cold_storage_retain_years |
| 2026-08-04 | GdprErasureLog append-only table tracks all erasure requests and which document types were legally retained | Audit trail for DPA requests; RetainedDocumentTypes + LegalBasisNote form the required response to the subject |

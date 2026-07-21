# Order Processing Platform — Architecture Notes

This document describes the order processing platform end to end: ingestion,
validation, fulfilment, and reporting. It intentionally leans on diagrams so
that every subsystem has a picture next to its prose. It doubles as a stress
test for the preview renderer — Mermaid, code highlighting, and math all
appear below.

## 1. System overview

Orders arrive over HTTPS, are validated, priced, and dispatched to a
fulfilment queue. The happy path takes under 300 ms at the median; the tail
is dominated by payment authorization.

```mermaid
flowchart TD
    A[Client] -->|POST /orders| B(API Gateway)
    B --> C{Valid schema?}
    C -->|yes| D[Order Service]
    C -->|no| E[400 Bad Request]
    D --> F[(Orders DB)]
    D --> G[[Pricing Engine]]
    G --> H{In stock?}
    H -->|yes| I[Fulfilment Queue]
    H -->|no| J[Backorder Queue]
    I --> K[Warehouse Worker]
    J --> K
    K --> L([Shipped])
```

The gateway terminates TLS and applies per-tenant rate limits. Everything
downstream of the Order Service is asynchronous.

## 2. Order placement sequence

The critical path involves four services. Payment authorization is the only
synchronous external call.

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant G as Gateway
    participant O as OrderSvc
    participant P as PaymentSvc
    participant Q as Queue
    C->>G: POST /orders
    G->>O: forward (traced)
    O->>P: authorize(card, amount)
    P-->>O: auth token
    O->>Q: enqueue(fulfilment)
    O-->>G: 201 Created
    G-->>C: order id + ETA
    Note over O,P: p99 here is 180 ms —<br/>the platform's dominant latency
```

## 3. Domain model

The core aggregate is `Order`; everything else hangs off it.

```mermaid
classDiagram
    class Order {
        +UUID id
        +OrderStatus status
        +Money total
        +place()
        +cancel()
    }
    class LineItem {
        +SKU sku
        +int quantity
        +Money unitPrice
    }
    class Customer {
        +UUID id
        +String email
        +loyaltyTier() Tier
    }
    class Shipment {
        +TrackingId tracking
        +ship()
    }
    Order "1" *-- "1..*" LineItem
    Customer "1" o-- "0..*" Order
    Order "1" --> "0..1" Shipment
```

## 4. Order lifecycle

Status transitions are strictly forward except for the cancellation edges.

```mermaid
stateDiagram-v2
    [*] --> Draft
    Draft --> Placed: submit
    Placed --> Paid: payment ok
    Placed --> Cancelled: payment failed
    Paid --> Fulfilling: picked up
    Fulfilling --> Shipped: handed to carrier
    Fulfilling --> Cancelled: out of stock
    Shipped --> Delivered
    Delivered --> [*]
    Cancelled --> [*]
```

## 5. Delivery milestones

The Q3 rollout is sequenced so the queue migration lands before peak season.

```mermaid
gantt
    title Q3 rollout
    dateFormat YYYY-MM-DD
    section Platform
        Queue migration        :a1, 2026-07-01, 21d
        Idempotency keys       :a2, after a1, 14d
    section Fulfilment
        Warehouse API v2       :b1, 2026-07-10, 30d
        Carrier webhooks       :b2, after b1, 10d
    section Hardening
        Load test              :c1, after a2, 7d
        Chaos drill            :c2, after c1, 5d
```

## 6. Traffic mix

Read traffic dwarfs writes, which shapes the caching strategy.

```mermaid
pie title Requests by endpoint (last 30 days)
    "GET /orders/:id" : 46
    "GET /orders" : 27
    "POST /orders" : 14
    "PATCH /orders/:id" : 8
    "DELETE /orders/:id" : 5
```

## 7. Storage schema

The relational core stays small; large payloads live in object storage.

```mermaid
erDiagram
    CUSTOMER ||--o{ ORDER : places
    ORDER ||--|{ LINE_ITEM : contains
    ORDER ||--o| SHIPMENT : "ships as"
    PRODUCT ||--o{ LINE_ITEM : "referenced by"
    CUSTOMER {
        uuid id PK
        string email
        string tier
    }
    ORDER {
        uuid id PK
        uuid customer_id FK
        string status
        int total_cents
    }
    LINE_ITEM {
        uuid order_id FK
        string sku
        int quantity
    }
```

## 8. Customer journey

Support tickets cluster around the payment step, which matches the journey
scores below.

```mermaid
journey
    title Checkout experience
    section Browse
        Find product: 6: Customer
        Compare options: 5: Customer
    section Buy
        Add to cart: 6: Customer
        Enter payment: 3: Customer
        Confirm order: 4: Customer
    section After
        Track shipment: 5: Customer, Support
        Receive package: 7: Customer
```

## 9. Deployment topology

Each region runs the full stack; cross-region traffic is replication only.

```mermaid
flowchart LR
    subgraph us-east
        LB1[ALB] --> S1[app x6]
        S1 --> DB1[(primary)]
    end
    subgraph eu-west
        LB2[ALB] --> S2[app x4]
        S2 --> DB2[(replica)]
    end
    DB1 -. async repl .-> DB2
    CDN{{CDN}} --> LB1
    CDN --> LB2
```

## 10. Incident escalation

Paging follows severity; only SEV-1 wakes the on-call manager.

```mermaid
flowchart TD
    A([Alert fires]) --> B{Severity?}
    B -->|SEV-1| C[Page primary + manager]
    B -->|SEV-2| D[Page primary]
    B -->|SEV-3| E[Ticket only]
    C --> F[War room]
    D --> G{Ack in 5 min?}
    G -->|no| C
    G -->|yes| H[Investigate]
    F --> H
    H --> I([Postmortem])
```

## Appendix A: Client snippet

The Swift client retries idempotently using the server-issued key:

```swift
struct OrderClient {
    let session: URLSession
    let idempotencyKey: UUID

    func place(_ order: OrderDraft) async throws -> OrderReceipt {
        var request = URLRequest(url: endpoint.appending(path: "orders"))
        request.httpMethod = "POST"
        request.setValue(idempotencyKey.uuidString,
                         forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(order)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            throw OrderError.rejected
        }
        return try JSONDecoder().decode(OrderReceipt.self, from: data)
    }
}
```

The TypeScript worker drains the fulfilment queue in batches:

```typescript
async function drain(queue: Queue<OrderEvent>, batchSize = 32): Promise<void> {
  while (true) {
    const events = await queue.take(batchSize, { waitMs: 500 });
    if (events.length === 0) continue;
    const results = await Promise.allSettled(events.map(fulfil));
    for (const [i, r] of results.entries()) {
      if (r.status === "rejected") await queue.deadLetter(events[i], r.reason);
    }
  }
}
```

Operators replay dead letters with a one-liner:

```bash
for id in $(dlq list --queue fulfilment --format ids); do
  dlq replay "$id" && echo "replayed $id"
done
```

## Appendix B: Capacity math

Peak load is provisioned from the queueing model. With arrival rate
$\lambda = 420$ req/s and per-worker service rate $\mu = 55$ req/s, the
utilization per worker is $\rho = \lambda / (c \mu)$ for $c$ workers.

Expected wait in an M/M/c queue:

$$
W_q = \frac{C(c, \lambda/\mu)}{c\mu - \lambda}
\qquad
C(c, a) = \frac{\dfrac{a^c}{c!}\,\dfrac{c}{c-a}}
               {\sum_{k=0}^{c-1} \dfrac{a^k}{k!} + \dfrac{a^c}{c!}\,\dfrac{c}{c-a}}
$$

With $c = 10$ workers, $\rho \approx 0.76$ and $W_q < 12$ ms, which leaves
headroom for a single-AZ failure ($c = 7$, $\rho \approx 0.99$ — too hot, so
the fleet floor is 12).

# MedusaJS y alternativas headless extensibles

> Investigación de Medusa (`https://medusajs.com/`) y comparativa con plataformas
> de e-commerce headless y altamente extensibles. Fecha: 2026-09-18.

> **Decisión: seguimos con MedusaJS.** Su core es **MIT** y es **más extensible**
> que las alternativas evaluadas para nuestro caso. Las alternativas de la
> sección 10 quedan documentadas como referencia, no como reemplazo.

---

## 1. Medusa — resumen

**Medusa es una plataforma de comercio digital open source con un framework de
customización incorporado.** Se define como *headless*: no impone un frontend,
expone su funcionalidad por API y tú construyes storefront, admin, apps y
marketplaces encima.

- **Sitio:** https://medusajs.com/
- **Docs:** https://docs.medusajs.com/
- **Repo:** https://github.com/medusajs/medusa (~36.4k estrellas, ~5.3k forks, +10.800 commits)
- **Licencia:** modelo **open-core**. El core es **MIT**; los materiales de la
  *Enterprise Edition* (RBAC, etc.) están bajo licencia comercial
  (`ENTERPRISE-LICENSE.md`).
- **Lema actual:** *"Open-Source Commerce Platform for Agents and Developers"*.

### ¿Qué la hace distinta?

Su propuesta no es solo "tienda", sino **primitivas de comercio + framework para
extenderlas sin reinventar la lógica core**. Los módulos de comercio son open
source y se publican en npm por separado.

---

## 2. Historia y evolución (v1 → v2)

- **Medusa v1 (2021–2024):** monolito Node.js/TypeScript sobre Express, con
  "services/plugins" y un modelo de datos propio.
- **Medusa v2 (2024–actual):** reescritura completa hacia una **arquitectura
  modular**. Se separó todo en *modules* con servicio propio, se introdujo el
  **Workflow Engine**, el lenguaje **DML** (Data Model Language) y los
  **module links**. Es la versión vigente y la que documenta la web.

La v2 es la relevante a día de hoy; prácticamente todo el grueso de la
documentación apunta a ella.

---

## 3. Stack técnico

| Capa | Tecnología |
|------|------------|
| Runtime | Node.js (servidor basado en **Express.js**) |
| Lenguaje | TypeScript |
| Base de datos | **PostgreSQL** (única soportada nativamente; otras vía módulo custom) |
| Framework de app | Framework propio de Medusa (API routes, workflows, modules, subscribers) |
| Admin | React (dashboard customizable con widgets y UI routes) |
| Storefront | Libre; starter oficial en **Next.js** |
| Infra opcional | Redis (sesiones, eventos, caché, locking, workflow engine), S3 (ficheros) |
| API | **REST** (API routes). Admin + Store APIs |
| Empaquetado | Monorepo Yarn; módulos publicados en npm |

---

## 4. Arquitectura (4 capas)

Una petición recorre:

1. **API Routes (HTTP)** — entrada, Express.js + Redis para sesiones.
2. **Workflows** — lógica de negocio orquestada en pasos (con retry y tracking).
3. **Modules** — servicios de dominio que gestionan recursos.
4. **Data store** — PostgreSQL (conexión inyectada en cada módulo).

Además hay una capa de **integraciones** con terceros mediante *Commerce Modules*
(ej. Stripe para pago, ShipStation para fulfillment) e *Infrastructure Modules*
(analytics, caching, eventos, ficheros, locking, notificaciones, workflow engine).

Los módulos pueden empaquetarse dentro de **plugins**.

Diagrama completo: https://docs.medusajs.com/learn/advanced-development/architecture/overview

---

## 5. Commerce Modules (incluidos out-of-the-box)

- API Key
- Auth
- Cart
- Currency
- Customer
- Fulfillment
- Inventory
- **Loyalty**
- Order
- Payment
- Pricing
- Product
- Promotion
- Region
- Sales Channel
- Settings
- Stock Location
- Store
- **Store Credit**
- Tax
- Translation
- User

Lista completa: https://docs.medusajs.com/resources/commerce-modules

### Infrastructure Modules

- Analytics (p. ej. PostHog)
- Caching (Redis; añadido en v2.11.0, reemplaza al deprecado *Cache Module*)
- Event (pub/sub, Redis)
- File (S3, etc.)
- Locking (Redis)
- Notification (SendGrid, etc.)
- Workflow Engine (Redis)

---

## 6. Capacidades del Framework (puntos de extensión)

Estas son las piezas que definen su grado de extensibilidad:

1. **API Routes personalizadas** — exponer endpoints REST propios.
2. **Workflows** — `createWorkflow("...", function(input) { ... })`; pasos con retry
   y estado. Aquí vive la lógica de negocio.
3. **Módulos custom** — `MedusaService({...})` para crear dominio propio con su
   propio modelo y servicio.
4. **DML (Data Model Language)** — definir modelos/tablas en TypeScript:
   ```ts
   const DigitalProduct = model.define("digital_product", {
     id: model.id().primaryKey(),
     name: model.text(),
     medias: model.hasMany(() => DigitalProductMedia, { mappedBy: "digitalProduct" }),
   }).cascades({ delete: ["medias"] })
   ```
5. **Module Links** — añadir relaciones entre tus modelos y los de Medusa sin
   tocar el core:
   ```ts
   export default defineLink(
     DigitalProductModule.linkable.digitalProduct,
     ProductModule.linkable.productVariant
   )
   ```
6. **Subscribers** — reaccionar a eventos (`order.placed`, etc.):
   ```ts
   export const config: SubscriberConfig = { event: "order.placed" }
   ```
7. **Admin UI Widgets y UI Routes** — inyectar UI en zonas predefinidas
   (`zone: "product.details.before"`) o añadir páginas al dashboard React.
8. **Plugins** — empaquetar todo lo anterior y reutilizarlo.
9. **Integración con sistemas externos** — workflows que orquestan Medusa + ERP/PIM/etc.

Referencia: https://docs.medusajs.com/learn/fundamentals/framework

---

## 7. Casos de uso soportados (recetas oficiales)

- **Marketplace** multi-vendor
- **B2B / DTC / Distribuidores**
- **Productos digitales** (fulfillment custom)
- **Suscripciones**
- **Productos empaquetados (bundles)**
- **Restaurant-delivery** (tipo UberEats)
- **ERP** (ej. Odoo) y **PIM/CMS** (ej. Sanity)
- **POS**, apps móviles, multi-store

Recetas: https://docs.medusajs.com/resources/recipes

---

## 8. Instalación y despliegue

**Requisitos típicos:** Node.js, PostgreSQL, y opcionalmente Redis.

**Local (vía docs):** https://docs.medusajs.com/learn/installation

**Cloud (recomendado por ellos):** Medusa Cloud — despliegue desde GitHub,
autoscaling, preview environments, CLI. Desde **$29/mes**, sin licencias extra
ni comisión por GMV (según su pricing).

**Self-host:** cualquier host Docker-compatible (Postgres + Redis + build Node).

Herramientas para agentes IA: MCP server, agent skills, Bloom (asistente de
código) y desarrollo agentic. Docs: https://docs.medusajs.com/learn/introduction/build-with-llms-ai

---

## 9. Pros y contras de Medusa

### Pros
- Framework de extensión **de primera clase** (workflows, modules, links, DML).
- Todo TypeScript/Node → un solo lenguaje en backend y tooling.
- Módulos usables también **fuera** de la app Medusa (serverless, Next.js, Node).
- Comunidad grande y en crecimiento (#1 en GitHub de su categoría según ellos).
- Cloud gestionado si no quieres operar infra.
- Storefront starter en Next.js.

### Contras
- Solo **PostgreSQL** nativo (otras BD requieren módulo custom).
- **Open-core**: features enterprise (RBAC, etc.) son de pago.
- Menos "plug-and-play" que Shopify/WooCommerce: exige perfil developer.
- Ecosistema de plugins más joven que Shopify/Magento.
- La v2 rompió compatibilidad con v1 (coste de migración).

---

## 10. Alternativas headless y extensibles

Todas las siguientes son **open source, headless y extensibles**. Se documentan
como referencia y descartes; **la elección es Medusa** (sección 12).

### 10.1 Vendure — plugin-first en TypeScript
- **Stack:** TypeScript, **NestJS**, GraphQL, React/TanStack en el admin.
- **Licencia:** **GPLv3** + *plugin license exception* (tus plugins pueden ser de
  cualquier licencia; los storefronts que solo consumen la API GraphQL no caen en GPL).
- **Repo:** https://github.com/vendurehq/vendure (~8.4k estrellas)
- **Por qué destaca:** enfoque **plugin-first**. Permite extender u **override de
  cualquier parte del core** mediante contratos de plugin estables y overrides de
  servicios; añadir entidades, lógica de pricing y workflows **sin forkear**.
- **BD:** PostgreSQL, MySQL, MariaDB o SQLite.
- **GraphQL** introspeccional → cómodo para tool-calling LLM/MCP.
- **Por qué no:** su licencia **GPLv3** (aun con excepción de plugins) frente al
  **MIT** de Medusa, y una comunidad/ecosistema menores. Medusa es igualmente
  extensible con workflows, modules, DML y links, en el mismo stack JS/TS.

### 10.2 Saleor — API-only, GraphQL nativo
- **Stack:** Python/Django, **GraphQL only**.
- **Licencia:** **BSD-3-Clause** (single version, sin feature gating).
- **Repo:** https://github.com/saleor/saleor (~23.3k estrellas)
- **Por qué destaca:** **API-first puro**. Se extiende con **apps** (webhooks,
  subscription queries, API extensions, iframes en el dashboard), no con plugins
  in-process. Extensible en **cualquier lenguaje**, despliegue independiente,
  multi-canal nativo.
- **Contra:** modelo de extensión service-oriented más complejo para un dev solo;
  no tocas el core in-process (todo vía API/apps).
- **Ideal si:** quieres composable commerce, equipos grandes, apps aisladas.

### 10.3 Spree Commerce — REST + Rails
- **Stack:** Ruby on Rails, REST API, SDKs TypeScript, admin React, storefront Next.js.
- **Licencia:** **BSD-3-Clause** (Enterprise Edition de pago para multi-tenant,
  aprobaciones B2B, etc.).
- **Repo:** https://github.com/spree/spree (~15.7k estrellas)
- **Por qué destaca:** primitivas para **marketplace multi-vendor** (commissions,
  payouts con Stripe Connect, seller panel) y **B2B** (price lists, companies,
  catalogs, tax exemptions) en el core open source. Rails engine → extensibilidad
  vía decorators/overrides.
- **Ideal si:** el equipo es Ruby/Rails y necesitas marketplace/B2B out-of-the-box.

### 10.4 Sylius — Symfony / API Platform
- **Stack:** PHP, **Symfony**, API Platform (REST), BDD con Behat.
- **Licencia:** **MIT**.
- **Repo:** https://github.com/Sylius/Sylius (~8.5k estrellas)
- **Por qué destaca:** framework de e-commerce sobre Symfony, fuerte cultura de
  tests y **muy extensible** vía bundles/overrides. Sylius Plus añade OnePageCheckout,
  B2B, multi-store, multi-source inventory.
- **Ideal si:** el stack es PHP/Symfony.

### 10.5 Shopware 6 — API-first alemán
- **Stack:** PHP/Symfony, API-first (Store API + Admin API), admin Vue.
- **Licencia:** MIT (Community Edition).
- **Web:** https://www.shopware.com/
- **Por qué destaca:** sistema de **plugins y apps**, muy orientado a extensibilidad
  y catálogos grandes; fuerte en DACH. Headless vía Store API.

### 10.6 Otras a mencionar
- **WooCommerce + WPGraphQL**: headless sobre WordPress; extensible vía plugins PHP,
  pero atado a WP.
- **Magento / Adobe Commerce**: OSS core, muy potente y extensible, pero pesado y
  con features tras licencia Adobe.
- **PrestaShop**: OSS, PHP; headless posible pero su ecosistema no es API-first por diseño.
- **Odoo**: no es e-commerce puro, es ERP con módulo website/eCommerce (LGPL);
  interesante si necesitas ERP + tienda en un solo sistema.

---

## 11. Tabla comparativa

| Plataforma | Lenguaje / Stack | Licencia | API | BD nativa | Extensión | Fuerza |
|---|---|---|---|---|---|---|
| **Medusa v2** | TS / Node+Express | **MIT** | REST | PostgreSQL | Workflows, modules, DML, links, plugins | **Elegida**: MIT + máxima extensibilidad y ecosistema |
| **Vendure** | TS / NestJS | GPLv3 (+plugin exception) | GraphQL | PG/MySQL/MariaDB/SQLite | Plugins + override de core | Plugin-first, pero GPLv3 y ecosistema menor |
| **Saleor** | Python / Django | BSD-3 | GraphQL only | PostgreSQL | Apps / webhooks (API-only) | Composable, multi-lenguaje, multi-canal |
| **Spree** | Ruby / Rails | BSD-3 | REST | PostgreSQL | Rails engine/overrides | Marketplace y B2B en el core |
| **Sylius** | PHP / Symfony | MIT | REST (API Platform) | MySQL/MariaDB/PostgreSQL | Bundles/overrides | Framework e-commerce PHP robusto |
| **Shopware 6** | PHP / Symfony | MIT (CE) | Store+Admin API | MySQL/MariaDB | Plugins + apps | API-first, catálogos grandes |

---

## 12. Recomendación

**Seguimos con Medusa v2.** Motivos:
- **Licencia MIT** en el core (las alternativas comparadas usan GPLv3 u otras
  variantes; Medusa es la más permisiva).
- **Más extensible** para nuestro caso: workflows, módulos custom, DML, module
  links, subscribers y plugins cubren cualquier customización sin forkear el core.
- Stack **JS/TS extremadamente** familiar, una sola lengua, y comunidad/ecosistema
  de referencia (#1 de su categoría en GitHub).

Alternativas documentadas para contexto (no elegidas): **Vendure** (plugin-first en
TS, pero GPLv3 y ecosistema menor), **Saleor** (Python/GraphQL), **Spree** (Ruby),
**Sylius** / **Shopware 6** (PHP).

> Nota: las features de la *Enterprise Edition* de Medusa (p. ej. RBAC) no son MIT
> y requieren acuerdo comercial; el core y todos los Commerce Modules sí son MIT.

---

## 13. Carrito y checkout — flujo técnico (Medusa v2)

El ciclo de vida del carrito se gestiona **por completo en el backend** mediante un
**estado persistente en PostgreSQL**. El frontend solo guarda el `cart_id`
(normalmente en `localStorage` o cookie de sesión) y va enriqueciendo el carrito
con peticiones. Medusa **recalcula automáticamente** precios, impuestos y
promociones en cada cambio.

### Diagrama general

```
[ Frontend ] --(1. Crear Cart)---------> [ Medusa ] (crea registro en DB, asocia región/canal)
[ Frontend ] --(2. Añadir Ítems)--------> [ Medusa ] (valida inventario, calcula precio/impuestos/promos)
[ Frontend ] --(3. Email + Dirección)---> [ Medusa ] (recalcula impuestos según dirección)
[ Frontend ] --(4. Envío)---------------> [ Medusa ] (cotiza y suma costo de envío al total)
[ Frontend ] --(5. Pago)----------------> [ Medusa ] (payment collection + payment session con Stripe/PayPal/...)
[ Frontend ] --(6. Complete)------------> [ Medusa ] (workflow atómico: cobra, resta stock, crea Order)
```

> Aclaración: la **región** se fija al **crear el carrito** (de ella salen moneda e
> impuestos base). Al añadir la dirección se **recalculan** los impuestos exactos
> para esa ubicación.

### 1. Creación del carrito

- **Endpoint:** `POST /store/carts` (JS SDK: `sdk.store.cart.create({ region_id })`).
- Se recomienda crearlo en el primer acceso y guardar `cart.id`.
- Requiere la **publishable API key** en la cabecera (el SDK la envía solo); el
  carrito queda asociado al/los **sales channel** de esa key.
- Si el cliente está logueado, el carrito se asocia a él automáticamente.
- La **moneda** se deriva de la región; si envías `currency_code` debe coincidir
  (desde v2.21.0) o da error.

```ts
sdk.store.cart.create({ region_id: region.id })
  .then(({ cart }) => localStorage.setItem("cart_id", cart.id))
```

### 2. Gestión de ítems

- **Endpoint:** `POST /store/carts/{id}/line-items`.
- El backend valida inventario, aplica **precio de la región**, **impuestos** y
  **promociones**, y actualiza el total.
- Nota: Medusa **no rechaza** un ítem cuyo producto no esté en el sales channel del
  carrito; hay que validarlo explícitamente si se quiere forzar.

### 3. Checkout: 5 pasos (no es una "página", son peticiones que enriquecen el carrito)

1. **Email** — `POST /store/carts/{id}` con `email` (pre-rellenar si está logueado).
2. **Dirección** — `POST /store/carts/{id}` con `shipping_address` / `billing_address`;
   recalcula impuestos exactos.
3. **Envío** —
   - `GET /store/shipping-options?cart_id={id}` para listar opciones.
   - `POST /store/shipping-options/{id}/calculate` para las de `price_type="calculated"`
     (cotización contra el fulfillment provider).
   - `POST /store/carts/{id}/shipping-methods` con `option_id` para fijar el método
     (soporta múltiples métodos en una request desde v2.16.0).
4. **Pago** —
   - `GET /store/payment-providers?region_id=` para listar proveedores.
   - Crear **payment collection**: `POST /store/payment-collections`
     (el SDK lo combina en `initiatePaymentSession`).
   - Inicializar **payment session**: `POST /store/payment-collections/{id}/payment-sessions`
     con `provider_id`. Devuelve los datos que el frontend necesita para pintar la UI
     segura (p. ej. el *client secret* de Stripe). La tarjeta **nunca** toca el backend de Medusa.
5. **Completar** — `POST /store/carts/{id}/complete` (JS SDK: `sdk.store.cart.complete(cart.id)`).

> Ojo: la respuesta de *complete* trae un campo `type`:
> - `type: "order"` → **éxito**, se creó la orden (`order` en la respuesta). Hay que
>   borrar el `cart_id` del `localStorage`.
> - `type: "cart"` → **fallo** (detalle en `error`). No asumas cobro solo por llamar
>   a *complete*.

### 4. Cierre e identidad: Workflows

Al llamar a *complete*, Medusa dispara internamente el workflow **`completeCartWorkflow`**
(core-flows), que garantiza de forma **atómica**: autorizar/capturar el pago, restar
inventario y transformar el carrito en una **Order**.

- **Rollback automático:** si el completion falla *después* de que el pago fue
  autorizado o capturado, el workflow **revierte el pago**:
  - pago autorizado sin capturar → se **cancela**;
  - pago capturado → se **reembolsa** (salvo que otro intento concurrente ya haya
    creado la orden, para no reembolsar la orden válida).
- Por eso el storefront **no** necesita emitir el refund por su cuenta.
- **Restricción:** no uses el hook `validate` de `completeCartWorkflow` para mutar
  ítems, métodos de envío o totales (el workflow lee el carrito una sola vez y
  construye la orden con ese snapshot). Si necesitas cambiar el carrito antes de
  completar, corre un workflow/step aparte y **refresca la payment collection** para
  que el monto de la sesión de pago cuadre.

### 5. Notas de implementación

- El carrito es **durable en DB**; no hay estado en memoria del servidor.
- La moneda/impuestos salen de la **región**; el precio final y el envío se recalculan
  en cada mutación.
- Carrito vacío con total `0`: algunos proveedores (Stripe) no permiten crear la sesión
  de pago; usar el **Manual System Payment Provider** o no inicializar la sesión hasta
  que el total sea > 0.

**Fuentes:** [Cart](https://docs.medusajs.com/resources/storefront-development/cart),
[Checkout](https://docs.medusajs.com/resources/storefront-development/checkout),
[Shipping](https://docs.medusajs.com/resources/storefront-development/checkout/shipping),
[Payment](https://docs.medusajs.com/resources/storefront-development/checkout/payment),
[Complete Cart](https://docs.medusajs.com/resources/storefront-development/checkout/complete-cart),
[Cart Module](https://docs.medusajs.com/resources/commerce-modules/cart).

---

## 14. Fuentes

- https://medusajs.com/
- https://docs.medusajs.com/
- https://docs.medusajs.com/learn/advanced-development/architecture/overview
- https://docs.medusajs.com/resources/commerce-modules
- https://docs.medusajs.com/resources/storefront-development/cart
- https://docs.medusajs.com/resources/storefront-development/checkout
- https://docs.medusajs.com/resources/storefront-development/checkout/shipping
- https://docs.medusajs.com/resources/storefront-development/checkout/payment
- https://docs.medusajs.com/resources/storefront-development/checkout/complete-cart
- https://docs.medusajs.com/resources/commerce-modules/cart
- https://docs.medusajs.com/learn/installation
- https://github.com/medusajs/medusa
- https://github.com/vendurehq/vendure
- https://github.com/saleor/saleor
- https://github.com/spree/spree
- https://github.com/Sylius/Sylius
- https://www.shopware.com/

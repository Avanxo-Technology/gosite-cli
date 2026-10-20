import { Migration } from "@medusajs/framework/mikro-orm/migrations";

export class Migration20261020210835 extends Migration {

  override async up(): Promise<void> {
    this.addSql(`alter table if exists "mailer_delivery" drop constraint if exists "mailer_delivery_dedupe_key_unique";`);
    this.addSql(`create table if not exists "mailer_delivery" ("id" text not null, "rule_id" text not null, "event" text not null, "resource_id" text null, "dedupe_key" text null, "to" text not null, "bcc" text null, "subject" text not null, "html" text not null, "status" text check ("status" in ('pending', 'sent', 'failed', 'skipped')) not null default 'pending', "attempts" integer not null default 0, "last_error" text null, "sent_at" timestamptz null, "created_at" timestamptz not null default now(), "updated_at" timestamptz not null default now(), "deleted_at" timestamptz null, constraint "mailer_delivery_pkey" primary key ("id"));`);
    this.addSql(`CREATE INDEX IF NOT EXISTS "IDX_mailer_delivery_rule_id" ON "mailer_delivery" ("rule_id") WHERE deleted_at IS NULL;`);
    this.addSql(`CREATE UNIQUE INDEX IF NOT EXISTS "IDX_mailer_delivery_dedupe_key_unique" ON "mailer_delivery" ("dedupe_key") WHERE deleted_at IS NULL;`);
    this.addSql(`CREATE INDEX IF NOT EXISTS "IDX_mailer_delivery_deleted_at" ON "mailer_delivery" ("deleted_at") WHERE deleted_at IS NULL;`);

    this.addSql(`create table if not exists "mailer_rule" ("id" text not null, "name" text not null, "event" text not null, "active" boolean not null default false, "recipient" text check ("recipient" in ('order_email', 'customer_email', 'event_email', 'custom')) not null default 'order_email', "recipient_address" text null, "bcc" text null, "subject" text not null, "html" text not null, "once" boolean not null default true, "created_at" timestamptz not null default now(), "updated_at" timestamptz not null default now(), "deleted_at" timestamptz null, constraint "mailer_rule_pkey" primary key ("id"));`);
    this.addSql(`CREATE INDEX IF NOT EXISTS "IDX_mailer_rule_event" ON "mailer_rule" ("event") WHERE deleted_at IS NULL;`);
    this.addSql(`CREATE INDEX IF NOT EXISTS "IDX_mailer_rule_deleted_at" ON "mailer_rule" ("deleted_at") WHERE deleted_at IS NULL;`);
  }

  override async down(): Promise<void> {
    this.addSql(`drop table if exists "mailer_delivery" cascade;`);

    this.addSql(`drop table if exists "mailer_rule" cascade;`);
  }

}

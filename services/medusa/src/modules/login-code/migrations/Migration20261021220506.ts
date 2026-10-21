import { Migration } from "@medusajs/framework/mikro-orm/migrations";

export class Migration20261021220506 extends Migration {

  override async up(): Promise<void> {
    this.addSql(`create table if not exists "login_code" ("id" text not null, "email" text not null, "code_hash" text not null, "expires_at" timestamptz not null, "attempts" integer not null default 0, "consumed_at" timestamptz null, "created_at" timestamptz not null default now(), "updated_at" timestamptz not null default now(), "deleted_at" timestamptz null, constraint "login_code_pkey" primary key ("id"));`);
    this.addSql(`CREATE INDEX IF NOT EXISTS "IDX_login_code_email" ON "login_code" ("email") WHERE deleted_at IS NULL;`);
    this.addSql(`CREATE INDEX IF NOT EXISTS "IDX_login_code_deleted_at" ON "login_code" ("deleted_at") WHERE deleted_at IS NULL;`);
  }

  override async down(): Promise<void> {
    this.addSql(`drop table if exists "login_code" cascade;`);
  }

}

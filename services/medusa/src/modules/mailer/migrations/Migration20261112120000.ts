import { Migration } from "@medusajs/framework/mikro-orm/migrations";

// Adds the "order_receipt" recipient: the order's metadata.receipt_email,
// else the order's e-mail.
export class Migration20261112120000 extends Migration {

  override async up(): Promise<void> {
    this.addSql(`alter table if exists "mailer_rule" drop constraint if exists "mailer_rule_recipient_check";`);
    this.addSql(`alter table if exists "mailer_rule" add constraint "mailer_rule_recipient_check" check ("recipient" in ('order_email', 'order_receipt', 'customer_email', 'event_email', 'custom'));`);
  }

  override async down(): Promise<void> {
    this.addSql(`update "mailer_rule" set "recipient" = 'order_email' where "recipient" = 'order_receipt';`);
    this.addSql(`alter table if exists "mailer_rule" drop constraint if exists "mailer_rule_recipient_check";`);
    this.addSql(`alter table if exists "mailer_rule" add constraint "mailer_rule_recipient_check" check ("recipient" in ('order_email', 'customer_email', 'event_email', 'custom'));`);
  }

}

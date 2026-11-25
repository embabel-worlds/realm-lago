import { Entity } from "@embabel/runtime-types";
import type { LagoSubscriptionRecord, LagoWriteGateway } from "./lago";

export interface Subscription {
  /** The plan to bill on, by its code in Lago. */
  planCode: string;
  /**
   * The subscription's own id in the business's terms, such as the deal it came from. Subscribing
   * again with the same id returns the subscription already there, so a retry cannot double-bill.
   */
  subscriptionId: string;
  /** What the subscription is called on invoices. */
  name?: string;
  /** When billing starts, as an ISO date-time; now if omitted. */
  startsAt?: string;
}

/** A customer in Lago, with what billing can do for it once found. */
export class LagoCustomer extends Entity<LagoWriteGateway> {
  externalId!: string;
  name?: string;

  /** Start billing this customer on a plan. A plan billed in advance is invoiced at once. */
  async subscribe(subscription: Subscription): Promise<LagoSubscriptionRecord> {
    if (!this.externalId) throw new Error("this customer has no externalId, which Lago subscribes by");
    if (!subscription.planCode || !subscription.subscriptionId) throw new Error("subscribe needs a planCode and a subscriptionId");
    const answer = await this.gateway.lago.lagoSubscriptionCreate({
      subscription: {
        external_customer_id: this.externalId,
        plan_code: subscription.planCode,
        external_id: subscription.subscriptionId,
        ...(subscription.name ? { name: subscription.name } : {}),
        ...(subscription.startsAt ? { subscription_at: subscription.startsAt } : {}),
      },
    });
    return answer.subscription;
  }
}

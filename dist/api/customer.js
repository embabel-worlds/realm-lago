"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.LagoCustomer = void 0;
const runtime_types_1 = require("@embabel/runtime-types");
/** A customer in Lago, with what billing can do for it once found. */
class LagoCustomer extends runtime_types_1.Entity {
    externalId;
    name;
    /** Start billing this customer on a plan. A plan billed in advance is invoiced at once. */
    async subscribe(subscription) {
        if (!this.externalId)
            throw new Error("this customer has no externalId, which Lago subscribes by");
        if (!subscription.planCode || !subscription.subscriptionId)
            throw new Error("subscribe needs a planCode and a subscriptionId");
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
exports.LagoCustomer = LagoCustomer;

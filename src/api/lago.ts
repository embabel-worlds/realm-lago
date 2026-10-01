/*
 * The slice of the gateway Lago's types call: the realm's two write verbs in apis/lago.json.
 * Each type names it as Entity's type argument, so this.gateway is typed with exactly these.
 */
export interface LagoWriteGateway {
  lago: {
    lagoSubscriptionCreate(args: {
      subscription: { external_customer_id: string; plan_code: string; external_id: string; name?: string; subscription_at?: string };
    }): Promise<{ subscription: LagoSubscriptionRecord }>;
    lagoInvoiceVoid(args: { lago_id: string }): Promise<{ invoice: { lago_id: string; status: string } }>;
  };
}

/** What Lago answers a subscription with, the parts a caller acts on. */
export interface LagoSubscriptionRecord {
  lago_id: string;
  external_id: string;
  status: string;
  plan_code: string;
  started_at?: string;
}

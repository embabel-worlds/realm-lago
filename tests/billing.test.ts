import { describe, it, expect, vi } from "vitest";
import { entityForTest, mockGateway } from "@embabel/runtime-types";
import { LagoCustomer } from "../src/api/customer";
import { LagoInvoice } from "../src/api/invoice";
import type { LagoWriteGateway } from "../src/api/lago";

describe("LagoCustomer.subscribe", () => {
  it("subscribes by the customer's external id, keyed by the subscription's own id", async () => {
    const lagoSubscriptionCreate = vi.fn(async () => ({ subscription: { lago_id: "s1", external_id: "deal-4054", status: "active", plan_code: "pro" } }));
    const c = entityForTest(LagoCustomer, { id: "l-1", externalId: "acme.example" }, mockGateway<LagoWriteGateway>({ lago: { lagoSubscriptionCreate } }));
    const s = await c.subscribe({ planCode: "pro", subscriptionId: "deal-4054", name: "Acme Pro" });
    expect(s.status).toBe("active");
    expect(lagoSubscriptionCreate).toHaveBeenCalledWith({
      subscription: { external_customer_id: "acme.example", plan_code: "pro", external_id: "deal-4054", name: "Acme Pro" },
    });
  });

  it("refuses without a plan or a subscription id, and without the customer's external id", async () => {
    const gw = mockGateway<LagoWriteGateway>({ lago: { lagoSubscriptionCreate: vi.fn() } });
    await expect(entityForTest(LagoCustomer, { id: "l-1", externalId: "acme.example" }, gw).subscribe({ planCode: "", subscriptionId: "x" })).rejects.toThrow(/planCode and a subscriptionId/);
    await expect(entityForTest(LagoCustomer, { id: "l-1" }, gw).subscribe({ planCode: "pro", subscriptionId: "x" })).rejects.toThrow(/no externalId/);
  });
});

describe("LagoInvoice.writeOff", () => {
  it("voids the invoice by Lago's own id", async () => {
    const lagoInvoiceVoid = vi.fn(async () => ({ invoice: { lago_id: "inv-9", status: "voided" } }));
    const inv = entityForTest(LagoInvoice, { id: "inv-9", number: "ACM-0042", paymentStatus: "failed" }, mockGateway<LagoWriteGateway>({ lago: { lagoInvoiceVoid } }));
    expect(await inv.writeOff()).toBe("voided");
    expect(lagoInvoiceVoid).toHaveBeenCalledWith({ lago_id: "inv-9" });
  });

  it("refuses a paid invoice before anything is sent", async () => {
    const lagoInvoiceVoid = vi.fn();
    const paid = entityForTest(LagoInvoice, { id: "inv-1", number: "ACM-0001", paymentStatus: "succeeded" }, mockGateway<LagoWriteGateway>({ lago: { lagoInvoiceVoid } }));
    await expect(paid.writeOff()).rejects.toThrow(/is paid/);
    expect(lagoInvoiceVoid).not.toHaveBeenCalled();
  });
});

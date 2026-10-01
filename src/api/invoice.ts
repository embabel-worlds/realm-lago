import { Entity } from "@embabel/runtime-types";
import type { LagoWriteGateway } from "./lago";

/** An invoice in Lago, with what billing can do to it once found. */
export class LagoInvoice extends Entity<LagoWriteGateway> {
  number?: string;
  paymentStatus?: string;
  amountDueCents?: number;

  /**
   * Write off what is owed: Lago voids the invoice, and nothing more is expected on it. Final; a
   * void cannot be undone. Refused here for an invoice already paid, before anything is sent.
   */
  async writeOff(): Promise<string> {
    if (this.paymentStatus === "succeeded") throw new Error(`invoice ${this.number ?? this.id} is paid; there is nothing to write off`);
    const answer = await this.gateway.lago.lagoInvoiceVoid({ lago_id: this.id });
    return answer.invoice.status;
  }
}

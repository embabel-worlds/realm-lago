"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.LagoInvoice = void 0;
const runtime_types_1 = require("@embabel/runtime-types");
/** An invoice in Lago, with what billing can do to it once found. */
class LagoInvoice extends runtime_types_1.Entity {
    number;
    paymentStatus;
    amountDueCents;
    /**
     * Write off what is owed: Lago voids the invoice, and nothing more is expected on it. Final; a
     * void cannot be undone. Refused here for an invoice already paid, before anything is sent.
     */
    async writeOff() {
        if (this.paymentStatus === "succeeded")
            throw new Error(`invoice ${this.number ?? this.id} is paid; there is nothing to write off`);
        const answer = await this.gateway.lago.lagoInvoiceVoid({ lago_id: this.id });
        return answer.invoice.status;
    }
}
exports.LagoInvoice = LagoInvoice;

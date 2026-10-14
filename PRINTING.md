# Receipts and kitchen tickets

`PrinterService` isolates printer behavior. `NativePrinterService` renders a black-on-white, fixed-width receipt with word wrapping through AppKit `NSPrintOperation`. Settings offer 58 mm and 80 mm paper, and separate saved names for receipt and kitchen printers. Blank printer names use the macOS default. The native print dialog permits printer/paper selection and Save as PDF.

Use a macOS-compatible driver for the thermal printer. This implementation uses the macOS print system; it does not issue model-specific ESC/POS commands or claim device support without testing. The printer and driver may impose page-length or margin limits. Confirm a long order, a delivery address and a 58/80 mm roll on the actual hardware.

Receipts include restaurant identity, order number/date/type, cashier, historical product/variant/option snapshots, quantities, line totals, subtotal, delivery, discount, total, payment or unpaid status, delivery customer details and the configured footer. Kitchen tickets include products, sizes, extras, notes, order type and customer details for delivery, with payment information omitted.

The order is committed before printing begins. Cancelling a print dialog or a spool/driver failure never removes the order or its payment. Orders offers receipt/kitchen printing and retry. The optional automatic kitchen-print setting opens the print operation immediately after punch. The app can report failure returned by the print system but cannot guarantee that physical paper emerged after the spooler accepted a job.

Cmd+P prints the currently selected order's receipt. Receipt text generation is separate from the AppKit print adapter and is covered by unit tests for snapshot content and payment-free kitchen tickets. Physical printing has not been tested in the Windows development environment.

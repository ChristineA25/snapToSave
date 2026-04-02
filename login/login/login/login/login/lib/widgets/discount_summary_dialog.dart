
// lib/widgets/discount_summary_dialog.dart
import 'package:flutter/material.dart';

class DiscountSummaryResult {
  final bool confirmed;
  final String? discountCond;
  DiscountSummaryResult({required this.confirmed, this.discountCond});
}

class DiscountSummaryDialog extends StatefulWidget {
  final String rowSummary;      // one-liner context string
  final List<MapEntry<String, String>> details; // label/value pairs for popup
  final bool discountOn;
  final int maxLen; // enforce 65,535
  const DiscountSummaryDialog({
    super.key,
    required this.rowSummary,
    required this.details,
    required this.discountOn,
    required this.maxLen,
  });

  @override
  State<DiscountSummaryDialog> createState() => _DiscountSummaryDialogState();
}

class _DiscountSummaryDialogState extends State<DiscountSummaryDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.rowSummary, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        ...widget.details.map((kv) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 120, child: Text('${kv.key}:', style: const TextStyle(color: Colors.black54))),
                  Expanded(child: Text(kv.value)),
                ],
              ),
            )),
        if (widget.discountOn) ...[
          const SizedBox(height: 10),
          const Text('How did you get the discount?', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: _controller,
            maxLength: widget.maxLen,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'e.g. Clubcard price, 2 for £3, voucher at checkout',
              errorText: _error,
            ),
          ),
        ],
      ],
    );

    return AlertDialog(
      title: const Text('Confirm item details'),
      content: SingleChildScrollView(child: body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, DiscountSummaryResult(confirmed: false)), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            if (widget.discountOn) {
              final v = _controller.text.trim();
              if (v.length > widget.maxLen) {
                setState(() => _error = 'Too long (max ${widget.maxLen})');
                return;
              }
            }
            Navigator.pop(context, DiscountSummaryResult(
              confirmed: true,
              discountCond: widget.discountOn ? _controller.text.trim() : null,
            ));
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}

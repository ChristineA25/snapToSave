
import 'package:flutter/material.dart';

/// NOTE:
/// In the "resolve AFTER submit" flow, features are taken from the typed
/// Feature column in your table UI. This feature picker sheet is no longer
/// invoked automatically while typing. You may keep it for future use or
/// remove it if unneeded.
Future<List<String>?> showFeaturePickerSheet(
  BuildContext context, {
  required List<String> suggested,
  List<String>? preselected,
}) async {
  final sel = <String>{...(preselected ?? const [])};
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Select features that exist',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in suggested)
                      StatefulBuilder(
                        builder: (c, set) => CheckboxListTile(
                          value: sel.contains(f),
                          onChanged: (v) {
                            if (v == true) {
                              sel.add(f);
                            } else {
                              sel.remove(f);
                            }
                            set(() {});
                          },
                          title: Text(f),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, null),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(ctx, sel.toList()),
                    icon: const Icon(Icons.check),
                    label: const Text('Apply'),
                  ),
                ],
              )
            ],
          ),
        ),
      );
    },
  );
}

/// Candidate chooser (used when multiple matches remain after submit).
/// Shows items numbered 1..N so the user can pick the n‑th row.
Future<Map<String, dynamic>?> showCandidateChooserSheet(
  BuildContext context, {
  required List<Map<String, dynamic>> candidates,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Choose the exact product',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final c = candidates[i];
                    final id = (c['id'] ?? '').toString();
                    final name = (c['name'] ?? '').toString();
                    final brand = (c['brand'] ?? '').toString();
                    final qty = (c['quantity'] ?? '').toString();
                    final feat = (c['feature'] ?? '').toString();
                    return ListTile(
                      leading: CircleAvatar(child: Text('${i + 1}')),
                      title: Text('$brand — $name'),
                      subtitle: Text(
                        'id: $id\nqty: $qty\nfeature: $feat',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(ctx, c),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

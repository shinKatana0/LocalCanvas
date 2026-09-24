/// Manual entry (`docs/connection.md` §4).
///
/// Reachable from every state, including when discovery finds nothing and
/// including when discovery cannot run at all — it is the escape hatch that
/// keeps the app working with mDNS removed entirely
/// (`docs/transport-boundary.md` §5).
///
/// The field refuses an address only when it cannot be read. A public host or
/// an `https://` address is accepted here exactly as a LAN address is.
library;

import 'package:flutter/material.dart';

import '../../connection/endpoint.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../keys.dart';

/// Asks for an address. Returns the endpoint the user entered, or `null` if
/// they backed out.
Future<Endpoint?> showManualEntrySheet(
  BuildContext context, {
  String? initialValue,
}) {
  return showModalBottomSheet<Endpoint>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: _ManualEntryForm(initialValue: initialValue),
    ),
  );
}

class _ManualEntryForm extends StatefulWidget {
  const _ManualEntryForm({this.initialValue});

  final String? initialValue;

  @override
  State<_ManualEntryForm> createState() => _ManualEntryFormState();
}

class _ManualEntryFormState extends State<_ManualEntryForm> {
  late final TextEditingController _field = TextEditingController(
    text: widget.initialValue ?? '',
  );

  /// Whether the last submission was unreadable, rather than the sentence
  /// saying so: the sentence belongs to the language on screen at the moment
  /// the field is drawn (T-0142).
  bool _invalid = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final endpoint = Endpoint.tryParse(_field.text);
    if (endpoint == null) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(endpoint);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LcSpace.lg,
        LcSpace.xs,
        LcSpace.lg,
        LcSpace.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l.manualEntryTitle, style: text.titleLarge),
          const SizedBox(height: LcSpace.xs),
          Text(
            l.manualEntryNote,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
          const SizedBox(height: LcSpace.md),
          TextField(
            key: LcKeys.addressField,
            controller: _field,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_invalid) setState(() => _invalid = false);
            },
            decoration: InputDecoration(
              hintText: '192.0.2.42',
              errorText: _invalid ? l.manualEntryNotAnAddress : null,
              prefixIcon: const Icon(Icons.dns_outlined),
            ),
          ),
          const SizedBox(height: LcSpace.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: LcKeys.addressSubmit,
              onPressed: _submit,
              child: Text(l.connect),
            ),
          ),
        ],
      ),
    );
  }
}

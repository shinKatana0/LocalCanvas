/// Choosing a server: the four ways in, on one screen
/// (`docs/connection.md`).
///
/// Discovery is the convenience; the pairing code and the typed address are
/// the guarantees. All three are visible at once and in every state, so a
/// network that suppresses multicast is a smaller list rather than a dead end.
library;

import 'package:flutter/material.dart';

import '../../connection/connection_controller.dart';

import '../../connection/discovery.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../common/brand.dart';
import '../common/notice_card.dart';
import '../keys.dart';
import 'manual_entry_sheet.dart';
import 'scan_screen.dart';

class ConnectScreen extends StatelessWidget {
  const ConnectScreen({super.key, required this.controller});

  final ConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final l = L.of(context);
    final notice = controller.notice;

    return Scaffold(
      key: LcKeys.connectScreen,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: LcLayout.readableWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      LcSpace.lg,
                      LcSpace.xl,
                      LcSpace.lg,
                      LcSpace.md,
                    ),
                    children: <Widget>[
                      // The product's name gives by scaling down, never by
                      // wrapping or clipping (T-0158): it is one word, and a
                      // brand split across two lines is not the brand. At an
                      // ordinary scale it fits and `scaleDown` leaves it
                      // exactly as it was.
                      const Row(
                        children: <Widget>[
                          CanvasMark(size: 34),
                          SizedBox(width: LcSpace.sm),
                          Flexible(
                            child: FittedBox(
                              key: LcKeys.connectWordmark,
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Wordmark(fontSize: 20),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: LcSpace.xl),
                      Text(l.connectTitle, style: text.displaySmall),
                      const SizedBox(height: LcSpace.xs),
                      Text(
                        l.connectIntro,
                        style: text.bodyMedium?.copyWith(
                          color: palette.textSecondary,
                        ),
                      ),
                      if (notice != null) ...<Widget>[
                        const SizedBox(height: LcSpace.lg),
                        NoticeCard(
                          notice: notice,
                          actions: <Widget>[
                            TextButton(
                              key: LcKeys.retryConnection,
                              onPressed: controller.isBusy
                                  ? null
                                  : () => controller.retry(),
                              child: Text(l.tryAgain),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: LcSpace.xl),
                      _SectionLabel(l.connectOnThisNetwork),
                      const SizedBox(height: LcSpace.sm),
                      _DiscoverySection(controller: controller),
                    ],
                  ),
                ),
                // Outside the scroll area on purpose: these two are the ways
                // in that always work, and they must never be somewhere the
                // user has to scroll to find.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    LcSpace.lg,
                    LcSpace.sm,
                    LcSpace.lg,
                    LcSpace.lg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      FilledButton.icon(
                        key: LcKeys.scanPairingCode,
                        onPressed: controller.isBusy
                            ? null
                            : () => _scan(context, controller),
                        icon: const Icon(
                          Icons.qr_code_scanner_rounded,
                          size: 20,
                        ),
                        label: Text(l.scanPairingCode),
                      ),
                      const SizedBox(height: LcSpace.sm),
                      OutlinedButton.icon(
                        key: LcKeys.enterAddress,
                        onPressed: controller.isBusy
                            ? null
                            : () => enterAddressManually(context, controller),
                        icon: const Icon(Icons.keyboard_outlined, size: 20),
                        label: Text(l.enterAddress),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens manual entry and connects to whatever it returns.
Future<void> enterAddressManually(
  BuildContext context,
  ConnectionController controller, {
  String? initialValue,
}) async {
  final endpoint = await showManualEntrySheet(
    context,
    initialValue: initialValue ?? controller.endpoint?.display,
  );
  if (endpoint == null) return;
  await controller.connectTo(endpoint);
}

Future<void> _scan(
  BuildContext context,
  ConnectionController controller,
) async {
  final result = await Navigator.of(context).push<ScanResult>(
    MaterialPageRoute<ScanResult>(builder: (_) => const ScanScreen()),
  );
  if (!context.mounted || result == null) return;

  switch (result) {
    case ScanDismissedForManualEntry():
      await enterAddressManually(context, controller);
    case ScannedPayload(:final payload):
      final outcome = await controller.connectToPairingPayload(payload);
      if (outcome == PairingOutcome.notAPairingCode && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L.of(context).notAPairingCode)),
        );
      }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: Theme.of(context).textTheme.labelSmall,
  );
}

/// The discovered list and its three honest empty answers.
class _DiscoverySection extends StatelessWidget {
  const _DiscoverySection({required this.controller});

  final ConnectionController controller;

  @override
  Widget build(BuildContext context) {
    final discovery = controller.discovery;
    final l = L.of(context);
    return ListenableBuilder(
      listenable: discovery,
      builder: (context, _) {
        final servers = discovery.servers;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final server in servers) ...<Widget>[
              _ServerTile(
                server: server,
                onTap: controller.isBusy
                    ? null
                    : () => controller.connectTo(server.endpoint),
              ),
              const SizedBox(height: LcSpace.xs),
            ],
            switch (discovery.status) {
              // Not searching and never asked to: offer the search rather
              // than a spinner that is not spinning for anything.
              DiscoveryStatus.idle => _SearchRow(
                label: l.searchThisNetwork,
                onPressed: () => discovery.scan(),
              ),
              DiscoveryStatus.scanning => const _SearchingRow(),
              DiscoveryStatus.finished when servers.isEmpty => _QuietCard(
                key: LcKeys.discoveryEmpty,
                title: l.discoveryEmptyTitle,
                body: l.discoveryEmptyBody,
                onSearchAgain: () => discovery.scan(),
              ),
              DiscoveryStatus.finished => _SearchRow(
                label: l.searchAgain,
                onPressed: () => discovery.scan(),
              ),
              // The card says what the app knows and no more. What it knows
              // about *why* is whatever refused the scan said, so that goes on
              // the screen too, untranslated: the person holding the phone is
              // the only one who can read it, and a cable is not always there.
              DiscoveryStatus.unavailable => _QuietCard(
                key: LcKeys.discoveryUnavailable,
                title: l.discoveryUnavailableTitle,
                body: l.discoveryUnavailableBody,
                reasonLabel: l.discoveryFailureLabel,
                reason: discovery.failure?.summary,
                onSearchAgain: () => discovery.scan(),
              ),
            },
          ],
        );
      },
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({required this.server, required this.onTap});

  final DiscoveredServer server;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(LcRadius.lg),
      child: InkWell(
        key: LcKeys.discoveredServer(server.id),
        onTap: onTap,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        child: Padding(
          padding: const EdgeInsets.all(LcSpace.md),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.accentQuiet,
                  borderRadius: BorderRadius.circular(LcRadius.sm),
                ),
                child: Icon(Icons.desktop_windows_outlined,
                    size: 20, color: palette.accent),
              ),
              const SizedBox(width: LcSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(server.displayName, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      server.endpoint.display,
                      style: text.bodySmall?.copyWith(color: palette.textMuted),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: palette.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchingRow extends StatelessWidget {
  const _SearchingRow();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: palette.accent),
        ),
        const SizedBox(width: LcSpace.sm),
        Expanded(
          child: Text(
            L.of(context).lookingForServers,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: palette.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: LcKeys.searchAgain,
      onPressed: onPressed,
      icon: const Icon(Icons.refresh, size: 18),
      label: Text(label),
    ),
  );
}

class _QuietCard extends StatelessWidget {
  const _QuietCard({
    super.key,
    required this.title,
    required this.body,
    required this.onSearchAgain,
    this.reasonLabel,
    this.reason,
  });

  final String title;
  final String body;
  final VoidCallback onSearchAgain;

  /// The platform's own words for why this state happened, and the localized
  /// label that introduces them. Absent for a card that has no such words —
  /// nothing answered is an outcome, not an error.
  final String? reasonLabel;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(LcSpace.md),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(LcRadius.lg),
        border: Border.all(color: palette.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: text.titleSmall),
          const SizedBox(height: LcSpace.xxs),
          Text(
            body,
            style: text.bodySmall?.copyWith(color: palette.textSecondary),
          ),
          if (reason != null && reason!.isNotEmpty) ...<Widget>[
            const SizedBox(height: LcSpace.xs),
            Text(
              reasonLabel ?? '',
              style: text.labelSmall?.copyWith(color: palette.textSecondary),
            ),
            Text(
              reason!,
              key: LcKeys.discoveryFailureReason,
              style: text.bodySmall?.copyWith(color: palette.textSecondary),
            ),
          ],
          const SizedBox(height: LcSpace.xxs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: LcKeys.searchAgain,
              onPressed: onSearchAgain,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(L.of(context).searchAgain),
            ),
          ),
        ],
      ),
    );
  }
}

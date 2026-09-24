/// The application root.
///
/// The order of the two things that happen at launch is the whole point of
/// this file: the connection sequence is started from [initState], and the
/// intro is painted *over* an app that is already doing that work. Nothing
/// waits for a frame count, and the intro's only effect on the app is that it
/// covers it for [LcMotion.intro].
///
/// It is also where the app notices that it is leaving the foreground, which
/// is the one moment a debounced draft has to be written whether or not its
/// wait is over.
///
/// **The brightness follows the same shape as the connection.** The remembered
/// theme choice is read from [initState], unawaited, exactly as the connection
/// sequence is; the app starts in [ThemeMode.system], which is the right answer
/// for a device that has said nothing and the only honest one for a device
/// whose answer has not arrived. The one thing the read is allowed to hold is
/// the *cover*: the intro stays over the app until the choice has settled, so
/// that a person who chose dark on a light phone never sees the app itself in
/// the other brightness. It holds nothing else — the connection, the registry
/// and Generate all proceed underneath it (`docs/ui-ux.md`: readiness is never
/// gated).
///
/// **The stored language is read the same way, under the same cover.** It has
/// exactly the shape the brightness has — a preference file, read from
/// [initState], unawaited — and the same reason to be waited for: a person who
/// chose English on a Russian phone must not see the app in Russian first
/// (T-0142). So the cover lifts when *both* have settled, and the deadline
/// below bounds the pair of them rather than either one.
///
/// **And it holds it for a bounded time.** [kBrightnessGrace] past the end of
/// the intro the cover comes off whatever the stores are doing. A preference read
/// that never answers is rare and a splash that never ends is the first thing
/// `docs/ui-ux.md` lists under "Never", so the deadline exists to make the bad
/// case the *contracted* one: the app appears, in system mode, showing whatever
/// it honestly is — `Connecting…` if the connection is still in flight. An
/// answer that arrives after the deadline is still applied; it is simply
/// applied in the open.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'connection/connection_controller.dart';
import 'generation/session_controller.dart';
import 'l10n/app_localizations.dart';
import 'l10n/app_locales.dart';
import 'l10n/locale_controller.dart';
import 'theme/pane_split_store.dart';
import 'theme/theme.dart';
import 'theme/theme_mode_controller.dart';
import 'theme/tokens.dart';
import 'ui/connect/connect_screen.dart';
import 'ui/keys.dart';
import 'ui/shell/connected_shell.dart';
import 'ui/startup/connecting_view.dart';
import 'ui/startup/startup_intro.dart';

class LocalCanvasApp extends StatefulWidget {
  const LocalCanvasApp({
    super.key,
    required this.session,
    required this.appearance,
    required this.language,
    this.split,
  });

  /// The connection, the registry and the generation, held here rather than
  /// inside the shell: a fold rebuilds the shell, and anything that lived in
  /// it would be rebuilt with it.
  final SessionController session;

  /// Where the split between the two panes is remembered, if this build was
  /// given anywhere to remember it.
  ///
  /// Carried through untouched: nothing at this level reads it, and the cover
  /// above does not wait for it. A split that arrives a few frames late is a
  /// pane that resizes on a screen already in the right colours and the right
  /// language — unlike a brightness, which would be the app appearing in the
  /// wrong one.
  final PaneSplitStore? split;

  /// Which of the two brightnesses this device shows. Required, so that a
  /// composition that forgot to remember the choice does not compile.
  final ThemeModeController appearance;

  /// Which language this device shows. Required for the same reason, and it
  /// buys more here: an app that failed to hand this over would silently draw
  /// every screen in whatever the fallback is.
  final LocaleController language;

  ConnectionController get controller => session.connection;

  @override
  State<LocalCanvasApp> createState() => _LocalCanvasAppState();
}

class _LocalCanvasAppState extends State<LocalCanvasApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Not awaited, and not chained to any animation: the app connects while
    // the intro plays.
    unawaited(widget.controller.start());
    // Started here rather than in `main`, and for the same reason: awaiting it
    // before the first frame would put a preference read in front of the app
    // appearing at all.
    unawaited(widget.appearance.restore());
    // The phone's own language preferences, before the first frame and then
    // whenever they change. Read through the binding rather than off
    // `PlatformDispatcher.instance`, because the binding's is the one a widget
    // test can put a Russian phone into.
    widget.language.systemLocales =
        WidgetsBinding.instance.platformDispatcher.locales;
    unawaited(widget.language.restore());
  }

  /// The phone's language settings changed while the app was running.
  ///
  /// Honoured immediately, and only where it can be: a person following their
  /// phone follows it here too, and a person who chose a language keeps it.
  /// [LocaleController] decides which of those this is; this method only
  /// carries the news.
  @override
  void didChangeLocales(List<Locale>? locales) {
    super.didChangeLocales(locales);
    widget.language.systemLocales = locales ?? const <Locale>[];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Leaving the foreground is the last moment the app is promised.
  ///
  /// Android may kill a backgrounded process without another word, so the
  /// draft that is still waiting out its debounce is written here — every
  /// state that is not [AppLifecycleState.resumed], because the one thing that
  /// matters is that the app is no longer in front of the user, and because a
  /// write is never destructive: the worst an early one costs is a write.
  ///
  /// **Coming back to it is when the list may have changed** (T-0017): a
  /// workflow imported on the PC while the phone was in a pocket. So a return
  /// re-reads the registry — once, quietly, and only when all three hold:
  ///
  /// * the app is connected. Anywhere else there is no shell to show a list in,
  ///   and the server the registry last read may not be the one being chosen;
  /// * no reconnect is running. It refreshes the registry itself, as one of its
  ///   steps, and a second request beside it would only race it;
  /// * the list is older than [WorkflowsController.registryStaleAfter], which
  ///   the controller checks — a glance at a notification asks nothing.
  ///
  /// It is [WorkflowsController.refresh], so the form stays on screen while it
  /// runs and a failure says nothing. Nothing is scheduled: the next re-read is
  /// the next return, or the person pressing Refresh.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (widget.controller.phase == ConnectionPhase.connected &&
          !widget.session.isReconnecting) {
        unawaited(widget.session.workflows.refreshIfStale());
      }
      return;
    }
    unawaited(widget.session.workflows.flushDrafts());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.appearance,
        widget.language,
      ]),
      builder: (context, _) => MaterialApp(
        // The product name, out of the same bundle as everything else, so the
        // guard against a stray literal has no exception to make for it.
        onGenerateTitle: (context) => L.of(context).appTitle,
        debugShowCheckedModeBanner: false,
        theme: lcLightTheme(),
        darkTheme: lcDarkTheme(),
        // The user's choice, and `ThemeMode.system` only because that is what
        // they chose or because nobody has chosen yet. Never a literal.
        themeMode: widget.appearance.mode,
        localizationsDelegates: L.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        // Already resolved, by `resolveAppLocale` and nowhere else. Handing
        // `MaterialApp` a chosen-or-resolved locale rather than `null` keeps
        // the decision in one function that a test can put any phone in front
        // of — instead of splitting it between this app and Flutter's own
        // fallback, which matches on country and would send a `zh_RU` phone to
        // Russian.
        locale: widget.language.locale,
        home: RootView(
          session: widget.session,
          appearance: widget.appearance,
          language: widget.language,
          split: widget.split,
        ),
      ),
    );
  }
}

/// How long past the end of the intro the cover will wait for the stored
/// brightness before giving up on it.
///
/// The read is over a preference file and normally completes within the first
/// frames, long before the animation does — so in every ordinary case this
/// deadline is never reached and costs nothing. It exists for the case that is
/// not ordinary: a preference read that never answers must not leave a splash
/// with no end, which is the first thing `docs/ui-ux.md` lists under "Never".
///
/// **It has to be longer than [LcMotion.introExit].** The cover does not
/// vanish when it is dismissed — it fades for that long. A grace shorter than
/// the fade would put the deadline inside the dismissal that is already
/// happening, where a bound and no bound at all are the same picture and
/// nothing can tell them apart. Half a second clears it with room to spare and
/// is still short enough that the pathological case ends in under two seconds.
const Duration kBrightnessGrace = Duration(milliseconds: 500);

/// The shell under the intro: whichever screen the connection phase calls for.
class RootView extends StatefulWidget {
  const RootView({
    super.key,
    required this.session,
    required this.appearance,
    required this.language,
    this.split,
  });

  final SessionController session;

  /// Read here for one thing only: whether the stored brightness has arrived.
  final ThemeModeController appearance;

  /// Read here for one thing only: whether the stored language has arrived.
  final LocaleController language;

  /// Not read here at all — handed to the shell, which is the only screen
  /// with two panes to split.
  final PaneSplitStore? split;

  ConnectionController get controller => session.connection;

  @override
  State<RootView> createState() => _RootViewState();
}

class _RootViewState extends State<RootView> {
  bool _introFinished = false;

  /// The grace ran out. The cover comes off whether or not the store answered.
  bool _graceExpired = false;

  Timer? _grace;

  @override
  void initState() {
    super.initState();
    widget.appearance.addListener(_onStoredChoice);
    widget.language.addListener(_onStoredChoice);
    // Armed at launch rather than when the intro ends, so the deadline is a
    // fixed point in the startup rather than something the animation can move.
    _grace = Timer(LcMotion.intro + kBrightnessGrace, () {
      if (mounted) setState(() => _graceExpired = true);
    });
    // Nothing to wait for on stores that have already answered — which, in a
    // test with immediate fakes, is before the first frame.
    _onStoredChoice();
  }

  @override
  void dispose() {
    _grace?.cancel();
    widget.appearance.removeListener(_onStoredChoice);
    widget.language.removeListener(_onStoredChoice);
    super.dispose();
  }

  /// The stored brightness arrived (or failed, which also ends the wait).
  ///
  /// **Cancelling the deadline here and cancelling it in [dispose] are a
  /// mutually redundant pair. Neither fails a test on its own.** Measured, one
  /// mutant at a time: remove this cancel and 0 tests fail; remove the one in
  /// [dispose] and 0 tests fail; remove both and 32 fail, because a pending
  /// timer outlives the widget test that created it and fails it. The property
  /// is real and is guarded only by their conjunction — either one, deleted by
  /// itself, is silent, so neither can be called the load-bearing one. An
  /// earlier version of this comment called this one exactly that, which
  /// attributed to a single line something that belongs to both.
  ///
  /// The [setState] is a third thing and it is **belt and braces**. An
  /// earlier version of this file claimed the subscription was required
  /// because `MaterialApp` caches the page it is given; that was measured and
  /// it is not true on this Flutter version — removing the subscription
  /// entirely changes no test, because the rebuild arrives from above. It is
  /// kept because it is free, because it makes this widget's correctness a
  /// property of this widget, and because nothing about the framework's
  /// caching is promised to us. Nothing currently proves it necessary, and
  /// this comment says so rather than inventing a reason.
  void _onStoredChoice() {
    if (!_storedChoicesSettled) return;
    _grace?.cancel();
    _grace = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => AnimatedSwitcher(
              duration: LcMotion.normal,
              child: _screen(),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !covered,
            child: AnimatedSwitcher(
              duration: LcMotion.introExit,
              child: covered
                  ? StartupIntro(
                      key: LcKeys.intro,
                      onFinished: () {
                        if (mounted) setState(() => _introFinished = true);
                      },
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }

  /// Whether the intro is still over the app.
  ///
  /// It lifts when the animation has run *and* the stored brightness has
  /// settled — or the grace ran out, whichever of the last two comes first.
  /// The read is never allowed to start the animation late, to lengthen it, or
  /// to hold anything but this, and it cannot hold even this indefinitely.
  bool get covered =>
      !_introFinished || !(_storedChoicesSettled || _graceExpired);

  /// Whether every stored choice the cover waits on has arrived.
  ///
  /// Both, not either: a build that lifted the cover on the first of the two
  /// would show the app in the wrong language while it waited for the theme,
  /// or the wrong brightness while it waited for the language — which is the
  /// exact defect the cover exists to prevent, moved one store along.
  bool get _storedChoicesSettled =>
      widget.appearance.restored && widget.language.restored;

  Widget _screen() {
    final controller = widget.controller;
    switch (controller.phase) {
      case ConnectionPhase.idle:
      case ConnectionPhase.connecting:
        return ConnectingView(
          key: LcKeys.connecting,
          serverName: _connectingLabel(controller),
        );
      case ConnectionPhase.needsServer:
        return ConnectScreen(controller: controller);
      case ConnectionPhase.connected:
        return ConnectedShell(
          session: widget.session,
          appearance: widget.appearance,
          language: widget.language,
          split: widget.split,
        );
    }
  }

  /// Name the server when it has a name, otherwise the address being tried,
  /// otherwise say nothing rather than invent something.
  static String? _connectingLabel(ConnectionController controller) {
    final endpoint = controller.endpoint;
    if (endpoint == null) return null;
    final remembered = controller.remembered;
    if (remembered != null && remembered.endpoint == endpoint) {
      return remembered.displayName;
    }
    return endpoint.display;
  }
}

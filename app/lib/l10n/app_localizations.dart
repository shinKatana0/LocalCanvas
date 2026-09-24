import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of L
/// returned by `L.of(context)`.
///
/// Applications need to include `L.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: L.localizationsDelegates,
///   supportedLocales: L.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the L.supportedLocales
/// property.
abstract class L {
  L(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static L of(BuildContext context) {
    return Localizations.of<L>(context, L)!;
  }

  static const LocalizationsDelegate<L> delegate = _LDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// The product name, in the Android task switcher. A brand, never translated.
  ///
  /// In en, this message translates to:
  /// **'LocalCanvas'**
  String get appTitle;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// Backing out of a dialog without doing the thing it asks about.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get tryAgain;

  /// No description provided for @checkAgain.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get checkAgain;

  /// No description provided for @chooseAnotherServer.
  ///
  /// In en, this message translates to:
  /// **'Choose another server'**
  String get chooseAnotherServer;

  /// No description provided for @reconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get reconnect;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @change.
  ///
  /// In en, this message translates to:
  /// **'Change'**
  String get change;

  /// No description provided for @replace.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replace;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @on.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get on;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// A value the server did not report. An em dash in every locale.
  ///
  /// In en, this message translates to:
  /// **'—'**
  String get valueNone;

  /// Between all but the last two items of a list of field names.
  ///
  /// In en, this message translates to:
  /// **', '**
  String get listSeparator;

  /// The last join of a list of field names. head is one name or several already joined by listSeparator.
  ///
  /// In en, this message translates to:
  /// **'{head} and {last}'**
  String listAnd(String head, String last);

  /// Spoken name of the draggable divider between the two panes on a wide screen. A screen reader reads it and then offers increase/decrease, which widen and narrow the controls side.
  ///
  /// In en, this message translates to:
  /// **'Move the split between the controls and the picture'**
  String get splitHandleLabel;

  /// No description provided for @appearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceTitle;

  /// No description provided for @appearanceNote.
  ///
  /// In en, this message translates to:
  /// **'Light, dark, or whatever this phone is set to. This one stays on this phone — it is not in your profile.'**
  String get appearanceNote;

  /// No description provided for @appearanceLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceLight;

  /// No description provided for @appearanceDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceDark;

  /// Follow the phone's own light/dark setting. These three are read directly under the block's own heading, so where the language inflects they agree with the word that heading uses -- not with an English noun that is nowhere on the screen.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get appearanceSystem;

  /// No description provided for @languageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageTitle;

  /// No description provided for @languageNote.
  ///
  /// In en, this message translates to:
  /// **'The language this app speaks. This one stays on this phone too — it is not in your profile.'**
  String get languageNote;

  /// Follow the phone's own language. Agrees with the block's own heading where the language inflects, as the appearance chips do.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get languageSystem;

  /// No description provided for @connectTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose your server'**
  String get connectTitle;

  /// No description provided for @connectIntro.
  ///
  /// In en, this message translates to:
  /// **'LocalCanvas runs beside the generator on your computer. Pick it below, scan its pairing code, or type its address.'**
  String get connectIntro;

  /// A section label. Drawn upper-cased by the widget.
  ///
  /// In en, this message translates to:
  /// **'On this network'**
  String get connectOnThisNetwork;

  /// No description provided for @scanPairingCode.
  ///
  /// In en, this message translates to:
  /// **'Scan pairing code'**
  String get scanPairingCode;

  /// No description provided for @enterAddress.
  ///
  /// In en, this message translates to:
  /// **'Enter address'**
  String get enterAddress;

  /// No description provided for @searchThisNetwork.
  ///
  /// In en, this message translates to:
  /// **'Search this network'**
  String get searchThisNetwork;

  /// No description provided for @searchAgain.
  ///
  /// In en, this message translates to:
  /// **'Search again'**
  String get searchAgain;

  /// No description provided for @lookingForServers.
  ///
  /// In en, this message translates to:
  /// **'Looking for servers…'**
  String get lookingForServers;

  /// No description provided for @discoveryEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No servers answered.'**
  String get discoveryEmptyTitle;

  /// No description provided for @discoveryEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Some home networks do not pass this kind of search along. The pairing code and the address below always work.'**
  String get discoveryEmptyBody;

  /// No description provided for @discoveryUnavailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Searching didn\'t work this time.'**
  String get discoveryUnavailableTitle;

  /// No description provided for @discoveryUnavailableBody.
  ///
  /// In en, this message translates to:
  /// **'The pairing code and the address below always work.'**
  String get discoveryUnavailableBody;

  /// Labels the line beneath it, which carries the platform's own words for why a search failed and is never translated.
  ///
  /// In en, this message translates to:
  /// **'What the system reported'**
  String get discoveryFailureLabel;

  /// No description provided for @notAPairingCode.
  ///
  /// In en, this message translates to:
  /// **'That code isn\'t a LocalCanvas pairing code. Scan the one your server shows, or enter its address.'**
  String get notAPairingCode;

  /// No description provided for @manualEntryTitle.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get manualEntryTitle;

  /// No description provided for @manualEntryNote.
  ///
  /// In en, this message translates to:
  /// **'The address of the machine running LocalCanvas. Its startup output prints one.'**
  String get manualEntryNote;

  /// No description provided for @manualEntryNotAnAddress.
  ///
  /// In en, this message translates to:
  /// **'That doesn\'t look like an address. Try something like 192.0.2.42 or 192.0.2.42:7801.'**
  String get manualEntryNotAnAddress;

  /// No description provided for @scanHint.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the code your server shows.'**
  String get scanHint;

  /// No description provided for @scanEnterAddressInstead.
  ///
  /// In en, this message translates to:
  /// **'Enter the address instead'**
  String get scanEnterAddressInstead;

  /// No description provided for @scannerPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'LocalCanvas needs camera access to read a pairing code. You can allow it in Settings, or type the address instead.'**
  String get scannerPermissionDenied;

  /// No description provided for @scannerUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device cannot scan codes. Type the address instead.'**
  String get scannerUnsupported;

  /// No description provided for @scannerFailed.
  ///
  /// In en, this message translates to:
  /// **'The camera could not be started. Type the address instead.'**
  String get scannerFailed;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connecting;

  /// No description provided for @connectingTo.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {serverName}…'**
  String connectingTo(String serverName);

  /// No description provided for @problemUnreachableTitle.
  ///
  /// In en, this message translates to:
  /// **'The LocalCanvas server can\'t be reached.'**
  String get problemUnreachableTitle;

  /// No description provided for @problemUnreachableAt.
  ///
  /// In en, this message translates to:
  /// **'Nothing answered at {address}. Check that the server is running and that this device is on the same network as it.'**
  String problemUnreachableAt(String address);

  /// No description provided for @problemUnreachableAnywhere.
  ///
  /// In en, this message translates to:
  /// **'Nothing answered at that address. Check that the server is running and that this device is on the same network as it.'**
  String get problemUnreachableAnywhere;

  /// No description provided for @problemNotLocalCanvasTitle.
  ///
  /// In en, this message translates to:
  /// **'That address isn\'t a LocalCanvas server.'**
  String get problemNotLocalCanvasTitle;

  /// No description provided for @problemNotLocalCanvasAt.
  ///
  /// In en, this message translates to:
  /// **'Something answered at {address}, but it did not identify itself as LocalCanvas. Check the address, or scan the pairing code the server shows.'**
  String problemNotLocalCanvasAt(String address);

  /// No description provided for @problemNotLocalCanvasAnywhere.
  ///
  /// In en, this message translates to:
  /// **'Something answered at that address, but it did not identify itself as LocalCanvas. Check the address, or scan the pairing code the server shows.'**
  String get problemNotLocalCanvasAnywhere;

  /// No description provided for @problemIncompatibleTitle.
  ///
  /// In en, this message translates to:
  /// **'This server speaks a different version.'**
  String get problemIncompatibleTitle;

  /// No description provided for @problemIncompatibleAt.
  ///
  /// In en, this message translates to:
  /// **'The server at {address} uses API version {reported}, and this app speaks version {client}. Update whichever of the two is older, then try again.'**
  String problemIncompatibleAt(String address, int reported, int client);

  /// No description provided for @problemIncompatibleAnywhere.
  ///
  /// In en, this message translates to:
  /// **'The server at that address uses API version {reported}, and this app speaks version {client}. Update whichever of the two is older, then try again.'**
  String problemIncompatibleAnywhere(int reported, int client);

  /// The version-mismatch sentence for a server that refused to say which version it speaks. A separate sentence rather than a phrase substituted into the one above, because a language that inflects cannot take a noun phrase where a number goes.
  ///
  /// In en, this message translates to:
  /// **'The server at {address} uses an API version it did not name, and this app speaks version {client}. Update whichever of the two is older, then try again.'**
  String problemIncompatibleUnknownAt(String address, int client);

  /// No description provided for @problemIncompatibleUnknownAnywhere.
  ///
  /// In en, this message translates to:
  /// **'The server at that address uses an API version it did not name, and this app speaks version {client}. Update whichever of the two is older, then try again.'**
  String problemIncompatibleUnknownAnywhere(int client);

  /// No description provided for @problemComfyTitle.
  ///
  /// In en, this message translates to:
  /// **'Connected, but ComfyUI isn\'t running.'**
  String get problemComfyTitle;

  /// No description provided for @problemComfy.
  ///
  /// In en, this message translates to:
  /// **'{serverName} answered, but it cannot generate anything yet. Start ComfyUI on that machine, then try again.'**
  String problemComfy(String serverName);

  /// detail is the gateway's own sentence about why, passed through as it arrived.
  ///
  /// In en, this message translates to:
  /// **'{serverName} answered, but it cannot generate anything yet. {detail} Start ComfyUI on that machine, then try again.'**
  String problemComfyWithDetail(String serverName, String detail);

  /// Stands in for the server's own name before it has given one. Used as the subject of a sentence.
  ///
  /// In en, this message translates to:
  /// **'The server'**
  String get problemServerFallbackName;

  /// No description provided for @serverConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get serverConnected;

  /// No description provided for @serverReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get serverReady;

  /// No description provided for @serverNotReady.
  ///
  /// In en, this message translates to:
  /// **'Not ready to generate'**
  String get serverNotReady;

  /// No description provided for @serverDetailAddress.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get serverDetailAddress;

  /// No description provided for @serverDetailServerVersion.
  ///
  /// In en, this message translates to:
  /// **'Server version'**
  String get serverDetailServerVersion;

  /// No description provided for @serverDetailApiVersion.
  ///
  /// In en, this message translates to:
  /// **'API version'**
  String get serverDetailApiVersion;

  /// No description provided for @serverDetailGenerator.
  ///
  /// In en, this message translates to:
  /// **'Generator'**
  String get serverDetailGenerator;

  /// Accessibility label for tapping the result picture, which opens it nearly full screen (T-0210).
  ///
  /// In en, this message translates to:
  /// **'Open the picture almost full screen'**
  String get resultOpenLarger;

  /// Label for the number of automatic reconnect attempts, chosen with a − / + stepper beside it (docs/recovery.md, T-0212).
  ///
  /// In en, this message translates to:
  /// **'Reconnect attempts'**
  String get serverDetailReconnectAttempts;

  /// No description provided for @reconnectAttemptsFewer.
  ///
  /// In en, this message translates to:
  /// **'Fewer reconnect attempts'**
  String get reconnectAttemptsFewer;

  /// No description provided for @reconnectAttemptsMore.
  ///
  /// In en, this message translates to:
  /// **'More reconnect attempts'**
  String get reconnectAttemptsMore;

  /// No description provided for @serverApiVersionValue.
  ///
  /// In en, this message translates to:
  /// **'{server} (this app speaks {client})'**
  String serverApiVersionValue(String server, String client);

  /// No description provided for @generatorRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get generatorRunning;

  /// No description provided for @generatorStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting up'**
  String get generatorStarting;

  /// No description provided for @generatorNotRunning.
  ///
  /// In en, this message translates to:
  /// **'Not running'**
  String get generatorNotRunning;

  /// No description provided for @generatorUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get generatorUnknown;

  /// No description provided for @workflowsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nothing to create with yet'**
  String get workflowsEmptyTitle;

  /// No description provided for @workflowsEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'{serverName} has no workflows to offer. They are chosen on the computer running it, and appear here once it publishes them.'**
  String workflowsEmptyBody(String serverName);

  /// Stands in for the server's own name in the empty state. Used as the subject of a sentence.
  ///
  /// In en, this message translates to:
  /// **'This server'**
  String get thisServer;

  /// No description provided for @creationIdleChosenTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready when you are'**
  String get creationIdleChosenTitle;

  /// No description provided for @creationIdleChosenBody.
  ///
  /// In en, this message translates to:
  /// **'What you generate with {workflowName} appears here.'**
  String creationIdleChosenBody(String workflowName);

  /// No description provided for @creationIdleUnchosenTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick something to create'**
  String get creationIdleUnchosenTitle;

  /// No description provided for @creationIdleUnchosenBody.
  ///
  /// In en, this message translates to:
  /// **'Choose a workflow to see what it can do and what it needs from you.'**
  String get creationIdleUnchosenBody;

  /// No description provided for @chooseAWorkflow.
  ///
  /// In en, this message translates to:
  /// **'Choose a workflow'**
  String get chooseAWorkflow;

  /// No description provided for @missingWorkflowTitle.
  ///
  /// In en, this message translates to:
  /// **'“{workflowName}” is no longer on this server.'**
  String missingWorkflowTitle(String workflowName);

  /// No description provided for @missingWorkflowBody.
  ///
  /// In en, this message translates to:
  /// **'Nothing was chosen in its place. What you typed is still here — pick another workflow to use it.'**
  String get missingWorkflowBody;

  /// No description provided for @defaultsSavedFor.
  ///
  /// In en, this message translates to:
  /// **'Settings saved as your defaults for {workflowName}.'**
  String defaultsSavedFor(String workflowName);

  /// No description provided for @setupSavedAs.
  ///
  /// In en, this message translates to:
  /// **'Saved as “{name}”.'**
  String setupSavedAs(String name);

  /// No description provided for @setupIsGone.
  ///
  /// In en, this message translates to:
  /// **'“{name}” is gone.'**
  String setupIsGone(String name);

  /// No description provided for @profileTitle.
  ///
  /// In en, this message translates to:
  /// **'Your profile'**
  String get profileTitle;

  /// Contractual (docs/privacy-security.md). It must claim exactly what the exported document holds and exactly what it does not. Neither half may be softened or widened.
  ///
  /// In en, this message translates to:
  /// **'Your saved settings and setups, as one file you can move to another phone. Nothing about this server, and nothing you have generated, is in it.'**
  String get profileNote;

  /// No description provided for @profileExport.
  ///
  /// In en, this message translates to:
  /// **'Export my profile'**
  String get profileExport;

  /// No description provided for @profileImport.
  ///
  /// In en, this message translates to:
  /// **'Import a profile'**
  String get profileImport;

  /// What the system's own document picker calls this kind of file, on the way in.
  ///
  /// In en, this message translates to:
  /// **'LocalCanvas profile'**
  String get profileFileTypeLabel;

  /// No description provided for @profileImportedNothing.
  ///
  /// In en, this message translates to:
  /// **'That profile had nothing in it.'**
  String get profileImportedNothing;

  /// No description provided for @profileImported.
  ///
  /// In en, this message translates to:
  /// **'Imported {what}. Nothing of yours was removed. Use \"Reset settings to my defaults\" to apply them here.'**
  String profileImported(String what);

  /// No description provided for @profileImportedWorkflows.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{settings for 1 workflow} other{settings for {count} workflows}}'**
  String profileImportedWorkflows(int count);

  /// No description provided for @profileImportedSetups.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 setup} other{{count} setups}}'**
  String profileImportedSetups(int count);

  /// No description provided for @profileNotAProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'That file is not a LocalCanvas profile.'**
  String get profileNotAProfileTitle;

  /// No description provided for @profileNotAProfileMessage.
  ///
  /// In en, this message translates to:
  /// **'Choose the file an export produced. It is a .json file and it starts by saying what it is.'**
  String get profileNotAProfileMessage;

  /// No description provided for @profileNewerTitle.
  ///
  /// In en, this message translates to:
  /// **'That profile is from a newer LocalCanvas.'**
  String get profileNewerTitle;

  /// No description provided for @profileNewerMessage.
  ///
  /// In en, this message translates to:
  /// **'It is a version {found} profile and this app reads version {supported}. Nothing was changed on this device. Update LocalCanvas, then import it again.'**
  String profileNewerMessage(int found, int supported);

  /// No description provided for @didntWorkTitle.
  ///
  /// In en, this message translates to:
  /// **'That didn\'t work.'**
  String get didntWorkTitle;

  /// No description provided for @tryAgainMessage.
  ///
  /// In en, this message translates to:
  /// **'Try again.'**
  String get tryAgainMessage;

  /// No description provided for @exportAccessDeniedTitle.
  ///
  /// In en, this message translates to:
  /// **'LocalCanvas can\'t save to your gallery.'**
  String get exportAccessDeniedTitle;

  /// No description provided for @exportAccessDeniedMessage.
  ///
  /// In en, this message translates to:
  /// **'Allow it to add photos and videos in Android settings, then try again.'**
  String get exportAccessDeniedMessage;

  /// No description provided for @exportNotEnoughSpaceTitle.
  ///
  /// In en, this message translates to:
  /// **'There is not enough space to save this.'**
  String get exportNotEnoughSpaceTitle;

  /// No description provided for @exportNotEnoughSpaceMessage.
  ///
  /// In en, this message translates to:
  /// **'Free some space on this device, then try again.'**
  String get exportNotEnoughSpaceMessage;

  /// No description provided for @exportUnsupportedFormatTitle.
  ///
  /// In en, this message translates to:
  /// **'Your gallery could not take this file.'**
  String get exportUnsupportedFormatTitle;

  /// No description provided for @exportUnsupportedFormatMessage.
  ///
  /// In en, this message translates to:
  /// **'The server produced a kind of file the gallery does not accept. Share it instead to keep it.'**
  String get exportUnsupportedFormatMessage;

  /// No description provided for @exportSavedToGallery.
  ///
  /// In en, this message translates to:
  /// **'Saved to your gallery.'**
  String get exportSavedToGallery;

  /// No description provided for @serverDidntAnswerTitle.
  ///
  /// In en, this message translates to:
  /// **'The server didn\'t answer.'**
  String get serverDidntAnswerTitle;

  /// No description provided for @serverUnreachableMessage.
  ///
  /// In en, this message translates to:
  /// **'It may have gone off the network or been stopped. Check that it is running, then try again.'**
  String get serverUnreachableMessage;

  /// No description provided for @serverUnreadableTitle.
  ///
  /// In en, this message translates to:
  /// **'The server\'s answer could not be read.'**
  String get serverUnreadableTitle;

  /// No description provided for @serverUnreadableMessage.
  ///
  /// In en, this message translates to:
  /// **'This app and the server may be different versions. Try again, and update whichever of the two is older if it keeps happening.'**
  String get serverUnreadableMessage;

  /// No description provided for @serverRefusedTitle.
  ///
  /// In en, this message translates to:
  /// **'The server could not do that.'**
  String get serverRefusedTitle;

  /// A refusal that carried neither a known code nor a sentence to quote.
  ///
  /// In en, this message translates to:
  /// **'The server did not say why.'**
  String get serverRefusedNoReason;

  /// No description provided for @mediaUploadUnreachableTitle.
  ///
  /// In en, this message translates to:
  /// **'The server didn\'t take the upload.'**
  String get mediaUploadUnreachableTitle;

  /// No description provided for @mediaUploadRefusedTitle.
  ///
  /// In en, this message translates to:
  /// **'The server could not take that file.'**
  String get mediaUploadRefusedTitle;

  /// No description provided for @mediaNotAllowedTitle.
  ///
  /// In en, this message translates to:
  /// **'That file could not be opened.'**
  String get mediaNotAllowedTitle;

  /// No description provided for @mediaNotAllowedMessage.
  ///
  /// In en, this message translates to:
  /// **'Choose it again, and allow LocalCanvas to read it when Android asks.'**
  String get mediaNotAllowedMessage;

  /// No description provided for @mediaGoneTitle.
  ///
  /// In en, this message translates to:
  /// **'That file is no longer available.'**
  String get mediaGoneTitle;

  /// No description provided for @mediaGoneMessage.
  ///
  /// In en, this message translates to:
  /// **'Choose it again.'**
  String get mediaGoneMessage;

  /// No description provided for @gatewayErrorUnsupportedMediaType.
  ///
  /// In en, this message translates to:
  /// **'This server does not accept that kind of file.'**
  String get gatewayErrorUnsupportedMediaType;

  /// No description provided for @gatewayErrorUnsupportedImageHeic.
  ///
  /// In en, this message translates to:
  /// **'That photo is in HEIC format, which LocalCanvas cannot use yet. Choose a JPEG or PNG, or turn off high-efficiency (HEIC) photos in the camera settings.'**
  String get gatewayErrorUnsupportedImageHeic;

  /// No description provided for @gatewayErrorEmptyUpload.
  ///
  /// In en, this message translates to:
  /// **'That file is empty.'**
  String get gatewayErrorEmptyUpload;

  /// No description provided for @gatewayErrorInvalidFilename.
  ///
  /// In en, this message translates to:
  /// **'That file\'s name cannot be used. Rename it, then choose it again.'**
  String get gatewayErrorInvalidFilename;

  /// No description provided for @gatewayErrorFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'That file is larger than this server accepts. Choose a smaller one.'**
  String get gatewayErrorFileTooLarge;

  /// No description provided for @gatewayErrorMediaKindMismatch.
  ///
  /// In en, this message translates to:
  /// **'That file is not the kind this field asks for.'**
  String get gatewayErrorMediaKindMismatch;

  /// No description provided for @gatewayErrorWorkflowNotFound.
  ///
  /// In en, this message translates to:
  /// **'That workflow is no longer on this server.'**
  String get gatewayErrorWorkflowNotFound;

  /// No description provided for @mediaNeedsPicture.
  ///
  /// In en, this message translates to:
  /// **'This workflow works from a picture you choose.'**
  String get mediaNeedsPicture;

  /// No description provided for @mediaNeedsClip.
  ///
  /// In en, this message translates to:
  /// **'This workflow works from a clip you choose.'**
  String get mediaNeedsClip;

  /// No description provided for @mediaCannotChoose.
  ///
  /// In en, this message translates to:
  /// **'Choosing one is not available on this device.'**
  String get mediaCannotChoose;

  /// No description provided for @mediaChoosePicture.
  ///
  /// In en, this message translates to:
  /// **'Choose picture'**
  String get mediaChoosePicture;

  /// No description provided for @mediaChooseClip.
  ///
  /// In en, this message translates to:
  /// **'Choose clip'**
  String get mediaChooseClip;

  /// No description provided for @mediaReadyToUse.
  ///
  /// In en, this message translates to:
  /// **'Ready to use'**
  String get mediaReadyToUse;

  /// No description provided for @mediaChosenPicture.
  ///
  /// In en, this message translates to:
  /// **'Chosen picture'**
  String get mediaChosenPicture;

  /// No description provided for @mediaChosenClip.
  ///
  /// In en, this message translates to:
  /// **'Chosen clip'**
  String get mediaChosenClip;

  /// No description provided for @mediaNounPicture.
  ///
  /// In en, this message translates to:
  /// **'picture'**
  String get mediaNounPicture;

  /// No description provided for @mediaNounClip.
  ///
  /// In en, this message translates to:
  /// **'clip'**
  String get mediaNounClip;

  /// No description provided for @mediaUploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading…'**
  String get mediaUploading;

  /// No description provided for @mediaFinishing.
  ///
  /// In en, this message translates to:
  /// **'Finishing…'**
  String get mediaFinishing;

  /// No description provided for @mediaUploadingProgress.
  ///
  /// In en, this message translates to:
  /// **'Uploading… {sent} of {total}'**
  String mediaUploadingProgress(String sent, String total);

  /// A size under a kilobyte, where a phone gallery would say the plain number.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 byte} other{{count} bytes}}'**
  String byteCount(int count);

  /// No description provided for @byteSize.
  ///
  /// In en, this message translates to:
  /// **'{amount} {unit}'**
  String byteSize(String amount, String unit);

  /// No description provided for @byteUnitKilo.
  ///
  /// In en, this message translates to:
  /// **'kB'**
  String get byteUnitKilo;

  /// No description provided for @byteUnitMega.
  ///
  /// In en, this message translates to:
  /// **'MB'**
  String get byteUnitMega;

  /// No description provided for @byteUnitGiga.
  ///
  /// In en, this message translates to:
  /// **'GB'**
  String get byteUnitGiga;

  /// No description provided for @byteUnitTera.
  ///
  /// In en, this message translates to:
  /// **'TB'**
  String get byteUnitTera;

  /// No description provided for @generationUploadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Sending this to the server…'**
  String get generationUploadingTitle;

  /// No description provided for @generationUploadingMessage.
  ///
  /// In en, this message translates to:
  /// **'Your inputs are on their way.'**
  String get generationUploadingMessage;

  /// No description provided for @generationQueuedTitle.
  ///
  /// In en, this message translates to:
  /// **'Waiting in the queue'**
  String get generationQueuedTitle;

  /// No description provided for @generationQueuedMessage.
  ///
  /// In en, this message translates to:
  /// **'The server has it and has not started yet.'**
  String get generationQueuedMessage;

  /// No description provided for @generationGeneratingTitle.
  ///
  /// In en, this message translates to:
  /// **'Generating'**
  String get generationGeneratingTitle;

  /// No description provided for @generationTakesAWhile.
  ///
  /// In en, this message translates to:
  /// **'This can take a while.'**
  String get generationTakesAWhile;

  /// No description provided for @generationCancelledTitle.
  ///
  /// In en, this message translates to:
  /// **'Cancelled.'**
  String get generationCancelledTitle;

  /// No description provided for @generationCancelledMessage.
  ///
  /// In en, this message translates to:
  /// **'Nothing was generated.'**
  String get generationCancelledMessage;

  /// No description provided for @generationFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'That generation didn\'t finish.'**
  String get generationFailedTitle;

  /// No description provided for @generationStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping…'**
  String get generationStopping;

  /// Stops a generation that is running. A verb, not the way out of a dialog.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get generationCancel;

  /// No description provided for @generateAgain.
  ///
  /// In en, this message translates to:
  /// **'Generate Again'**
  String get generateAgain;

  /// No description provided for @generationSaveAsSetup.
  ///
  /// In en, this message translates to:
  /// **'Save as a setup'**
  String get generationSaveAsSetup;

  /// No description provided for @resultPreviousResult.
  ///
  /// In en, this message translates to:
  /// **'Previous result'**
  String get resultPreviousResult;

  /// No description provided for @resultNextResult.
  ///
  /// In en, this message translates to:
  /// **'Next result'**
  String get resultNextResult;

  /// Which of this session's results is on screen. Positions count from the oldest still kept.
  ///
  /// In en, this message translates to:
  /// **'{position} of {total}'**
  String resultHistoryPosition(int position, int total);

  /// No description provided for @generationFinishedTitle.
  ///
  /// In en, this message translates to:
  /// **'Finished.'**
  String get generationFinishedTitle;

  /// No description provided for @generationNoOutput.
  ///
  /// In en, this message translates to:
  /// **'The server reported no output for this generation.'**
  String get generationNoOutput;

  /// No description provided for @generationClipReadyTitle.
  ///
  /// In en, this message translates to:
  /// **'Your clip is ready.'**
  String get generationClipReadyTitle;

  /// No description provided for @generationClipReadyMessage.
  ///
  /// In en, this message translates to:
  /// **'Save it or share it to watch it.'**
  String get generationClipReadyMessage;

  /// No description provided for @generationPreviewFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'The picture couldn\'t be fetched.'**
  String get generationPreviewFailedTitle;

  /// No description provided for @generationClipFetchFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'The clip couldn\'t be fetched.'**
  String get generationClipFetchFailedTitle;

  /// No description provided for @clipPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get clipPlay;

  /// No description provided for @clipPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get clipPause;

  /// No description provided for @clipSoundOn.
  ///
  /// In en, this message translates to:
  /// **'Turn the sound on'**
  String get clipSoundOn;

  /// No description provided for @clipSoundOff.
  ///
  /// In en, this message translates to:
  /// **'Turn the sound off'**
  String get clipSoundOff;

  /// No description provided for @clipOpenLarger.
  ///
  /// In en, this message translates to:
  /// **'Open the clip almost full screen'**
  String get clipOpenLarger;

  /// No description provided for @clipCannotPlayTitle.
  ///
  /// In en, this message translates to:
  /// **'This phone can\'t play the clip.'**
  String get clipCannotPlayTitle;

  /// Shown when the device's video decoder refuses a result clip (T-0211). The bytes are fine, so saving and sharing still work.
  ///
  /// In en, this message translates to:
  /// **'It is still yours: Save and Share work as usual.'**
  String get clipCannotPlayMessage;

  /// No description provided for @generationProgressStep.
  ///
  /// In en, this message translates to:
  /// **'Step {step} of {total}'**
  String generationProgressStep(int step, int total);

  /// No description provided for @reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get reconnecting;

  /// Contractual (docs/recovery.md). The English half is quoted from the contract word for word.
  ///
  /// In en, this message translates to:
  /// **'Connection lost.'**
  String get connectionLostTitle;

  /// Contractual (docs/recovery.md), quoted word for word. Drawn only while a check is actually running.
  ///
  /// In en, this message translates to:
  /// **'Checking whether the generation survived.'**
  String get checkingSurvival;

  /// No description provided for @survivalUnknown.
  ///
  /// In en, this message translates to:
  /// **'The server is still unreachable, so whether the generation survived is unknown. Reconnect, or choose another server.'**
  String get survivalUnknown;

  /// Contractual (docs/recovery.md), quoted word for word.
  ///
  /// In en, this message translates to:
  /// **'Generation state could not be recovered.'**
  String get stateUnrecoverable;

  /// No description provided for @generationLostMessage.
  ///
  /// In en, this message translates to:
  /// **'The server no longer has this generation. Your inputs are still here, so you can start it again.'**
  String get generationLostMessage;

  /// No description provided for @fieldRequired.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get fieldRequired;

  /// No description provided for @formAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get formAdvanced;

  /// No description provided for @formAdvancedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 setting} other{{count} settings}}'**
  String formAdvancedCount(int count);

  /// No description provided for @generate.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get generate;

  /// No description provided for @saveMyDefaults.
  ///
  /// In en, this message translates to:
  /// **'Save settings as my defaults'**
  String get saveMyDefaults;

  /// No description provided for @resetToMyDefaults.
  ///
  /// In en, this message translates to:
  /// **'Reset settings to my defaults'**
  String get resetToMyDefaults;

  /// No description provided for @resetToWorkflowDefaults.
  ///
  /// In en, this message translates to:
  /// **'Reset settings to workflow defaults'**
  String get resetToWorkflowDefaults;

  /// No description provided for @useExample.
  ///
  /// In en, this message translates to:
  /// **'Use example'**
  String get useExample;

  /// No description provided for @replaceWrittenTextTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace what you wrote?'**
  String get replaceWrittenTextTitle;

  /// No description provided for @useExampleConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'The example would take the place of the text in {fieldLabel}.'**
  String useExampleConfirmBody(String fieldLabel);

  /// No description provided for @keepWrittenText.
  ///
  /// In en, this message translates to:
  /// **'Keep mine'**
  String get keepWrittenText;

  /// Puts a new random value in the seed field, beside a dice icon. Take the ordinary way your language says 'do this at random' rather than translating the English word for the quality of being random -- a word that means 'by accident' is the opposite of a button somebody presses on purpose. It need not be an imperative: the Russian is not one. An imperative was tried there and rejected on layout, not on register, because the row it sits in has no room to spare (T-0153); revisit it when that row is fixed.
  ///
  /// In en, this message translates to:
  /// **'Random'**
  String get fieldRandom;

  /// No description provided for @freezeSeed.
  ///
  /// In en, this message translates to:
  /// **'Freeze seed'**
  String get freezeSeed;

  /// No description provided for @freezeSeedOn.
  ///
  /// In en, this message translates to:
  /// **'Generate Again reuses this seed.'**
  String get freezeSeedOn;

  /// No description provided for @freezeSeedOff.
  ///
  /// In en, this message translates to:
  /// **'Generate Again uses a new seed.'**
  String get freezeSeedOff;

  /// No description provided for @unsupportedInput.
  ///
  /// In en, this message translates to:
  /// **'This app version cannot show this kind of input yet.'**
  String get unsupportedInput;

  /// The gateway honours straight ASCII double quotes and nothing else, so the quotation marks in this sentence must stay " in every locale even where the language would ordinarily use its own.
  ///
  /// In en, this message translates to:
  /// **'Text inside \"quotes\" is preserved.'**
  String get quoteHint;

  /// No description provided for @translationSentAsTyped.
  ///
  /// In en, this message translates to:
  /// **'This prompt is sent as typed, without translation.'**
  String get translationSentAsTyped;

  /// No description provided for @translationNoLanguages.
  ///
  /// In en, this message translates to:
  /// **'This PC is set to translate, but no languages are installed on it. A prompt in another language will fail unless you send it as typed.'**
  String get translationNoLanguages;

  /// No description provided for @translationNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'This PC is set to translate, but the translator is not installed on it. A prompt in another language will fail unless you send it as typed.'**
  String get translationNotInstalled;

  /// No description provided for @translationGeneric.
  ///
  /// In en, this message translates to:
  /// **'A prompt in another language is translated before generating.'**
  String get translationGeneric;

  /// No description provided for @translationPair.
  ///
  /// In en, this message translates to:
  /// **'A prompt in {from} is translated to {to} before generating.'**
  String translationPair(String from, String to);

  /// Between the source-language labels the server offers: RU or JA.
  ///
  /// In en, this message translates to:
  /// **' or '**
  String get translationOrSeparator;

  /// No description provided for @translationApplied.
  ///
  /// In en, this message translates to:
  /// **'Translated for this generation'**
  String get translationApplied;

  /// No description provided for @translationOriginal.
  ///
  /// In en, this message translates to:
  /// **'Original'**
  String get translationOriginal;

  /// No description provided for @translationSentToWorkflow.
  ///
  /// In en, this message translates to:
  /// **'Sent to workflow'**
  String get translationSentToWorkflow;

  /// No description provided for @issueNotAWholeNumber.
  ///
  /// In en, this message translates to:
  /// **'{fieldLabel} has to be a whole number.'**
  String issueNotAWholeNumber(String fieldLabel);

  /// No description provided for @issueNotANumber.
  ///
  /// In en, this message translates to:
  /// **'{fieldLabel} has to be a number.'**
  String issueNotANumber(String fieldLabel);

  /// No description provided for @issueOutOfRange.
  ///
  /// In en, this message translates to:
  /// **'{fieldLabel} has to be {range}.'**
  String issueOutOfRange(String fieldLabel, String range);

  /// No description provided for @issueMissing.
  ///
  /// In en, this message translates to:
  /// **'{fieldLabel} is needed before you can generate.'**
  String issueMissing(String fieldLabel);

  /// No description provided for @issueNotSelectableYet.
  ///
  /// In en, this message translates to:
  /// **'{fieldLabel} is needed, and choosing one is not available on this device.'**
  String issueNotSelectableYet(String fieldLabel);

  /// No description provided for @issueMediaUploading.
  ///
  /// In en, this message translates to:
  /// **'{fieldLabel} is still uploading.'**
  String issueMediaUploading(String fieldLabel);

  /// No description provided for @issueMediaFailed.
  ///
  /// In en, this message translates to:
  /// **'{fieldLabel} did not reach the server. {detail}'**
  String issueMediaFailed(String fieldLabel, String detail);

  /// No description provided for @issueUnsupportedType.
  ///
  /// In en, this message translates to:
  /// **'{fieldLabel} is a kind of input this version of the app cannot show yet.'**
  String issueUnsupportedType(String fieldLabel);

  /// No description provided for @generateNeeds.
  ///
  /// In en, this message translates to:
  /// **'Generate needs {fieldNames}.'**
  String generateNeeds(String fieldNames);

  /// No description provided for @generateBlockedNotSelectable.
  ///
  /// In en, this message translates to:
  /// **'Choosing a picture or a clip is not available on this device.'**
  String get generateBlockedNotSelectable;

  /// No description provided for @generateBlockedUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This workflow asks for something this app version cannot show yet.'**
  String get generateBlockedUnsupported;

  /// No description provided for @generateBlockedBusy.
  ///
  /// In en, this message translates to:
  /// **'Generate is unavailable until this generation finishes.'**
  String get generateBlockedBusy;

  /// No description provided for @rangeBetween.
  ///
  /// In en, this message translates to:
  /// **'between {min} and {max}'**
  String rangeBetween(String min, String max);

  /// No description provided for @rangeAtLeast.
  ///
  /// In en, this message translates to:
  /// **'{min} or more'**
  String rangeAtLeast(String min);

  /// No description provided for @rangeAtMost.
  ///
  /// In en, this message translates to:
  /// **'{max} or less'**
  String rangeAtMost(String max);

  /// No description provided for @rangeAnyNumber.
  ///
  /// In en, this message translates to:
  /// **'a number'**
  String get rangeAnyNumber;

  /// A frame count read back as a length. The numbers keep the digits and the decimal point the workflow itself uses, in every locale, so what is read matches what is submitted.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s at {fps} fps'**
  String durationReading(String seconds, String fps);

  /// No description provided for @durationReadingApproximate.
  ///
  /// In en, this message translates to:
  /// **'≈ {seconds} s at {fps} fps'**
  String durationReadingApproximate(String seconds, String fps);

  /// No description provided for @workflowPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a workflow'**
  String get workflowPickerTitle;

  /// Tooltip of the picker's button that reads the workflow list from the PC again, for a workflow added there while the app was open.
  ///
  /// In en, this message translates to:
  /// **'Refresh the list'**
  String get workflowsRefresh;

  /// No description provided for @workflowCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 workflow} other{{count} workflows}}'**
  String workflowCount(int count);

  /// The heading over workflows that declared no group of their own.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get workflowGroupOther;

  /// The picker filter's first option, and its default: every workflow, whatever group it is in. Every other option is a group name the gateway served and is never translated.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get workflowFilterAll;

  /// No description provided for @workflowWhatThisDoes.
  ///
  /// In en, this message translates to:
  /// **'What this does'**
  String get workflowWhatThisDoes;

  /// No description provided for @helpWhatItNeeds.
  ///
  /// In en, this message translates to:
  /// **'What it needs'**
  String get helpWhatItNeeds;

  /// No description provided for @helpBestFor.
  ///
  /// In en, this message translates to:
  /// **'Best for'**
  String get helpBestFor;

  /// No description provided for @helpHowToUse.
  ///
  /// In en, this message translates to:
  /// **'How to use it'**
  String get helpHowToUse;

  /// No description provided for @helpExamplePrompt.
  ///
  /// In en, this message translates to:
  /// **'Example prompt'**
  String get helpExamplePrompt;

  /// No description provided for @helpNotIdealFor.
  ///
  /// In en, this message translates to:
  /// **'Not ideal for'**
  String get helpNotIdealFor;

  /// No description provided for @helpDefaults.
  ///
  /// In en, this message translates to:
  /// **'Defaults'**
  String get helpDefaults;

  /// No description provided for @setupsHeading.
  ///
  /// In en, this message translates to:
  /// **'Setups'**
  String get setupsHeading;

  /// No description provided for @setupSaveWithProse.
  ///
  /// In en, this message translates to:
  /// **'Save prompt and settings as a setup'**
  String get setupSaveWithProse;

  /// No description provided for @setupSaveSettingsOnly.
  ///
  /// In en, this message translates to:
  /// **'Save settings as a setup'**
  String get setupSaveSettingsOnly;

  /// No description provided for @setupNameTitle.
  ///
  /// In en, this message translates to:
  /// **'Name this setup'**
  String get setupNameTitle;

  /// No description provided for @setupRenameTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename this setup'**
  String get setupRenameTitle;

  /// No description provided for @setupNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get setupNameLabel;

  /// No description provided for @setupApplyBody.
  ///
  /// In en, this message translates to:
  /// **'“{name}” would take the place of the text you have written in this form.'**
  String setupApplyBody(String name);

  /// No description provided for @setupForgetTitle.
  ///
  /// In en, this message translates to:
  /// **'Forget this setup?'**
  String get setupForgetTitle;

  /// No description provided for @setupForgetBody.
  ///
  /// In en, this message translates to:
  /// **'“{name}” would be gone. What is in the form now is not touched either way.'**
  String setupForgetBody(String name);

  /// No description provided for @setupKeepIt.
  ///
  /// In en, this message translates to:
  /// **'Keep it'**
  String get setupKeepIt;

  /// No description provided for @setupRenameTooltip.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get setupRenameTooltip;

  /// No description provided for @setupDeleteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get setupDeleteTooltip;
}

class _LDelegate extends LocalizationsDelegate<L> {
  const _LDelegate();

  @override
  Future<L> load(Locale locale) {
    return SynchronousFuture<L>(lookupL(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_LDelegate old) => false;
}

L lookupL(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return LEn();
    case 'ru':
      return LRu();
  }

  throw FlutterError(
    'L.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}

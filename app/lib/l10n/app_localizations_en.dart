// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class LEn extends L {
  LEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'LocalCanvas';

  @override
  String get ok => 'OK';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get rename => 'Rename';

  @override
  String get delete => 'Delete';

  @override
  String get tryAgain => 'Try again';

  @override
  String get checkAgain => 'Check again';

  @override
  String get chooseAnotherServer => 'Choose another server';

  @override
  String get reconnect => 'Reconnect';

  @override
  String get connect => 'Connect';

  @override
  String get change => 'Change';

  @override
  String get replace => 'Replace';

  @override
  String get remove => 'Remove';

  @override
  String get share => 'Share';

  @override
  String get on => 'On';

  @override
  String get off => 'Off';

  @override
  String get valueNone => '—';

  @override
  String get listSeparator => ', ';

  @override
  String listAnd(String head, String last) {
    return '$head and $last';
  }

  @override
  String get splitHandleLabel =>
      'Move the split between the controls and the picture';

  @override
  String get appearanceTitle => 'Appearance';

  @override
  String get appearanceNote =>
      'Light, dark, or whatever this phone is set to. This one stays on this phone — it is not in your profile.';

  @override
  String get appearanceLight => 'Light';

  @override
  String get appearanceDark => 'Dark';

  @override
  String get appearanceSystem => 'System';

  @override
  String get languageTitle => 'Language';

  @override
  String get languageNote =>
      'The language this app speaks. This one stays on this phone too — it is not in your profile.';

  @override
  String get languageSystem => 'System';

  @override
  String get connectTitle => 'Choose your server';

  @override
  String get connectIntro =>
      'LocalCanvas runs beside the generator on your computer. Pick it below, scan its pairing code, or type its address.';

  @override
  String get connectOnThisNetwork => 'On this network';

  @override
  String get scanPairingCode => 'Scan pairing code';

  @override
  String get enterAddress => 'Enter address';

  @override
  String get searchThisNetwork => 'Search this network';

  @override
  String get searchAgain => 'Search again';

  @override
  String get lookingForServers => 'Looking for servers…';

  @override
  String get discoveryEmptyTitle => 'No servers answered.';

  @override
  String get discoveryEmptyBody =>
      'Some home networks do not pass this kind of search along. The pairing code and the address below always work.';

  @override
  String get discoveryUnavailableTitle => 'Searching didn\'t work this time.';

  @override
  String get discoveryUnavailableBody =>
      'The pairing code and the address below always work.';

  @override
  String get discoveryFailureLabel => 'What the system reported';

  @override
  String get notAPairingCode =>
      'That code isn\'t a LocalCanvas pairing code. Scan the one your server shows, or enter its address.';

  @override
  String get manualEntryTitle => 'Server address';

  @override
  String get manualEntryNote =>
      'The address of the machine running LocalCanvas. Its startup output prints one.';

  @override
  String get manualEntryNotAnAddress =>
      'That doesn\'t look like an address. Try something like 192.0.2.42 or 192.0.2.42:7801.';

  @override
  String get scanHint => 'Point the camera at the code your server shows.';

  @override
  String get scanEnterAddressInstead => 'Enter the address instead';

  @override
  String get scannerPermissionDenied =>
      'LocalCanvas needs camera access to read a pairing code. You can allow it in Settings, or type the address instead.';

  @override
  String get scannerUnsupported =>
      'This device cannot scan codes. Type the address instead.';

  @override
  String get scannerFailed =>
      'The camera could not be started. Type the address instead.';

  @override
  String get connecting => 'Connecting…';

  @override
  String connectingTo(String serverName) {
    return 'Connecting to $serverName…';
  }

  @override
  String get problemUnreachableTitle =>
      'The LocalCanvas server can\'t be reached.';

  @override
  String problemUnreachableAt(String address) {
    return 'Nothing answered at $address. Check that the server is running and that this device is on the same network as it.';
  }

  @override
  String get problemUnreachableAnywhere =>
      'Nothing answered at that address. Check that the server is running and that this device is on the same network as it.';

  @override
  String get problemNotLocalCanvasTitle =>
      'That address isn\'t a LocalCanvas server.';

  @override
  String problemNotLocalCanvasAt(String address) {
    return 'Something answered at $address, but it did not identify itself as LocalCanvas. Check the address, or scan the pairing code the server shows.';
  }

  @override
  String get problemNotLocalCanvasAnywhere =>
      'Something answered at that address, but it did not identify itself as LocalCanvas. Check the address, or scan the pairing code the server shows.';

  @override
  String get problemIncompatibleTitle =>
      'This server speaks a different version.';

  @override
  String problemIncompatibleAt(String address, int reported, int client) {
    return 'The server at $address uses API version $reported, and this app speaks version $client. Update whichever of the two is older, then try again.';
  }

  @override
  String problemIncompatibleAnywhere(int reported, int client) {
    return 'The server at that address uses API version $reported, and this app speaks version $client. Update whichever of the two is older, then try again.';
  }

  @override
  String problemIncompatibleUnknownAt(String address, int client) {
    return 'The server at $address uses an API version it did not name, and this app speaks version $client. Update whichever of the two is older, then try again.';
  }

  @override
  String problemIncompatibleUnknownAnywhere(int client) {
    return 'The server at that address uses an API version it did not name, and this app speaks version $client. Update whichever of the two is older, then try again.';
  }

  @override
  String get problemComfyTitle => 'Connected, but ComfyUI isn\'t running.';

  @override
  String problemComfy(String serverName) {
    return '$serverName answered, but it cannot generate anything yet. Start ComfyUI on that machine, then try again.';
  }

  @override
  String problemComfyWithDetail(String serverName, String detail) {
    return '$serverName answered, but it cannot generate anything yet. $detail Start ComfyUI on that machine, then try again.';
  }

  @override
  String get problemServerFallbackName => 'The server';

  @override
  String get serverConnected => 'Connected';

  @override
  String get serverReady => 'Ready';

  @override
  String get serverNotReady => 'Not ready to generate';

  @override
  String get serverDetailAddress => 'Address';

  @override
  String get serverDetailServerVersion => 'Server version';

  @override
  String get serverDetailApiVersion => 'API version';

  @override
  String get serverDetailGenerator => 'Generator';

  @override
  String get resultOpenLarger => 'Open the picture almost full screen';

  @override
  String get serverDetailReconnectAttempts => 'Reconnect attempts';

  @override
  String get reconnectAttemptsFewer => 'Fewer reconnect attempts';

  @override
  String get reconnectAttemptsMore => 'More reconnect attempts';

  @override
  String serverApiVersionValue(String server, String client) {
    return '$server (this app speaks $client)';
  }

  @override
  String get generatorRunning => 'Running';

  @override
  String get generatorStarting => 'Starting up';

  @override
  String get generatorNotRunning => 'Not running';

  @override
  String get generatorUnknown => 'Unknown';

  @override
  String get workflowsEmptyTitle => 'Nothing to create with yet';

  @override
  String workflowsEmptyBody(String serverName) {
    return '$serverName has no workflows to offer. They are chosen on the computer running it, and appear here once it publishes them.';
  }

  @override
  String get thisServer => 'This server';

  @override
  String get creationIdleChosenTitle => 'Ready when you are';

  @override
  String creationIdleChosenBody(String workflowName) {
    return 'What you generate with $workflowName appears here.';
  }

  @override
  String get creationIdleUnchosenTitle => 'Pick something to create';

  @override
  String get creationIdleUnchosenBody =>
      'Choose a workflow to see what it can do and what it needs from you.';

  @override
  String get chooseAWorkflow => 'Choose a workflow';

  @override
  String missingWorkflowTitle(String workflowName) {
    return '“$workflowName” is no longer on this server.';
  }

  @override
  String get missingWorkflowBody =>
      'Nothing was chosen in its place. What you typed is still here — pick another workflow to use it.';

  @override
  String defaultsSavedFor(String workflowName) {
    return 'Settings saved as your defaults for $workflowName.';
  }

  @override
  String setupSavedAs(String name) {
    return 'Saved as “$name”.';
  }

  @override
  String setupIsGone(String name) {
    return '“$name” is gone.';
  }

  @override
  String get profileTitle => 'Your profile';

  @override
  String get profileNote =>
      'Your saved settings and setups, as one file you can move to another phone. Nothing about this server, and nothing you have generated, is in it.';

  @override
  String get profileExport => 'Export my profile';

  @override
  String get profileImport => 'Import a profile';

  @override
  String get profileFileTypeLabel => 'LocalCanvas profile';

  @override
  String get profileImportedNothing => 'That profile had nothing in it.';

  @override
  String profileImported(String what) {
    return 'Imported $what. Nothing of yours was removed. Use \"Reset settings to my defaults\" to apply them here.';
  }

  @override
  String profileImportedWorkflows(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'settings for $count workflows',
      one: 'settings for 1 workflow',
    );
    return '$_temp0';
  }

  @override
  String profileImportedSetups(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count setups',
      one: '1 setup',
    );
    return '$_temp0';
  }

  @override
  String get profileNotAProfileTitle =>
      'That file is not a LocalCanvas profile.';

  @override
  String get profileNotAProfileMessage =>
      'Choose the file an export produced. It is a .json file and it starts by saying what it is.';

  @override
  String get profileNewerTitle => 'That profile is from a newer LocalCanvas.';

  @override
  String profileNewerMessage(int found, int supported) {
    return 'It is a version $found profile and this app reads version $supported. Nothing was changed on this device. Update LocalCanvas, then import it again.';
  }

  @override
  String get didntWorkTitle => 'That didn\'t work.';

  @override
  String get tryAgainMessage => 'Try again.';

  @override
  String get exportAccessDeniedTitle =>
      'LocalCanvas can\'t save to your gallery.';

  @override
  String get exportAccessDeniedMessage =>
      'Allow it to add photos and videos in Android settings, then try again.';

  @override
  String get exportNotEnoughSpaceTitle =>
      'There is not enough space to save this.';

  @override
  String get exportNotEnoughSpaceMessage =>
      'Free some space on this device, then try again.';

  @override
  String get exportUnsupportedFormatTitle =>
      'Your gallery could not take this file.';

  @override
  String get exportUnsupportedFormatMessage =>
      'The server produced a kind of file the gallery does not accept. Share it instead to keep it.';

  @override
  String get exportSavedToGallery => 'Saved to your gallery.';

  @override
  String get serverDidntAnswerTitle => 'The server didn\'t answer.';

  @override
  String get serverUnreachableMessage =>
      'It may have gone off the network or been stopped. Check that it is running, then try again.';

  @override
  String get serverUnreadableTitle => 'The server\'s answer could not be read.';

  @override
  String get serverUnreadableMessage =>
      'This app and the server may be different versions. Try again, and update whichever of the two is older if it keeps happening.';

  @override
  String get serverRefusedTitle => 'The server could not do that.';

  @override
  String get serverRefusedNoReason => 'The server did not say why.';

  @override
  String get mediaUploadUnreachableTitle =>
      'The server didn\'t take the upload.';

  @override
  String get mediaUploadRefusedTitle => 'The server could not take that file.';

  @override
  String get mediaNotAllowedTitle => 'That file could not be opened.';

  @override
  String get mediaNotAllowedMessage =>
      'Choose it again, and allow LocalCanvas to read it when Android asks.';

  @override
  String get mediaGoneTitle => 'That file is no longer available.';

  @override
  String get mediaGoneMessage => 'Choose it again.';

  @override
  String get gatewayErrorUnsupportedMediaType =>
      'This server does not accept that kind of file.';

  @override
  String get gatewayErrorUnsupportedImageHeic =>
      'That photo is in HEIC format, which LocalCanvas cannot use yet. Choose a JPEG or PNG, or turn off high-efficiency (HEIC) photos in the camera settings.';

  @override
  String get gatewayErrorEmptyUpload => 'That file is empty.';

  @override
  String get gatewayErrorInvalidFilename =>
      'That file\'s name cannot be used. Rename it, then choose it again.';

  @override
  String get gatewayErrorFileTooLarge =>
      'That file is larger than this server accepts. Choose a smaller one.';

  @override
  String get gatewayErrorMediaKindMismatch =>
      'That file is not the kind this field asks for.';

  @override
  String get gatewayErrorWorkflowNotFound =>
      'That workflow is no longer on this server.';

  @override
  String get mediaNeedsPicture =>
      'This workflow works from a picture you choose.';

  @override
  String get mediaNeedsClip => 'This workflow works from a clip you choose.';

  @override
  String get mediaCannotChoose =>
      'Choosing one is not available on this device.';

  @override
  String get mediaChoosePicture => 'Choose picture';

  @override
  String get mediaChooseClip => 'Choose clip';

  @override
  String get mediaReadyToUse => 'Ready to use';

  @override
  String get mediaChosenPicture => 'Chosen picture';

  @override
  String get mediaChosenClip => 'Chosen clip';

  @override
  String get mediaNounPicture => 'picture';

  @override
  String get mediaNounClip => 'clip';

  @override
  String get mediaUploading => 'Uploading…';

  @override
  String get mediaFinishing => 'Finishing…';

  @override
  String mediaUploadingProgress(String sent, String total) {
    return 'Uploading… $sent of $total';
  }

  @override
  String byteCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count bytes',
      one: '1 byte',
    );
    return '$_temp0';
  }

  @override
  String byteSize(String amount, String unit) {
    return '$amount $unit';
  }

  @override
  String get byteUnitKilo => 'kB';

  @override
  String get byteUnitMega => 'MB';

  @override
  String get byteUnitGiga => 'GB';

  @override
  String get byteUnitTera => 'TB';

  @override
  String get generationUploadingTitle => 'Sending this to the server…';

  @override
  String get generationUploadingMessage => 'Your inputs are on their way.';

  @override
  String get generationQueuedTitle => 'Waiting in the queue';

  @override
  String get generationQueuedMessage =>
      'The server has it and has not started yet.';

  @override
  String get generationGeneratingTitle => 'Generating';

  @override
  String get generationTakesAWhile => 'This can take a while.';

  @override
  String get generationCancelledTitle => 'Cancelled.';

  @override
  String get generationCancelledMessage => 'Nothing was generated.';

  @override
  String get generationFailedTitle => 'That generation didn\'t finish.';

  @override
  String get generationStopping => 'Stopping…';

  @override
  String get generationCancel => 'Cancel';

  @override
  String get generateAgain => 'Generate Again';

  @override
  String get generationSaveAsSetup => 'Save as a setup';

  @override
  String get resultPreviousResult => 'Previous result';

  @override
  String get resultNextResult => 'Next result';

  @override
  String resultHistoryPosition(int position, int total) {
    return '$position of $total';
  }

  @override
  String get generationFinishedTitle => 'Finished.';

  @override
  String get generationNoOutput =>
      'The server reported no output for this generation.';

  @override
  String get generationClipReadyTitle => 'Your clip is ready.';

  @override
  String get generationClipReadyMessage => 'Save it or share it to watch it.';

  @override
  String get generationPreviewFailedTitle =>
      'The picture couldn\'t be fetched.';

  @override
  String get generationClipFetchFailedTitle => 'The clip couldn\'t be fetched.';

  @override
  String get clipPlay => 'Play';

  @override
  String get clipPause => 'Pause';

  @override
  String get clipSoundOn => 'Turn the sound on';

  @override
  String get clipSoundOff => 'Turn the sound off';

  @override
  String get clipOpenLarger => 'Open the clip almost full screen';

  @override
  String get clipCannotPlayTitle => 'This phone can\'t play the clip.';

  @override
  String get clipCannotPlayMessage =>
      'It is still yours: Save and Share work as usual.';

  @override
  String generationProgressStep(int step, int total) {
    return 'Step $step of $total';
  }

  @override
  String get reconnecting => 'Reconnecting…';

  @override
  String get connectionLostTitle => 'Connection lost.';

  @override
  String get checkingSurvival => 'Checking whether the generation survived.';

  @override
  String get survivalUnknown =>
      'The server is still unreachable, so whether the generation survived is unknown. Reconnect, or choose another server.';

  @override
  String get stateUnrecoverable => 'Generation state could not be recovered.';

  @override
  String get generationLostMessage =>
      'The server no longer has this generation. Your inputs are still here, so you can start it again.';

  @override
  String get fieldRequired => 'Required';

  @override
  String get formAdvanced => 'Advanced';

  @override
  String formAdvancedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count settings',
      one: '1 setting',
    );
    return '$_temp0';
  }

  @override
  String get generate => 'Generate';

  @override
  String get saveMyDefaults => 'Save settings as my defaults';

  @override
  String get resetToMyDefaults => 'Reset settings to my defaults';

  @override
  String get resetToWorkflowDefaults => 'Reset settings to workflow defaults';

  @override
  String get useExample => 'Use example';

  @override
  String get replaceWrittenTextTitle => 'Replace what you wrote?';

  @override
  String useExampleConfirmBody(String fieldLabel) {
    return 'The example would take the place of the text in $fieldLabel.';
  }

  @override
  String get keepWrittenText => 'Keep mine';

  @override
  String get fieldRandom => 'Random';

  @override
  String get freezeSeed => 'Freeze seed';

  @override
  String get freezeSeedOn => 'Generate Again reuses this seed.';

  @override
  String get freezeSeedOff => 'Generate Again uses a new seed.';

  @override
  String get unsupportedInput =>
      'This app version cannot show this kind of input yet.';

  @override
  String get quoteHint => 'Text inside \"quotes\" is preserved.';

  @override
  String get translationSentAsTyped =>
      'This prompt is sent as typed, without translation.';

  @override
  String get translationNoLanguages =>
      'This PC is set to translate, but no languages are installed on it. A prompt in another language will fail unless you send it as typed.';

  @override
  String get translationNotInstalled =>
      'This PC is set to translate, but the translator is not installed on it. A prompt in another language will fail unless you send it as typed.';

  @override
  String get translationGeneric =>
      'A prompt in another language is translated before generating.';

  @override
  String translationPair(String from, String to) {
    return 'A prompt in $from is translated to $to before generating.';
  }

  @override
  String get translationOrSeparator => ' or ';

  @override
  String get translationApplied => 'Translated for this generation';

  @override
  String get translationOriginal => 'Original';

  @override
  String get translationSentToWorkflow => 'Sent to workflow';

  @override
  String issueNotAWholeNumber(String fieldLabel) {
    return '$fieldLabel has to be a whole number.';
  }

  @override
  String issueNotANumber(String fieldLabel) {
    return '$fieldLabel has to be a number.';
  }

  @override
  String issueOutOfRange(String fieldLabel, String range) {
    return '$fieldLabel has to be $range.';
  }

  @override
  String issueMissing(String fieldLabel) {
    return '$fieldLabel is needed before you can generate.';
  }

  @override
  String issueNotSelectableYet(String fieldLabel) {
    return '$fieldLabel is needed, and choosing one is not available on this device.';
  }

  @override
  String issueMediaUploading(String fieldLabel) {
    return '$fieldLabel is still uploading.';
  }

  @override
  String issueMediaFailed(String fieldLabel, String detail) {
    return '$fieldLabel did not reach the server. $detail';
  }

  @override
  String issueUnsupportedType(String fieldLabel) {
    return '$fieldLabel is a kind of input this version of the app cannot show yet.';
  }

  @override
  String generateNeeds(String fieldNames) {
    return 'Generate needs $fieldNames.';
  }

  @override
  String get generateBlockedNotSelectable =>
      'Choosing a picture or a clip is not available on this device.';

  @override
  String get generateBlockedUnsupported =>
      'This workflow asks for something this app version cannot show yet.';

  @override
  String get generateBlockedBusy =>
      'Generate is unavailable until this generation finishes.';

  @override
  String rangeBetween(String min, String max) {
    return 'between $min and $max';
  }

  @override
  String rangeAtLeast(String min) {
    return '$min or more';
  }

  @override
  String rangeAtMost(String max) {
    return '$max or less';
  }

  @override
  String get rangeAnyNumber => 'a number';

  @override
  String durationReading(String seconds, String fps) {
    return '$seconds s at $fps fps';
  }

  @override
  String durationReadingApproximate(String seconds, String fps) {
    return '≈ $seconds s at $fps fps';
  }

  @override
  String get workflowPickerTitle => 'Choose a workflow';

  @override
  String get workflowsRefresh => 'Refresh the list';

  @override
  String workflowCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count workflows',
      one: '1 workflow',
    );
    return '$_temp0';
  }

  @override
  String get workflowGroupOther => 'Other';

  @override
  String get workflowFilterAll => 'All';

  @override
  String get workflowWhatThisDoes => 'What this does';

  @override
  String get helpWhatItNeeds => 'What it needs';

  @override
  String get helpBestFor => 'Best for';

  @override
  String get helpHowToUse => 'How to use it';

  @override
  String get helpExamplePrompt => 'Example prompt';

  @override
  String get helpNotIdealFor => 'Not ideal for';

  @override
  String get helpDefaults => 'Defaults';

  @override
  String get setupsHeading => 'Setups';

  @override
  String get setupSaveWithProse => 'Save prompt and settings as a setup';

  @override
  String get setupSaveSettingsOnly => 'Save settings as a setup';

  @override
  String get setupNameTitle => 'Name this setup';

  @override
  String get setupRenameTitle => 'Rename this setup';

  @override
  String get setupNameLabel => 'Name';

  @override
  String setupApplyBody(String name) {
    return '“$name” would take the place of the text you have written in this form.';
  }

  @override
  String get setupForgetTitle => 'Forget this setup?';

  @override
  String setupForgetBody(String name) {
    return '“$name” would be gone. What is in the form now is not touched either way.';
  }

  @override
  String get setupKeepIt => 'Keep it';

  @override
  String get setupRenameTooltip => 'Rename';

  @override
  String get setupDeleteTooltip => 'Delete';
}

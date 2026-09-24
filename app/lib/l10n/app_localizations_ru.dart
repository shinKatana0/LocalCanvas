// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class LRu extends L {
  LRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'LocalCanvas';

  @override
  String get ok => 'ОК';

  @override
  String get cancel => 'Отмена';

  @override
  String get save => 'Сохранить';

  @override
  String get rename => 'Переименовать';

  @override
  String get delete => 'Удалить';

  @override
  String get tryAgain => 'Попробовать снова';

  @override
  String get checkAgain => 'Проверить снова';

  @override
  String get chooseAnotherServer => 'Выбрать другой сервер';

  @override
  String get reconnect => 'Переподключиться';

  @override
  String get connect => 'Подключиться';

  @override
  String get change => 'Изменить';

  @override
  String get replace => 'Заменить';

  @override
  String get remove => 'Убрать';

  @override
  String get share => 'Поделиться';

  @override
  String get on => 'Вкл.';

  @override
  String get off => 'Выкл.';

  @override
  String get valueNone => '—';

  @override
  String get listSeparator => ', ';

  @override
  String listAnd(String head, String last) {
    return '$head и $last';
  }

  @override
  String get splitHandleLabel =>
      'Передвиньте границу между настройками и изображением';

  @override
  String get appearanceTitle => 'Оформление';

  @override
  String get appearanceNote =>
      'Светлое, тёмное или как настроен этот телефон. Это остаётся на телефоне — в ваш профиль оно не входит.';

  @override
  String get appearanceLight => 'Светлое';

  @override
  String get appearanceDark => 'Тёмное';

  @override
  String get appearanceSystem => 'Системное';

  @override
  String get languageTitle => 'Язык';

  @override
  String get languageNote =>
      'На каком языке говорит приложение. Это тоже остаётся на телефоне — в ваш профиль оно не входит.';

  @override
  String get languageSystem => 'Системный';

  @override
  String get connectTitle => 'Выберите сервер';

  @override
  String get connectIntro =>
      'LocalCanvas работает на вашем компьютере, рядом с генератором. Выберите его ниже, отсканируйте код подключения или введите адрес.';

  @override
  String get connectOnThisNetwork => 'В этой сети';

  @override
  String get scanPairingCode => 'Сканировать код подключения';

  @override
  String get enterAddress => 'Ввести адрес';

  @override
  String get searchThisNetwork => 'Искать в этой сети';

  @override
  String get searchAgain => 'Искать снова';

  @override
  String get lookingForServers => 'Идёт поиск серверов…';

  @override
  String get discoveryEmptyTitle => 'Ни один сервер не ответил.';

  @override
  String get discoveryEmptyBody =>
      'Некоторые домашние сети не пропускают такой поиск. Код подключения и адрес ниже работают всегда.';

  @override
  String get discoveryUnavailableTitle => 'В этот раз поиск не сработал.';

  @override
  String get discoveryUnavailableBody =>
      'Код подключения и адрес ниже работают всегда.';

  @override
  String get discoveryFailureLabel => 'Что сообщила система';

  @override
  String get notAPairingCode =>
      'Это не код подключения LocalCanvas. Отсканируйте тот, который показывает ваш сервер, или введите его адрес.';

  @override
  String get manualEntryTitle => 'Адрес сервера';

  @override
  String get manualEntryNote =>
      'Адрес компьютера, на котором работает LocalCanvas. При запуске он печатает его сам.';

  @override
  String get manualEntryNotAnAddress =>
      'Это не похоже на адрес. Попробуйте что-нибудь вроде 192.0.2.42 или 192.0.2.42:7801.';

  @override
  String get scanHint =>
      'Наведите камеру на код, который показывает ваш сервер.';

  @override
  String get scanEnterAddressInstead => 'Ввести адрес вручную';

  @override
  String get scannerPermissionDenied =>
      'Чтобы прочитать код подключения, LocalCanvas нужен доступ к камере. Его можно дать в настройках — или ввести адрес вручную.';

  @override
  String get scannerUnsupported =>
      'Это устройство не умеет сканировать коды. Введите адрес вручную.';

  @override
  String get scannerFailed =>
      'Камеру не удалось запустить. Введите адрес вручную.';

  @override
  String get connecting => 'Подключение…';

  @override
  String connectingTo(String serverName) {
    return 'Подключение к $serverName…';
  }

  @override
  String get problemUnreachableTitle =>
      'Не удаётся связаться с сервером LocalCanvas.';

  @override
  String problemUnreachableAt(String address) {
    return 'По адресу $address никто не ответил. Проверьте, что сервер запущен и что это устройство в той же сети, что и он.';
  }

  @override
  String get problemUnreachableAnywhere =>
      'По этому адресу никто не ответил. Проверьте, что сервер запущен и что это устройство в той же сети, что и он.';

  @override
  String get problemNotLocalCanvasTitle =>
      'По этому адресу — не сервер LocalCanvas.';

  @override
  String problemNotLocalCanvasAt(String address) {
    return 'По адресу $address кто-то ответил, но не представился как LocalCanvas. Проверьте адрес или отсканируйте код подключения, который показывает сервер.';
  }

  @override
  String get problemNotLocalCanvasAnywhere =>
      'По этому адресу кто-то ответил, но не представился как LocalCanvas. Проверьте адрес или отсканируйте код подключения, который показывает сервер.';

  @override
  String get problemIncompatibleTitle =>
      'Этот сервер говорит на другой версии.';

  @override
  String problemIncompatibleAt(String address, int reported, int client) {
    return 'Сервер по адресу $address использует версию API $reported, а это приложение говорит на версии $client. Обновите то из двух, что старее, и попробуйте снова.';
  }

  @override
  String problemIncompatibleAnywhere(int reported, int client) {
    return 'Сервер по этому адресу использует версию API $reported, а это приложение говорит на версии $client. Обновите то из двух, что старее, и попробуйте снова.';
  }

  @override
  String problemIncompatibleUnknownAt(String address, int client) {
    return 'Сервер по адресу $address не назвал версию API, а это приложение говорит на версии $client. Обновите то из двух, что старее, и попробуйте снова.';
  }

  @override
  String problemIncompatibleUnknownAnywhere(int client) {
    return 'Сервер по этому адресу не назвал версию API, а это приложение говорит на версии $client. Обновите то из двух, что старее, и попробуйте снова.';
  }

  @override
  String get problemComfyTitle => 'Подключено, но ComfyUI не запущен.';

  @override
  String problemComfy(String serverName) {
    return '$serverName ответил, но сгенерировать пока ничего не может. Запустите на той машине ComfyUI и попробуйте снова.';
  }

  @override
  String problemComfyWithDetail(String serverName, String detail) {
    return '$serverName ответил, но сгенерировать пока ничего не может. $detail Запустите на той машине ComfyUI и попробуйте снова.';
  }

  @override
  String get problemServerFallbackName => 'Сервер';

  @override
  String get serverConnected => 'Подключено';

  @override
  String get serverReady => 'Готов';

  @override
  String get serverNotReady => 'Не готов к генерации';

  @override
  String get serverDetailAddress => 'Адрес';

  @override
  String get serverDetailServerVersion => 'Версия сервера';

  @override
  String get serverDetailApiVersion => 'Версия API';

  @override
  String get serverDetailGenerator => 'Генератор';

  @override
  String get resultOpenLarger => 'Открыть картинку почти на весь экран';

  @override
  String get serverDetailReconnectAttempts => 'Попыток переподключения';

  @override
  String get reconnectAttemptsFewer => 'Меньше попыток переподключения';

  @override
  String get reconnectAttemptsMore => 'Больше попыток переподключения';

  @override
  String serverApiVersionValue(String server, String client) {
    return '$server (приложение говорит на $client)';
  }

  @override
  String get generatorRunning => 'Работает';

  @override
  String get generatorStarting => 'Запускается';

  @override
  String get generatorNotRunning => 'Не работает';

  @override
  String get generatorUnknown => 'Неизвестно';

  @override
  String get workflowsEmptyTitle => 'Пока нечем создавать';

  @override
  String workflowsEmptyBody(String serverName) {
    return '$serverName не предлагает ни одного воркфлоу. Их выбирают на том компьютере, где он работает, и они появятся здесь, как только он их опубликует.';
  }

  @override
  String get thisServer => 'Этот сервер';

  @override
  String get creationIdleChosenTitle => 'Можно начинать';

  @override
  String creationIdleChosenBody(String workflowName) {
    return 'Здесь появится то, что вы сгенерируете в «$workflowName».';
  }

  @override
  String get creationIdleUnchosenTitle => 'Выберите, что создавать';

  @override
  String get creationIdleUnchosenBody =>
      'Выберите воркфлоу, чтобы увидеть, что он умеет и что ему нужно от вас.';

  @override
  String get chooseAWorkflow => 'Выбрать воркфлоу';

  @override
  String missingWorkflowTitle(String workflowName) {
    return '«$workflowName» больше нет на этом сервере.';
  }

  @override
  String get missingWorkflowBody =>
      'Взамен ничего не выбрано. То, что вы написали, осталось на месте — выберите другой воркфлоу, чтобы это использовать.';

  @override
  String defaultsSavedFor(String workflowName) {
    return 'Настройки сохранены как ваши значения по умолчанию для «$workflowName».';
  }

  @override
  String setupSavedAs(String name) {
    return 'Сохранено как «$name».';
  }

  @override
  String setupIsGone(String name) {
    return '«$name» больше нет.';
  }

  @override
  String get profileTitle => 'Ваш профиль';

  @override
  String get profileNote =>
      'Ваши сохранённые настройки и наборы — одним файлом, который можно перенести на другой телефон. В нём нет ничего об этом сервере и ничего из того, что вы сгенерировали.';

  @override
  String get profileExport => 'Экспортировать мой профиль';

  @override
  String get profileImport => 'Импортировать профиль';

  @override
  String get profileFileTypeLabel => 'Профиль LocalCanvas';

  @override
  String get profileImportedNothing => 'В этом профиле ничего не было.';

  @override
  String profileImported(String what) {
    return 'Импортировано: $what. Ничего вашего не удалено. Чтобы применить их здесь, нажмите «Сбросить настройки к моим значениям».';
  }

  @override
  String profileImportedWorkflows(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'настройки для $count воркфлоу',
    );
    return '$_temp0';
  }

  @override
  String profileImportedSetups(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count набора',
      many: '$count наборов',
      few: '$count набора',
      one: '$count набор',
    );
    return '$_temp0';
  }

  @override
  String get profileNotAProfileTitle => 'Этот файл — не профиль LocalCanvas.';

  @override
  String get profileNotAProfileMessage =>
      'Выберите файл, который создал экспорт. Это файл .json, и в самом его начале написано, что это такое.';

  @override
  String get profileNewerTitle =>
      'Этот профиль — от более новой версии LocalCanvas.';

  @override
  String profileNewerMessage(int found, int supported) {
    return 'Это профиль версии $found, а приложение читает версию $supported. На этом устройстве ничего не изменилось. Обновите LocalCanvas и импортируйте его снова.';
  }

  @override
  String get didntWorkTitle => 'Не получилось.';

  @override
  String get tryAgainMessage => 'Попробуйте снова.';

  @override
  String get exportAccessDeniedTitle =>
      'LocalCanvas не может сохранять в вашу галерею.';

  @override
  String get exportAccessDeniedMessage =>
      'Разрешите ему добавлять фото и видео в настройках Android и попробуйте снова.';

  @override
  String get exportNotEnoughSpaceTitle => 'Для сохранения не хватает места.';

  @override
  String get exportNotEnoughSpaceMessage =>
      'Освободите место на устройстве и попробуйте снова.';

  @override
  String get exportUnsupportedFormatTitle => 'Галерея не приняла этот файл.';

  @override
  String get exportUnsupportedFormatMessage =>
      'Сервер создал файл такого вида, который галерея не принимает. Чтобы сохранить его, отправьте его через «Поделиться».';

  @override
  String get exportSavedToGallery => 'Сохранено в вашу галерею.';

  @override
  String get serverDidntAnswerTitle => 'Сервер не ответил.';

  @override
  String get serverUnreachableMessage =>
      'Возможно, он пропал из сети или был остановлен. Проверьте, что он запущен, и попробуйте снова.';

  @override
  String get serverUnreadableTitle => 'Ответ сервера не удалось прочитать.';

  @override
  String get serverUnreadableMessage =>
      'Возможно, у приложения и сервера разные версии. Попробуйте снова, а если это повторяется — обновите то из двух, что старее.';

  @override
  String get serverRefusedTitle => 'Сервер не смог это сделать.';

  @override
  String get serverRefusedNoReason => 'Сервер не сказал почему.';

  @override
  String get mediaUploadUnreachableTitle => 'Сервер не принял загрузку.';

  @override
  String get mediaUploadRefusedTitle => 'Сервер не смог принять этот файл.';

  @override
  String get mediaNotAllowedTitle => 'Этот файл не удалось открыть.';

  @override
  String get mediaNotAllowedMessage =>
      'Выберите его снова и разрешите LocalCanvas прочитать его, когда Android спросит.';

  @override
  String get mediaGoneTitle => 'Этого файла больше нет.';

  @override
  String get mediaGoneMessage => 'Выберите его снова.';

  @override
  String get gatewayErrorUnsupportedMediaType =>
      'Этот сервер не принимает файлы такого вида.';

  @override
  String get gatewayErrorUnsupportedImageHeic =>
      'Это фото в формате HEIC, который LocalCanvas пока не поддерживает. Выберите JPEG или PNG либо отключите в настройках камеры высокоэффективный формат фото (HEIC).';

  @override
  String get gatewayErrorEmptyUpload => 'Этот файл пуст.';

  @override
  String get gatewayErrorInvalidFilename =>
      'Имя этого файла использовать нельзя. Переименуйте его и выберите снова.';

  @override
  String get gatewayErrorFileTooLarge =>
      'Этот файл больше, чем принимает сервер. Выберите файл поменьше.';

  @override
  String get gatewayErrorMediaKindMismatch =>
      'Этот файл не того вида, какой нужен этому полю.';

  @override
  String get gatewayErrorWorkflowNotFound =>
      'Этого воркфлоу больше нет на этом сервере.';

  @override
  String get mediaNeedsPicture =>
      'Этот воркфлоу работает с картинкой, которую вы выберете.';

  @override
  String get mediaNeedsClip =>
      'Этот воркфлоу работает с видео, которое вы выберете.';

  @override
  String get mediaCannotChoose => 'На этом устройстве нельзя выбрать файл.';

  @override
  String get mediaChoosePicture => 'Выбрать картинку';

  @override
  String get mediaChooseClip => 'Выбрать видео';

  @override
  String get mediaReadyToUse => 'Готово к использованию';

  @override
  String get mediaChosenPicture => 'Выбранная картинка';

  @override
  String get mediaChosenClip => 'Выбранное видео';

  @override
  String get mediaNounPicture => 'картинка';

  @override
  String get mediaNounClip => 'видео';

  @override
  String get mediaUploading => 'Отправка…';

  @override
  String get mediaFinishing => 'Завершение…';

  @override
  String mediaUploadingProgress(String sent, String total) {
    return 'Отправка… $sent из $total';
  }

  @override
  String byteCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count байта',
      many: '$count байт',
      few: '$count байта',
      one: '$count байт',
    );
    return '$_temp0';
  }

  @override
  String byteSize(String amount, String unit) {
    return '$amount $unit';
  }

  @override
  String get byteUnitKilo => 'кБ';

  @override
  String get byteUnitMega => 'МБ';

  @override
  String get byteUnitGiga => 'ГБ';

  @override
  String get byteUnitTera => 'ТБ';

  @override
  String get generationUploadingTitle => 'Отправка на сервер…';

  @override
  String get generationUploadingMessage => 'То, что вы ввели, уже в пути.';

  @override
  String get generationQueuedTitle => 'Ожидание в очереди';

  @override
  String get generationQueuedMessage => 'Сервер получил задачу и ещё не начал.';

  @override
  String get generationGeneratingTitle => 'Генерация';

  @override
  String get generationTakesAWhile => 'Это может занять некоторое время.';

  @override
  String get generationCancelledTitle => 'Остановлено.';

  @override
  String get generationCancelledMessage => 'Ничего не сгенерировано.';

  @override
  String get generationFailedTitle => 'Эта генерация не завершилась.';

  @override
  String get generationStopping => 'Остановка…';

  @override
  String get generationCancel => 'Остановить';

  @override
  String get generateAgain => 'Сгенерировать снова';

  @override
  String get generationSaveAsSetup => 'Сохранить как набор';

  @override
  String get resultPreviousResult => 'Предыдущий результат';

  @override
  String get resultNextResult => 'Следующий результат';

  @override
  String resultHistoryPosition(int position, int total) {
    return '$position из $total';
  }

  @override
  String get generationFinishedTitle => 'Готово.';

  @override
  String get generationNoOutput =>
      'Сервер сообщил, что у этой генерации нет результата.';

  @override
  String get generationClipReadyTitle => 'Ваше видео готово.';

  @override
  String get generationClipReadyMessage =>
      'Сохраните его или поделитесь им, чтобы посмотреть.';

  @override
  String get generationPreviewFailedTitle => 'Картинку не удалось получить.';

  @override
  String get generationClipFetchFailedTitle => 'Видео не удалось получить.';

  @override
  String get clipPlay => 'Воспроизвести';

  @override
  String get clipPause => 'Пауза';

  @override
  String get clipSoundOn => 'Включить звук';

  @override
  String get clipSoundOff => 'Выключить звук';

  @override
  String get clipOpenLarger => 'Открыть видео почти на весь экран';

  @override
  String get clipCannotPlayTitle =>
      'Этот телефон не может воспроизвести видео.';

  @override
  String get clipCannotPlayMessage =>
      'Оно всё равно ваше: сохранить и поделиться можно как обычно.';

  @override
  String generationProgressStep(int step, int total) {
    return 'Шаг $step из $total';
  }

  @override
  String get reconnecting => 'Переподключение…';

  @override
  String get connectionLostTitle => 'Связь потеряна.';

  @override
  String get checkingSurvival => 'Проверяем, уцелела ли генерация.';

  @override
  String get survivalUnknown =>
      'Сервер по-прежнему недоступен, поэтому неизвестно, уцелела ли генерация. Переподключитесь или выберите другой сервер.';

  @override
  String get stateUnrecoverable =>
      'Состояние генерации восстановить не удалось.';

  @override
  String get generationLostMessage =>
      'У сервера больше нет этой генерации. То, что вы ввели, осталось на месте, так что её можно запустить заново.';

  @override
  String get fieldRequired => 'Обязательное';

  @override
  String get formAdvanced => 'Дополнительно';

  @override
  String formAdvancedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count настройки',
      many: '$count настроек',
      few: '$count настройки',
      one: '$count настройка',
    );
    return '$_temp0';
  }

  @override
  String get generate => 'Сгенерировать';

  @override
  String get saveMyDefaults => 'Сохранить настройки как мои значения';

  @override
  String get resetToMyDefaults => 'Сбросить настройки к моим значениям';

  @override
  String get resetToWorkflowDefaults =>
      'Сбросить настройки к значениям воркфлоу';

  @override
  String get useExample => 'Взять пример';

  @override
  String get replaceWrittenTextTitle => 'Заменить то, что вы написали?';

  @override
  String useExampleConfirmBody(String fieldLabel) {
    return 'Пример займёт место текста в поле «$fieldLabel».';
  }

  @override
  String get keepWrittenText => 'Оставить своё';

  @override
  String get fieldRandom => 'Наугад';

  @override
  String get freezeSeed => 'Зафиксировать seed';

  @override
  String get freezeSeedOn => '«Сгенерировать снова» возьмёт этот же seed.';

  @override
  String get freezeSeedOff => '«Сгенерировать снова» возьмёт новый seed.';

  @override
  String get unsupportedInput =>
      'Эта версия приложения пока не умеет показывать такой ввод.';

  @override
  String get quoteHint => 'Текст в \"кавычках\" сохраняется как есть.';

  @override
  String get translationSentAsTyped =>
      'Этот промпт отправляется как есть, без перевода.';

  @override
  String get translationNoLanguages =>
      'На этом компьютере включён перевод, но не установлен ни один язык. Промпт на другом языке не пройдёт, если не отправить его как есть.';

  @override
  String get translationNotInstalled =>
      'На этом компьютере включён перевод, но сам переводчик не установлен. Промпт на другом языке не пройдёт, если не отправить его как есть.';

  @override
  String get translationGeneric =>
      'Промпт на другом языке переводится перед генерацией.';

  @override
  String translationPair(String from, String to) {
    return 'Промпт на $from переводится на $to перед генерацией.';
  }

  @override
  String get translationOrSeparator => ' или ';

  @override
  String get translationApplied => 'Переведено для этой генерации';

  @override
  String get translationOriginal => 'Оригинал';

  @override
  String get translationSentToWorkflow => 'Отправлено в воркфлоу';

  @override
  String issueNotAWholeNumber(String fieldLabel) {
    return '«$fieldLabel» должно быть целым числом.';
  }

  @override
  String issueNotANumber(String fieldLabel) {
    return '«$fieldLabel» должно быть числом.';
  }

  @override
  String issueOutOfRange(String fieldLabel, String range) {
    return '«$fieldLabel» должно быть $range.';
  }

  @override
  String issueMissing(String fieldLabel) {
    return '«$fieldLabel» нужно заполнить, чтобы начать генерацию.';
  }

  @override
  String issueNotSelectableYet(String fieldLabel) {
    return '«$fieldLabel» нужно заполнить, а выбрать файл на этом устройстве нельзя.';
  }

  @override
  String issueMediaUploading(String fieldLabel) {
    return '«$fieldLabel» ещё отправляется.';
  }

  @override
  String issueMediaFailed(String fieldLabel, String detail) {
    return '«$fieldLabel» не дошло до сервера. $detail';
  }

  @override
  String issueUnsupportedType(String fieldLabel) {
    return '«$fieldLabel» — такой ввод, который эта версия приложения пока не умеет показывать.';
  }

  @override
  String generateNeeds(String fieldNames) {
    return 'Для генерации нужно заполнить: $fieldNames.';
  }

  @override
  String get generateBlockedNotSelectable =>
      'Выбрать картинку или видео на этом устройстве нельзя.';

  @override
  String get generateBlockedUnsupported =>
      'Этому воркфлоу нужно то, что эта версия приложения пока не умеет показывать.';

  @override
  String get generateBlockedBusy =>
      'Кнопка «Сгенерировать» недоступна, пока идёт эта генерация.';

  @override
  String rangeBetween(String min, String max) {
    return 'от $min до $max';
  }

  @override
  String rangeAtLeast(String min) {
    return '$min или больше';
  }

  @override
  String rangeAtMost(String max) {
    return '$max или меньше';
  }

  @override
  String get rangeAnyNumber => 'числом';

  @override
  String durationReading(String seconds, String fps) {
    return '$seconds с при $fps к/с';
  }

  @override
  String durationReadingApproximate(String seconds, String fps) {
    return '≈ $seconds с при $fps к/с';
  }

  @override
  String get workflowPickerTitle => 'Выберите воркфлоу';

  @override
  String get workflowsRefresh => 'Обновить список';

  @override
  String workflowCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count воркфлоу',
    );
    return '$_temp0';
  }

  @override
  String get workflowGroupOther => 'Прочее';

  @override
  String get workflowFilterAll => 'Все';

  @override
  String get workflowWhatThisDoes => 'Что это делает';

  @override
  String get helpWhatItNeeds => 'Что ему нужно';

  @override
  String get helpBestFor => 'Лучше всего для';

  @override
  String get helpHowToUse => 'Как этим пользоваться';

  @override
  String get helpExamplePrompt => 'Пример промпта';

  @override
  String get helpNotIdealFor => 'Плохо подходит для';

  @override
  String get helpDefaults => 'Значения по умолчанию';

  @override
  String get setupsHeading => 'Наборы';

  @override
  String get setupSaveWithProse => 'Сохранить промпт и настройки как набор';

  @override
  String get setupSaveSettingsOnly => 'Сохранить настройки как набор';

  @override
  String get setupNameTitle => 'Назовите этот набор';

  @override
  String get setupRenameTitle => 'Переименуйте этот набор';

  @override
  String get setupNameLabel => 'Название';

  @override
  String setupApplyBody(String name) {
    return '«$name» займёт место текста, который вы написали в этой форме.';
  }

  @override
  String get setupForgetTitle => 'Забыть этот набор?';

  @override
  String setupForgetBody(String name) {
    return '«$name» будет удалён. То, что сейчас в форме, в любом случае не изменится.';
  }

  @override
  String get setupKeepIt => 'Оставить';

  @override
  String get setupRenameTooltip => 'Переименовать';

  @override
  String get setupDeleteTooltip => 'Удалить';
}

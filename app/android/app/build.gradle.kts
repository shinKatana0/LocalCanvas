import com.android.build.api.artifact.SingleArtifact

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.localcanvas.localcanvas"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.localcanvas.localcanvas"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ---------------------------------------------------------------------------
// The APK a person sideloads says which build it is.
//
// v0.1 is installed by hand: the user copies an APK to the phone and picks
// it out of a file manager. `app-release.apk` is the same filename every Flutter
// app on the machine produces, for every version of every one of them, so two
// builds side by side are indistinguishable. This puts
// `LocalCanvas-<version>.apk` next to it -- and, for a split build,
// `LocalCanvas-<version>-<abi>.apk` next to each of those. The version is read
// off the artifact the build just produced; it is typed nowhere.
//
// MEASURED, Flutter 3.47.0 (Dart 3.13.0), 2026-09-10 -- WHY THIS IS A COPY AND
// NOT A RENAME. `flutter build apk` cannot be made to name that file:
//
//  * the Flutter Gradle plugin copies the packaged APK into
//    `build/app/outputs/flutter-apk/` and renames the copy from a string it
//    builds itself -- `app<-abi><-flavor>-<mode>.apk` -- ignoring the variant's
//    `outputFileName` entirely. So the obvious Gradle rename changes the name in
//    `build/app/outputs/apk/release/` and has no effect on the file anyone opens
//    (`packages/flutter_tools/gradle/src/main/kotlin/FlutterPlugin.kt`, the
//    `rename { "$filename.apk" }` inside the `assembleTask.doLast` copy);
//  * and after Gradle exits, the flutter tool *requires* `app-release.apk` to be
//    sitting in that directory: `listApkPaths` composes the same name from the
//    build mode and `_exitWithExpectedFileNotFound` aborts the build with
//    "Gradle build failed to produce an .apk file" when it is absent
//    (`packages/flutter_tools/lib/src/android/gradle.dart`). Moving or deleting
//    `app-release.apk` therefore fails the build even though the APK exists.
//
// So `app-release.apk` stays, because the toolchain insists on it, and it is a
// byte-for-byte copy of the same build rather than a different one -- installing
// either gives the same app. The named file is the one to reach for.
//
// WHAT THIS TASK TAKES AS ITS INPUT, AND WHY IT MATTERS. Not a filename in the
// output directory. The first version of this looked for a file called
// `app-release.apk` and copied whatever was there, and that was wrong twice over
// (both reproduced with real builds, 2026-09-10):
//
//  * `flutter build apk --release --split-per-abi` -- which `README.md`
//    documents -- produces `app-armeabi-v7a-release.apk`,
//    `app-arm64-v8a-release.apk` and `app-x86_64-release.apk` and NO
//    `app-release.apk`, so the probe failed and took three correctly built APKs
//    down with it;
//  * and when a universal `app-release.apk` happened to be left over from an
//    earlier build, the probe found *that* and copied it out as
//    `LocalCanvas-<version>.apk` -- fresh timestamp, stale bytes, possibly a
//    different version entirely. A versioned name that lies is worse than no
//    versioned name at all, because the whole point of this is that the name in
//    a file manager can be trusted.
//
// So the task consumes `SingleArtifact.APK`, the packaging task's own declared
// output, and reads `BuiltArtifactsLoader` -- the `output-metadata.json` that
// AGP writes for the build that just ran. Every name comes from that record:
// the version from the artifact's own `versionName` (so `--build-name` is
// followed rather than second-guessed) and the ABI from its own filter. There is
// no filename to guess and nothing to be stale.
//
// `dependsOn`, not `finalizedBy`. Gradle runs finalizers even when the finalized
// task FAILS, which is the other way a stale artifact gets a fresh name on it: a
// build that dies before packaging would still have had its finalizer copy
// whatever was lying around. As a dependency, this cannot run unless packaging
// really produced something.
abstract class NameSideloadApks : DefaultTask() {

    /** The packaging task's own output directory, artifact and metadata alike. */
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val apkDirectory: DirectoryProperty

    @get:Internal
    abstract val builtArtifactsLoader: Property<com.android.build.api.variant.BuiltArtifactsLoader>

    /**
     * Where the named copies go: `build/app/outputs/flutter-apk`.
     *
     * Deliberately `@Internal` and not `@OutputDirectory`. That directory is not
     * this task's to own -- the Flutter Gradle plugin writes `app-release.apk`
     * into it, and the flutter tool aborts the build if that file is missing.
     * Declaring it as an output would invite Gradle's stale-output cleanup to
     * delete a file this task never wrote and the build cannot do without. The
     * cost is that the task is never up to date, which for a copy of something
     * that was just built is the correct answer anyway.
     */
    @get:Internal
    abstract val sideloadDirectory: DirectoryProperty

    @TaskAction
    fun nameThem() {
        val built =
            builtArtifactsLoader.get().load(apkDirectory.get())
                ?: throw GradleException(
                    "could not read the APKs the packaging task produced from " +
                        "${apkDirectory.get().asFile}"
                )
        if (built.elements.isEmpty()) {
            throw GradleException(
                "the packaging task reported no APKs in ${apkDirectory.get().asFile}"
            )
        }

        val destination = sideloadDirectory.get().asFile
        // This task deletes files (below), so it says out loud where it believes
        // it is before it does.
        if (destination.name != FLUTTER_APK_DIRECTORY) {
            throw GradleException(
                "refusing to work in $destination: expected a directory called " +
                    FLUTTER_APK_DIRECTORY
            )
        }
        destination.mkdirs()

        val wanted = LinkedHashMap<String, File>()
        for (element in built.elements) {
            val version =
                element.versionName
                    ?: throw GradleException(
                        "the built artifact ${element.outputFile} carries no versionName, " +
                            "so it cannot be named for its version"
                    )
            val abi =
                element.filters
                    .firstOrNull {
                        it.filterType ==
                            com.android.build.api.variant.FilterConfiguration.FilterType.ABI
                    }
                    ?.identifier
            val name =
                if (abi == null) "$PREFIX$version.apk" else "$PREFIX$version-$abi.apk"
            wanted[name] = File(element.outputFile)
        }

        // A named copy of an *older* build sitting beside the current one looks
        // exactly as current as the current one. Only this build's names survive.
        destination.listFiles()?.forEach { file ->
            if (
                file.isFile &&
                    file.name.startsWith(PREFIX) &&
                    file.name.endsWith(".apk") &&
                    !wanted.containsKey(file.name)
            ) {
                if (file.delete()) {
                    logger.lifecycle("Removed a name from an older build: ${file.name}")
                }
            }
        }

        for ((name, source) in wanted) {
            if (!source.isFile) {
                throw GradleException(
                    "the build metadata names $source, and it is not there"
                )
            }
            val copy = File(destination, name)
            source.copyTo(copy, overwrite = true)
            logger.lifecycle("Sideload this one: ${copy.path}")
        }
    }

    companion object {
        const val PREFIX = "LocalCanvas-"
        const val FLUTTER_APK_DIRECTORY = "flutter-apk"
    }
}

androidComponents {
    // Release only. `flutter-apk` holds every build type at once, so naming a
    // debug build `LocalCanvas-<version>.apk` too would have the two overwrite
    // each other under one name -- the confusion this whole thing removes.
    onVariants(selector().withBuildType("release")) { variant ->
        val capitalised = variant.name.replaceFirstChar { it.uppercase() }
        val naming =
            tasks.register<NameSideloadApks>("name${capitalised}SideloadApks") {
                description =
                    "Copies each APK this build produced to LocalCanvas-<version>[-<abi>].apk."
                group = "build"
                // Setting this from the artifact provider is also what makes the
                // task depend on packaging: no explicit dependsOn to drift.
                apkDirectory.set(variant.artifacts.get(SingleArtifact.APK))
                builtArtifactsLoader.set(variant.artifacts.getBuiltArtifactsLoader())
                sideloadDirectory.set(layout.buildDirectory.dir("outputs/flutter-apk"))
            }
        tasks.matching { it.name == "assemble$capitalised" }.configureEach {
            dependsOn(naming)
        }
    }
}

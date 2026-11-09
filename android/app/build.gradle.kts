plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.litwei.dart_control_panel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.litwei.dart_control_panel"
        ndk { abiFilters += listOf("arm64-v8a") }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        // media_kit's prebuilt JARs contain lib/<abi> resources; ABI filters
        // alone do not remove those resource entries from an arm64 APK.
        resources.excludes += setOf("lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**")
        jniLibs.excludes += setOf("lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**")
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
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

// Narrow content:// grants for one generated ZIP, no broad storage permission.
dependencies {
    implementation("androidx.core:core:1.13.1")
    testImplementation("junit:junit:4.13.2")
}

// Build the vendored board detector with the same NDK used by Flutter, without
// relying on the sibling source tree or a machine-specific CMake installation.
val greenSource = file("src/main/cpp")
val greenOutput = layout.buildDirectory.dir("generated/green-jni")
val buildGreenDetector by tasks.registering(Exec::class) {
    inputs.dir(greenSource)
    inputs.property("linkMode", "static-libcxx-v1")
    outputs.file(greenOutput.map { it.file("arm64-v8a/libdart_green_detector.so") })
    doFirst {
        val host = when {
            System.getProperty("os.name").lowercase().contains("linux") -> "linux-x86_64"
            System.getProperty("os.name").lowercase().contains("mac") -> "darwin-x86_64"
            else -> "windows-x86_64"
        }
        val suffix = if (host.startsWith("windows")) ".cmd" else ""
        val compiler = File(android.ndkDirectory, "toolchains/llvm/prebuilt/$host/bin/aarch64-linux-android24-clang++$suffix")
        val output = greenOutput.get().file("arm64-v8a/libdart_green_detector.so").asFile
        output.parentFile.mkdirs()
        commandLine(compiler.absolutePath, "-std=c++17", "-O2", "-fPIC", "-shared", "-static-libstdc++",
            "-I${File(greenSource, "vendor").absolutePath}",
            File(greenSource, "green_jni.cpp").absolutePath,
            File(greenSource, "vendor/src/detector.cpp").absolutePath,
            File(greenSource, "vendor/src/green_detector.cpp").absolutePath,
            File(greenSource, "vendor/src/luma_ellipse.cpp").absolutePath,
            "-o", output.absolutePath)
    }
}
android.sourceSets.getByName("main").jniLibs.srcDir(greenOutput.get().asFile)
tasks.named("preBuild").configure { dependsOn(buildGreenDetector) }

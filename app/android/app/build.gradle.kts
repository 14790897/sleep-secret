// 必须显式 import：Kotlin DSL 里 `java` 这个名字被 Android 插件注册的扩展遮蔽了，
// 写成 java.util.Properties 会解析到那个扩展而不是包，报 Unresolved reference。
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------- 签名
//
// 用固定的 release keystore，**不是 debug 签名**。
//
// debug keystore 是每台机器各自生成的（每个 CI runner 也是），所以 CI 打的包
// 和本地打的包签名不同，甚至不同次 CI 之间也可能不同。签名不同就没法覆盖安装，
// 只能卸载重装——而那会清掉用户所有的睡眠历史记录。
//
// 凭据来源：
//   - 本地：android/key.properties（已 gitignore）
//   - CI：workflow 从 GitHub Secrets 还原出同一个文件
// 文件不存在时退回 debug 签名，这样 clone 下来直接 flutter run 就能跑。
//
// ⚠️ app/android/sleep-secret-release.jks 和 key.properties 是**这个应用的身份**，
// 弄丢就再也无法给已安装的用户推送更新。备份见仓库根目录 README 的说明。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.sleepsecret.sleep_secret"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sleepsecret.sleep_secret"
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

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                // storeFile 相对于 android/ 目录
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // R8 会混淆类名，而 ONNX Runtime 的 JNI 是按类名字符串找类的——
            // 不保留就会在第一次推理时整个进程 SIGABRT。
            // 规则和踩坑记录见 proguard-rules.pro。
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

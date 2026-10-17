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

    // AGP 会往 APK 的签名块里塞一个 'Dependency metadata' 块——压缩后用 Google Play
    // 的密钥加密。F-Droid 无法检查里面的内容，所以禁止额外的签名块，于是
    // `fdroid build` 能过、但复查产物的 `check apk` 会判失败（实测三个 APK 全中：
    // "found extra signing block 'Dependency metadata'"）。
    // 这个块只对 Google Play 的「应用大小归因」有用，我们不上架 Play，关掉没有任何代价。
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    // 默认（minSdk >= 23）native 库以**不压缩**的方式存进 APK（为了安装时能直接
    // mmap，不用解压），代价是 APK 里有 38MB 是原样存放的 .so——onnxruntime 一个
    // 就占 20MB。F-Droid 评审建议改成 legacy 打包：.so 参与 deflate 压缩，
    // 安装时再解出来。下载体积小约 40%，代价是安装后多占一份解压后的空间。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
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

// ------------------------------------------------------- versionCode 的 ABI 位
//
// Flutter 的 --split-per-abi 默认给每个 ABI 加 1000/2000/4000
// （FlutterPlugin.kt 的 ABI_VERSION），也就是把 ABI 摆在**千位**上。
// 而 pubspec 的 versionCode 一次 minor 才涨 100、patch 才涨 1 ——
// ABI 的跨度（3000）远大于版本的涨幅，于是**旧版本的高 ABI 会排在新版本的低 ABI 前面**：
//
//     2.18.1 的 x86_64 = 25801   >   2.19.0 的 armeabi-v7a = 22900
//
// F-Droid 只保留版本号最高的那几个 APK，其余进 archive；客户端也总是更新到
// 能装的那个里版本号最高的。两者都会被这个倒挂搞错。所以把 ABI 挪到**个位**：
// `versionCode * 10 + abiCode`，版本号永远压过 ABI 之间的差异。
//
// 这是 F-Droid 评审明确要求的（Quick Start Guide 的 "Setup ABI split" 一节），
// 元数据里的 VercodeOperation 必须跟着写成 '%c * 10 + 1/2/3'，
// 两处是同一个算法的两种表达，改一处必须改另一处。
//
// 用已废弃的 ApkVariantOutput 而不是评审给的 internal 版本 ——
// Flutter 自己的插件用的就是这个类型，跟当前 AGP 的兼容性有保证。
val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abi = output.filters.find { it.filterType == "ABI" }?.identifier
        val abiCode = abiCodes[abi]
        if (abiCode != null) {
            @Suppress("DEPRECATION")
            (output as com.android.build.gradle.api.ApkVariantOutput).versionCodeOverride =
                variant.versionCode * 10 + abiCode
        }
    }
}

// ------------------------------------------------------- 抹掉 ELF 的 build ID
//
// F-Droid 的可复现构建要求：同一份源码，在任何路径、任何工具链路径下构建，
// 产物要**逐字节相同**。实测（把 F-Droid 构建的 APK 和本仓库发布的 APK 逐字节比）
// 我们和他们的 libdartjni.so 大小相同、内容**只有 20 字节不同**——正好是链接器
// 写进 .note.gnu.build-id 的那个 ID。它是链接输入的哈希，会随构建路径变化；
// 而 .so 打进 APK 时已经被 strip，所以除了这个 ID 之外看不出任何差异。
//
// 试过用 CFLAGS/LDFLAGS 传 `-Wl,--build-id=none`、`-ffile-prefix-map`、
// `-fdebug-compilation-dir`，都压不过 NDK 驱动自己的默认 `--build-id=sha1`
// （用户参数在它前面）。所以改成**打包之前把它清零**：两边都是零，结果就一致了。
//
// 代价：build ID 不再能用于崩溃符号化。它本来在 F-Droid 和上游之间就对不上，
// 所以这一点没有变差。
tasks.matching { it.name.startsWith("package") }
    .configureEach {
        doFirst {
            // ⚠️ 不要猜路径，也不要信 outputs.files：
            //   · outputs.files 里没有这个目录（取到空集合，task 静默什么都不做）
            //   · Flutter 的 AGP 构建目录是 <app>/build/app/...，不是 <app>/build/...
            // 直接在构建目录里按名字找。
            val buildDir = layout.buildDirectory.get().asFile
            // 打包读的是 stripped_native_libs，merged 只是它的输入。两个都清一遍，
            // 免得将来 AGP 换了来源。
            val dirs = buildDir.walkTopDown()
                .filter {
                    it.isDirectory &&
                        (it.name == "merged_native_libs" || it.name == "stripped_native_libs")
                }
                .toList()
            var patchedFiles = 0
            dirs.forEach { root ->
                root.walkTopDown()
                    .filter { it.isFile && it.name.endsWith(".so") }
                    .forEach { so ->
                        val bytes = so.readBytes()
                        // GNU note 头（按字节序）：namesz=4、descsz=0x14(20)、
                        // type=3(NT_GNU_BUILD_ID)、名字 "GNU\0"。描述符紧随其后。
                        val marker = byteArrayOf(
                            4, 0, 0, 0,
                            0x14, 0, 0, 0,
                            3, 0, 0, 0,
                            'G'.code.toByte(), 'N'.code.toByte(),
                            'U'.code.toByte(), 0,
                        )
                        var patched = false
                        var i = 0
                        while (i <= bytes.size - marker.size) {
                            if (marker.indices.all { bytes[i + it] == marker[it] }) {
                                // 描述符紧跟在 16 字节的 note 头之后
                                val p = i + marker.size
                                if (p + 20 <= bytes.size) {
                                    for (k in 0 until 20) bytes[p + k] = 0
                                    patched = true
                                }
                            }
                            i++
                        }
                        if (patched) {
                            so.writeBytes(bytes)
                            patchedFiles++
                        }
                    }
            }
            println("build-id: cleared in $patchedFiles .so file(s) before $name")
        }
    }

flutter {
    source = "../.."
}

import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名配置：优先级 CI 环境变量（GitHub secrets 解出的 keystore）> 本地 key.properties
// （开发者本地 release 构建，仓库外维护）> 都缺则回退 debug 签名（本地开发）。
//
// 为什么必须有稳定 release 签名：此前 release 用 debug keystore 签名，而 CI runner 每次
// 都是全新临时环境 → 每次发布的 APK 签名都不同 → 覆盖安装必然报「签名冲突」。
// 改成 CI 用 secrets 里的固定 keystore 后，每次发布签名一致，更新不再冲突。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "dev.zizai.zi_zai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            val envStorePath = System.getenv("ZIZAI_KEYSTORE_PATH")
            if (!envStorePath.isNullOrEmpty()) {
                // CI：GitHub secrets 解出的稳定 keystore。
                storeFile = file(envStorePath)
                storePassword = System.getenv("ZIZAI_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ZIZAI_KEY_ALIAS")
                keyPassword = System.getenv("ZIZAI_KEY_PASSWORD")
            } else if (keystorePropertiesFile.exists()) {
                // 本地：android/key.properties（storeFile 相对 android/ 目录）。
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = "dev.zizai.zi_zai"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 有稳定 release 签名则用它，否则回退 debug（本地开发 `flutter run --release`）。
            val releaseSigning = signingConfigs.getByName("release")
            signingConfig = if (releaseSigning.storeFile != null) {
                releaseSigning
            } else {
                signingConfigs.getByName("debug")
            }
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

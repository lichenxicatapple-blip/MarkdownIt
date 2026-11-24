import groovy.json.JsonSlurper
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application") version "8.12.0"
    id("org.jetbrains.kotlin.android") version "2.1.20"
}

val repository = rootProject.layout.projectDirectory.dir("..")
val design = JsonSlurper().parseText(providers.fileContents(repository.file("design/tokens.json")).asText.get()) as Map<*, *>
val tokens = design["tokens"] as Map<*, *>
fun tokenValue(name: String) = (tokens[name] as Map<*, *>)["value"] as String
val homeSloganSize = tokenValue("size.homeSlogan").removeSuffix("px")
val homeMarkSize = tokenValue("size.homeMark").removeSuffix("px")
val agentSheetRatio = tokenValue("ratio.agentSheetHeight").toDouble()

android {
    namespace = "dev.catli.markdownit"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.catli.markdownit"
        minSdk = 30
        targetSdk = 36
        versionCode = 2
        versionName = "1.1.0"
        resValue("dimen", "home_slogan_size", "${homeSloganSize}sp")
        resValue("dimen", "home_mark_size", "${homeMarkSize}dp")
        resValue("fraction", "ai_sheet_height", "${agentSheetRatio * 100}%")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin.compilerOptions.jvmTarget.set(JvmTarget.JVM_17)

dependencies {
    implementation("androidx.activity:activity-ktx:1.8.2")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.3")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("com.google.android.material:material:1.13.0")
}

val readerAssets = layout.buildDirectory.dir("shared/reader")
val brandResources = layout.buildDirectory.dir("shared/brand")

val packageReader by tasks.registering(Sync::class) {
    inputs.file(layout.projectDirectory.file("build.gradle.kts"))
    into(readerAssets)
    from(repository.dir("MarkdownIt/Resources/Web")) {
        into("web")
        exclude("image-preview.html")
        filesMatching("index.html") {
            filter { line ->
                line.replace("connect-src 'none'", "connect-src 'self'")
                    .replace("<script src=\"localization.js\">", "<script src=\"/reader-locales.js\"></script><script src=\"localization.js\">")
                    .replace("<script src=\"reader.js\">", "<script src=\"../android-reader.js\"></script><script src=\"reader.js\">")
            }
        }
        filesMatching("conversation.html") {
            filter { line ->
                line.replace("<script src=\"localization.js\">", "<script src=\"/reader-locales.js\"></script><script src=\"localization.js\">")
                    .replace("<script src=\"conversation.js\">", "<script src=\"../android-conversation.js\"></script><script src=\"conversation.js\">")
            }
        }
        filesMatching("conversation.js") {
            filter { line -> line.replace(
                "jm-resource://\${nativeToken}/image?path=",
                "/resource/\${nativeToken}?path=",
            ) }
        }
    }
}

val packageBrand by tasks.registering(Sync::class) {
    into(brandResources)
    from(repository.dir("design/brand/production")) {
        include("mark.png", "home-mark.png")
        into("drawable-nodpi")
        rename { if (it == "mark.png") "brand_mark.png" else "brand_home.png" }
    }
    from(repository.file("vendor/Newsreader16pt-Regular.ttf")) {
        into("font")
        rename("Newsreader16pt-Regular.ttf", "newsreader_regular.ttf")
    }
    from(repository.file("vendor/Newsreader.LICENSE")) {
        into("raw")
        rename("Newsreader.LICENSE", "newsreader_license.txt")
    }
}

android.sourceSets.getByName("main") {
    assets.srcDir(readerAssets)
    res.srcDir(brandResources)
}

tasks.named("preBuild") {
    dependsOn(packageReader, packageBrand)
}

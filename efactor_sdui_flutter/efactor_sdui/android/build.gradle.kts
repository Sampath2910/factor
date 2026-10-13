import org.gradle.api.plugins.JavaPluginExtension
import org.gradle.jvm.toolchain.JavaLanguageVersion

allprojects {
    repositories {
        google()
        mavenCentral()

        maven {
            url = uri("https://jitpack.io")
        }
        maven {
            url = uri("${rootProject.projectDir}/../packages/efactor_provisioning/android/repo")
        }
    }
}

// Prefer the running JDK (Android Studio JBR 21) when plugins request an
// older toolchain. Applied afterEvaluate so it wins over plugin defaults.
subprojects {
    afterEvaluate {
        extensions.findByType(JavaPluginExtension::class.java)?.toolchain
            ?.languageVersion
            ?.set(JavaLanguageVersion.of(21))
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.ext.set(
        "flutter",
        mapOf(
            "compileSdkVersion" to 36,
            "minSdkVersion" to 23,
            "targetSdkVersion" to 35,
            "ndkVersion" to "28.2.13676358"
        )
    )
}

subprojects {
    plugins.withType(com.android.build.gradle.LibraryPlugin::class.java) {
        val androidExt = extensions.getByType(com.android.build.gradle.LibraryExtension::class.java)
        androidExt.compileSdk = 36
    }
}

subprojects {
    project.evaluationDependsOn(":app")

    tasks.matching { it.name.contains("LibJars") || it.name.contains("Annotations") }.configureEach {
        doFirst {
            val typedefFile = file("${project.layout.buildDirectory.get()}/intermediates/annotations_typedef_file/release/extractReleaseAnnotations/typedefs.txt")
            if (!typedefFile.exists()) {
                typedefFile.parentFile.mkdirs()
                typedefFile.createNewFile()
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

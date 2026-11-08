pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        maven("https://repo1.maven.org/maven2")
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenLocal()
        google()
        maven("https://repo1.maven.org/maven2")
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

rootProject.name = "Dimina Android"
include(":app")
include(":engine_qjs")
include(":dimina")

// Optional vendor adapter: applications include :map-amap only when they choose AMap.
include(":map-amap")

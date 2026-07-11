// Gradle settings for the self-contained Android build of AsyncImageCache.
//
// This build is consumed by ActionUIAndroid as a composite build:
//   includeBuild("../AsyncImageCache/android")
// which substitutes the `com.abracode:asyncimagecache` module in place of any binary dependency. Keeping the
// build self-contained (its own settings + wrapper) means it also builds and tests standalone.

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "AsyncImageCache"
include(":asyncimagecache")
include(":demo")

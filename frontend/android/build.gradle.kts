allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// `file_picker` 8.x declares API 34 in its own Android library project.
// Flutter's current lifecycle plugin requires API 36, so keep every Android
// library compiled against the same API as the host app. This does not change
// the app's targetSdk or minimum supported Android version.
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

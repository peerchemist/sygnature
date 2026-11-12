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

val cargoKitTargetPlatforms = listOf("android-arm64", "android-x64")

gradle.projectsEvaluated {
    rootProject.subprojects.forEach { subproject ->
        subproject.tasks
            .matching { it.name.startsWith("cargokitCargoBuild") }
            .configureEach {
                // CargoKit ignores the app's ABI filters and adds 32-bit x86 to debug builds.
                javaClass
                    .getMethod("setTargetPlatforms", List::class.java)
                    .invoke(this, cargoKitTargetPlatforms)
            }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

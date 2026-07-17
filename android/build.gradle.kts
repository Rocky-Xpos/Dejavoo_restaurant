// Credentials for the Dejavoo (denovo) S3 maven repo hosting the
// invoke-dvpay-lite SDK. Read from android/denovo.properties
// (denovo.aws.accessKey / denovo.aws.secretKey), falling back to the
// DENOVO_AWS_ACCESS_KEY / DENOVO_AWS_SECRET_KEY environment variables.
// When neither source provides both keys the repo is skipped entirely, so a
// plain Flutter build without SDK credentials still CONFIGURES — Gradle then
// only fails if the com.denovo dependency actually has to be resolved.
val denovoProperties = java.util.Properties().apply {
    val f = rootProject.file("denovo.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val denovoAccessKey: String? =
    denovoProperties.getProperty("denovo.aws.accessKey")
        ?: System.getenv("DENOVO_AWS_ACCESS_KEY")
val denovoSecretKey: String? =
    denovoProperties.getProperty("denovo.aws.secretKey")
        ?: System.getenv("DENOVO_AWS_SECRET_KEY")

allprojects {
    repositories {
        google()
        mavenCentral()
        val dvpayAccess = denovoAccessKey
        val dvpaySecret = denovoSecretKey
        if (!dvpayAccess.isNullOrBlank() && !dvpaySecret.isNullOrBlank()) {
            maven {
                url = uri("s3://denovo-android.s3.amazonaws.com")
                credentials(AwsCredentials::class) {
                    accessKey = dvpayAccess
                    secretKey = dvpaySecret
                }
            }
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// The scoring engine: a line-by-line port of the Swift package BiteCore (Sources/BiteCore).
// Pure Kotlin on the JVM, no Android, so its tests run without an emulator.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(libs.serialization.json)
    testImplementation(libs.junit)
}

tasks.test {
    testLogging { events("failed"); showStandardStreams = true }
}

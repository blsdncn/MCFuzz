plugins {
    java
    id("com.gradleup.shadow") version "8.3.6"
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.ow2.asm:asm:9.7.1")
    implementation("org.ow2.asm:asm-commons:9.7.1")
    implementation("org.ow2.asm:asm-tree:9.7.1")
    implementation("org.ow2.asm:asm-analysis:9.7.1")
    implementation("org.ow2.asm:asm-util:9.7.1")

    // JaCoCo core for the internal CFG analysis classes we vendor
    implementation("org.jacoco:org.jacoco.core:0.8.12")

    // ByteBuddy for agent installer (used by Jazzer's AgentInstaller pattern)
    implementation("net.bytebuddy:byte-buddy-agent:1.15.11")

    // JNA for potential future SHM access without JNI
    implementation("net.java.dev.jna:jna:5.16.0")

    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
}

// Build a fat JAR that can be used as -javaagent
tasks.shadowJar {
    archiveClassifier.set("")
    manifest {
        attributes(
            mapOf(
                "Premain-Class" to "agent.AflMcAgent",
                "Can-Redefine-Classes" to "true",
                "Can-Retransform-Classes" to "true",
                "Can-Set-Native-Method-Prefix" to "true"
            )
        )
    }
}

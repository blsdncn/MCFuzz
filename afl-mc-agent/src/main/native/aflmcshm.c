/*
 * Copyright 2024 AFL-MC-Agent Contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * JNI bridge: Java_afl_NativeShm_attach
 * Attaches to a SysV shared memory segment via shmat().
 */

#include <stdlib.h>
#include <string.h>
#include <sys/shm.h>
#include <jni.h>

JNIEXPORT jlong JNICALL
Java_afl_NativeShm_attach(JNIEnv *env, jclass cls, jint shm_id)
{
    (void)env;
    (void)cls;

    void *addr = shmat((int)shm_id, NULL, 0);
    if (addr == (void *)-1) {
        return 0;
    }
    return (jlong)addr;
}

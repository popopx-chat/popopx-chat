/*
 * cactus_jni.c — the JNI seam between chat.popopx.common.copilot.NeedleCactusEngine and the
 * published Cactus runtime.
 *
 * Kept deliberately thin: it copies a verified byte buffer into cactus_load, sets the system prompt
 * and the tool schema, runs one completion into a caller-owned buffer, and surfaces the runtime's own
 * last error as a Java string. It allocates nothing that outlives a call and keeps no state of its
 * own, because cactus keeps one global context and the Kotlin wrapper serialises every call against
 * it.
 *
 * The Kotlin package is chat.popopx.common.copilot rather than a chat.popopx.android package: the
 * expect declarations this Android code satisfies live in :common's commonMain, and Kotlin matches
 * actual to expect by qualified name inside the same module, so the actuals — and the native methods
 * they declare — have to be in that package.
 *
 * Build: see CMakeLists.txt in this directory, or the one-line clang invocation recorded there.
 * Links against ../cactus/android-arm64/libcactus.a (measured
 * 67dbd7b856a3e9d8b0fbb68f0c59592e7572cf859238ba7f3074f74b6fa9a5da, 2,898,160 bytes), which exports
 * exactly the five symbols used here.
 */

#include <jni.h>
#include <stddef.h>
#include <string.h>

#include "cactus.h"

/* One completion of a tool call is a few hundred bytes of JSON; 16 KiB is generous and bounded, and
 * the buffer is stack-allocated so a failure path cannot leak it. */
#define CACTUS_OUT_CAPACITY 16384

/* Returned by the c_* entry points: 1 success, 0 failure. cactus itself returns 0 on success for
 * load/init, which is inverted here so the Kotlin side reads the same way for every call. */

static char g_out[CACTUS_OUT_CAPACITY];

JNIEXPORT jboolean JNICALL
Java_chat_popopx_common_copilot_PopopxCactusJni_nativeAvailable(JNIEnv *env, jobject self) {
  (void) env;
  (void) self;
  /* Linked directly against the archive, so reaching this function at all proves the runtime is in
   * the process. Kept as a native call rather than a Kotlin constant so a build that drops the shim
   * reports unavailable instead of crashing on a missing symbol. */
  return JNI_TRUE;
}

JNIEXPORT jint JNICALL
Java_chat_popopx_common_copilot_PopopxCactusJni_nativeLoad(JNIEnv *env, jobject self, jbyteArray model, jlong length) {
  (void) self;
  if (model == NULL || length <= 0) return 0;
  /* GetStringByteArrayElements may return a copy; CACTUS_MODE does not keep the pointer, so either
   * way the buffer is released without committing changes back. */
  jbyte *bytes = (*env)->GetByteArrayElements(env, model, NULL);
  if (bytes == NULL) return 0;
  int rc = cactus_load((const unsigned char *) bytes, (unsigned long long) length);
  (*env)->ReleaseByteArrayElements(env, model, bytes, JNI_ABORT);
  return rc == 0 ? 1 : 0;
}

JNIEXPORT jint JNICALL
Java_chat_popopx_common_copilot_PopopxCactusJni_nativeInit(JNIEnv *env, jobject self, jstring systemPrompt, jstring toolsJson) {
  (void) self;
  const char *prompt = systemPrompt == NULL ? NULL : (*env)->GetStringUTFChars(env, systemPrompt, NULL);
  const char *tools = toolsJson == NULL ? NULL : (*env)->GetStringUTFChars(env, toolsJson, NULL);
  if ((*env)->ExceptionCheck(env) || prompt == NULL || tools == NULL) {
    if (prompt != NULL) (*env)->ReleaseStringUTFChars(env, systemPrompt, prompt);
    if (tools != NULL) (*env)->ReleaseStringUTFChars(env, toolsJson, tools);
    return 0;
  }
  /* No tool index: the five tools are the whole schema and the runtime builds its matcher from the
   * JSON each init, which is what lets the prompt carry today's date without reloading weights. */
  int rc = cactus_init(prompt, tools, NULL);
  (*env)->ReleaseStringUTFChars(env, systemPrompt, prompt);
  (*env)->ReleaseStringUTFChars(env, toolsJson, tools);
  return rc == 0 ? 1 : 0;
}

JNIEXPORT jstring JNICALL
Java_chat_popopx_common_copilot_PopopxCactusJni_nativeComplete(JNIEnv *env, jobject self, jstring text, jint maxNewTokens) {
  (void) self;
  if (text == NULL || maxNewTokens <= 0) return NULL;
  const char *input = (*env)->GetStringUTFChars(env, text, NULL);
  if ((*env)->ExceptionCheck(env) || input == NULL) return NULL;
  g_out[0] = '\0';
  /* No audio: samples is 0 and pcm is NULL, which is the documented text-only call. */
  int rc = cactus_complete(input, NULL, 0, (int) maxNewTokens, g_out, (int) sizeof(g_out));
  (*env)->ReleaseStringUTFChars(env, text, input);
  if (rc != 0 || g_out[0] == '\0') return NULL;
  return (*env)->NewStringUTF(env, g_out);
}

JNIEXPORT void JNICALL
Java_chat_popopx_common_copilot_PopopxCactusJni_nativeReset(JNIEnv *env, jobject self) {
  (void) env;
  (void) self;
  cactus_reset();
}

JNIEXPORT jstring JNICALL
Java_chat_popopx_common_copilot_PopopxCactusJni_nativeLastError(JNIEnv *env, jobject self) {
  (void) self;
  const char *error = cactus_last_error();
  if (error == NULL || error[0] == '\0') return NULL;
  return (*env)->NewStringUTF(env, error);
}

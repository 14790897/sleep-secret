# ONNX Runtime 的 Java 类必须原样保留。
#
# ORT 的 JNI 代码按**类名字符串**去 FindClass（比如 "ai/onnxruntime/OnnxValue"），
# R8 一旦把类名混淆成 g/e/a 这种短名，JNI 就找不到，返回 java_class == null，
# 然后整个进程直接 SIGABRT。
#
# 症状很有迷惑性：debug 构建（不混淆）一切正常，集成测试全过，
# 只有 release 版会在**第一次真正跑推理时**崩溃——而如果没有任何声音进来，
# 推理被能量门控全部跳过，就永远看不到这个崩溃。
#
# 实测崩溃栈：
#   JNI DETECTED ERROR IN APPLICATION: java_class == null
#     in call to GetMethodID
#     from boolean[] ai.onnxruntime.OrtSession.run(...)
#   at ai.onnxruntime.OrtSession.g(r8-map-id-...)
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# flutter_onnxruntime 通过反射/JNI 访问的类同样要保留
-keep class com.masicai.flutteronnxruntime.** { *; }

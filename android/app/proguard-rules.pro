# Kotlinx Serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class de.kerlhandel.vmflow.**$$serializer { *; }
-keepclassmembers class de.kerlhandel.vmflow.** {
    *** Companion;
}
-keepclasseswithmembers class de.kerlhandel.vmflow.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Data models
-keep class de.kerlhandel.vmflow.data.model.** { *; }

# Ktor
-keep class io.ktor.** { *; }
-dontwarn io.ktor.**

# Supabase
-keep class io.github.jan.supabase.** { *; }
-dontwarn io.github.jan.supabase.**

# Firebase / FCM
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**

# Hilt
-keepclasseswithmembers class * {
    @dagger.hilt.** *;
}
-keepclassmembers class ** {
    @dagger.hilt.** *;
}

# ML Kit
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# CameraX
-keep class androidx.camera.** { *; }

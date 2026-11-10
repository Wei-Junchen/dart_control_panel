#include <jni.h>
#include <memory>
#include <stdexcept>
#include "vision/green_detector.hpp"
#include "vision/luma_ellipse_detector.hpp"
#include "vision/green_luma_threshold.hpp"

static void fail(JNIEnv *env, const char *message) {
    env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), message);
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_litwei_dart_1control_1panel_NativeGreenDetector_mask(JNIEnv *env, jobject, jlong ptr, jbyteArray frame, jint w, jint h, jint step) {
    if (!ptr || !frame || w<2 || h<2 || w>4096 || h>4096 || (w&1) || (h&1) || step<1 || step>4096 ||
        static_cast<jlong>(env->GetArrayLength(frame)) != static_cast<jlong>(w)*h*3/2) {
        fail(env, "NV21 掩码尺寸无效"); return nullptr;
    }
    const int pw = (w + step - 1) / step, ph = (h + step - 1) / step;
    std::vector<jbyte> result;
    try { result.resize(static_cast<size_t>(pw) * ph); }
    catch (const std::exception &e) { fail(env, e.what()); return nullptr; }
    auto *bytes = env->GetByteArrayElements(frame, nullptr); if (!bytes) return nullptr;
    auto *detector = reinterpret_cast<vision::Detector *>(ptr);
    const auto *y = reinterpret_cast<const uint8_t *>(bytes);
    const auto *vu = y + w * h;
    const auto roi = detector->acquisition_roi(w, h);
    for (int py=0; py<ph; py++) for (int px=0; px<pw; px++) {
        const int x=px*step, yy=py*step, uv=(yy/2)*w+(x&~1);
        if (x>=roi.x && x<roi.x+roi.w && yy>=roi.y && yy<roi.y+roi.h &&
            y[yy*w+x] >= (detector->config().mode == "luma_ellipse" ? detector->config().luma_threshold : vision::required_green_luma(detector->config(), vu[uv+1], vu[uv])))
            result[static_cast<size_t>(py)*pw+px] = static_cast<jbyte>(255);
    }
    env->ReleaseByteArrayElements(frame, bytes, JNI_ABORT);
    auto out=env->NewByteArray(static_cast<jsize>(result.size()));
    if (out) env->SetByteArrayRegion(out, 0, static_cast<jsize>(result.size()), result.data());
    return out;
}
extern "C" JNIEXPORT jlong JNICALL
Java_com_litwei_dart_1control_1panel_NativeGreenDetector_create(JNIEnv *env, jobject, jintArray args, jstring mode, jintArray ints, jdoubleArray floats, jintArray common) {
    if (!common || env->GetArrayLength(common) != 9) { fail(env, "检测器参数无效"); return 0; }
    if (!mode || !ints || env->GetArrayLength(ints) != 2 || !floats || env->GetArrayLength(floats) != 4) { fail(env, "亮度椭圆参数无效"); return 0; }
    if (!args || env->GetArrayLength(args) != 5) { fail(env, "需要五个绿色阈值"); return 0; }
    jint v[5]; env->GetIntArrayRegion(args, 0, 5, v);
    if (v[0]<0 || v[0]>255 || v[1]<0 || v[1]>255 || v[2]<-510 || v[2]>510 || v[3]<-255 || v[3]>255 || v[4]<-255 || v[4]>255) { fail(env, "绿色阈值越界"); return 0; }
    try {
        vision::DetectorConfig c;
        const char *mode_chars = env->GetStringUTFChars(mode, nullptr);
        if (!mode_chars) return 0;
        c.mode = mode_chars;
        env->ReleaseStringUTFChars(mode, mode_chars);
        jint li[2]; jdouble lf[4];
        env->GetIntArrayRegion(ints, 0, 2, li);
        env->GetDoubleArrayRegion(floats, 0, 4, lf);
        c.luma_threshold=li[0]; c.ellipse_min_pixels=li[1];
        c.ellipse_max_axis_ratio=lf[0]; c.ellipse_min_iou=lf[1];
        c.ellipse_green_min_fraction=lf[2]; c.ellipse_color_scale=lf[3];
        if (!vision::valid_detector_strategy(c)) { fail(env, "检测模式或椭圆参数无效"); return 0; }
        jint cv[9]; env->GetIntArrayRegion(common, 0, 9, cv);
        if (cv[0]<1 || cv[1]<1 || cv[2]<1 || cv[3]<1 || cv[3]>8 || cv[4]<1 || cv[4]>8 ||
            cv[5]<0 || cv[6]<0 || cv[7]<0 || cv[8]<0 || cv[5]>4096 || cv[6]>4096 || cv[7]>4096 || cv[8]>4096 ||
            ((cv[7]==0) != (cv[8]==0))) { fail(env, "检测器参数越界"); return 0; }
        c.search_radius=cv[0]; c.area_threshold=cv[1]; c.pixels_threshold=cv[2];
        c.sample_step_x=cv[3]; c.sample_step_y=cv[4];
        c.roi_x=cv[5]; c.roi_y=cv[6]; c.roi_width=cv[7]; c.roi_height=cv[8];
        c.green_y_min=v[0]; c.green_g_min=v[1]; c.green_score_min=v[2]; c.green_rg_min=v[3]; c.green_gb_min=v[4];
        vision::Detector *detector = c.mode == "luma_ellipse"
            ? static_cast<vision::Detector *>(new vision::LumaEllipseDetector(c))
            : static_cast<vision::Detector *>(new vision::GreenDetector(c));
        return reinterpret_cast<jlong>(detector);
    } catch (const std::exception &e) { fail(env, e.what()); return 0; }
}
extern "C" JNIEXPORT jlongArray JNICALL
Java_com_litwei_dart_1control_1panel_NativeGreenDetector_detect(JNIEnv *env, jobject, jlong ptr, jbyteArray frame, jint w, jint h) {
    if (!ptr || !frame || w<2 || h<2 || w>4096 || h>4096 || (w&1) || (h&1) || static_cast<jlong>(env->GetArrayLength(frame)) != static_cast<jlong>(w)*h*3/2) { fail(env, "NV21 帧尺寸无效"); return nullptr; }
    auto *data = env->GetByteArrayElements(frame, nullptr); if (!data) return nullptr;
    try {
        auto *det = reinterpret_cast<vision::Detector *>(ptr);
        const auto *y = reinterpret_cast<uint8_t *>(data);
        auto target = det->detect_nv21(y, y + w*h, w, h, w, w, w*h, w*h/2);
        auto profile = det->last_profile();
        jlong result[] = {target.found ? 1 : 0, target.x, target.y, target.rect_x, target.rect_y, target.rect_w, target.rect_h, target.pixels, target.area, static_cast<jlong>(profile.threshold_us), static_cast<jlong>(profile.blob_us)};
        env->ReleaseByteArrayElements(frame, data, JNI_ABORT);
        auto array=env->NewLongArray(sizeof(result)/sizeof(result[0]));
        if (array) env->SetLongArrayRegion(array, 0, sizeof(result)/sizeof(result[0]), result);
        return array;
    } catch (const std::exception &e) { env->ReleaseByteArrayElements(frame, data, JNI_ABORT); fail(env, e.what()); return nullptr; }
}
extern "C" JNIEXPORT void JNICALL
Java_com_litwei_dart_1control_1panel_NativeGreenDetector_destroy(JNIEnv *, jobject, jlong ptr) {
    delete reinterpret_cast<vision::Detector *>(ptr);
}

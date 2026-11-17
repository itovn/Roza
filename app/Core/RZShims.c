// (chép từ Côn Bằng TV Legacy app/Core/CBShims.c) Hàm iOS 5 / iOS 6 không có mà thư viện chuẩn Rust (rustc chỉ hỗ trợ từ iOS 10) gọi tới. Định nghĩa ngay trong app: ld gắn lời
// gọi của Rust vào đây (tệp đối tượng của app được ưu tiên hơn thư viện hệ thống), nên dyld của iOS cũ không phải tìm.
#include <dirent.h>
#include <errno.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <time.h>

// Mã đồng hồ của <time.h> iOS 10 (SDK 9.3 chưa có)
enum {
    RZ_CLOCK_REALTIME = 0,
    RZ_CLOCK_MONOTONIC_RAW = 4,
    RZ_CLOCK_MONOTONIC_RAW_APPROX = 5,
    RZ_CLOCK_MONOTONIC = 6,
    RZ_CLOCK_UPTIME_RAW = 8,
    RZ_CLOCK_UPTIME_RAW_APPROX = 9,
    RZ_CLOCK_PROCESS_CPUTIME_ID = 12,
    RZ_CLOCK_THREAD_CPUTIME_ID = 16,
};

static uint64_t rz_mach_ns(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    uint64_t t = mach_absolute_time();
    return t / tb.denom * tb.numer + (t % tb.denom) * tb.numer / tb.denom;
}

// std::time::Instant của Rust trên Apple dùng CLOCK_UPTIME_RAW (không tính lúc máy ngủ) = mach_absolute_time;
// SystemTime dùng CLOCK_REALTIME.
int clock_gettime(int clock_id, struct timespec *tp) {
    if (!tp) {
        errno = EINVAL;
        return -1;
    }
    switch (clock_id) {
        case RZ_CLOCK_REALTIME: {
            struct timeval tv;
            if (gettimeofday(&tv, NULL) != 0) return -1;
            tp->tv_sec = tv.tv_sec;
            tp->tv_nsec = (long)tv.tv_usec * 1000;
            return 0;
        }
        case RZ_CLOCK_MONOTONIC_RAW:
        case RZ_CLOCK_MONOTONIC_RAW_APPROX:
        case RZ_CLOCK_MONOTONIC:
        case RZ_CLOCK_UPTIME_RAW:
        case RZ_CLOCK_UPTIME_RAW_APPROX: {
            uint64_t ns = rz_mach_ns();
            tp->tv_sec = (time_t)(ns / 1000000000ull);
            tp->tv_nsec = (long)(ns % 1000000000ull);
            return 0;
        }
        case RZ_CLOCK_PROCESS_CPUTIME_ID:
        case RZ_CLOCK_THREAD_CPUTIME_ID: {
            struct rusage ru;
            if (getrusage(RUSAGE_SELF, &ru) != 0) return -1;
            uint64_t us = (uint64_t)(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000000ull +
                          (uint64_t)(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec);
            tp->tv_sec = (time_t)(us / 1000000ull);
            tp->tv_nsec = (long)(us % 1000000ull) * 1000;
            return 0;
        }
        default:
            errno = EINVAL;
            return -1;
    }
}

// iOS 7+: LLVM đổi pow(10, x) trong mã Rust thành __exp10 (rustc tưởng máy ≥ iOS 10). Tệp này dựng với đích iOS 6 nên
// LLVM không đổi ngược pow ở đây thành __exp10 (không đệ quy).
double __exp10(double x) {
    return pow(10.0, x);
}

float __exp10f(float x) {
    return powf(10.0f, x);
}

// iOS 7+: LLVM gộp sin + cos cùng đối số trong mã Rust thành __sincosf_stret / __sincos_stret (tiny-skia xoay hình khi vẽ
// sticker động TGS) — iOS 5 / 6 không có: dyld dừng app ở lần gọi đầu (16/11/2026, iPhone 5). Tệp này dựng với đích iOS 6 nên
// LLVM không gộp ngược sinf / cosf ở đây.
// (SDK 9.3 không khai báo struct __float2 / __double2 cho armv7 → kiểu riêng cùng bố cục; trả về qua con trỏ như ABI APCS
// LLVM dùng khi gọi.)
typedef struct {
    float sinval, cosval;
} rz_float2;
typedef struct {
    double sinval, cosval;
} rz_double2;

rz_float2 __sincosf_stret(float x) {
    rz_float2 r = {sinf(x), cosf(x)};
    return r;
}

rz_double2 __sincos_stret(double x) {
    rz_double2 r = {sin(x), cos(x)};
    return r;
}

// iOS 11+: std::fs::copy của Rust thử nhân bản tệp (APFS) trước — báo «không hỗ trợ» thì nó tự chép kiểu thường.
int fclonefileat(int srcfd, int dst_dirfd, const char *dst, uint32_t flags) {
    (void)srcfd;
    (void)dst_dirfd;
    (void)dst;
    (void)flags;
    errno = ENOTSUP;
    return -1;
}

// CommonCrypto iOS 8+: số ngẫu nhiên cho HashMap của Rust, rustls… — arc4random_buf có từ iOS 4.3.
int32_t CCRandomGenerateBytes(void *bytes, size_t count) {
    arc4random_buf(bytes, count);
    return 0;  // kCCSuccess
}

// iOS 6+: dirfd là hàm của libSystem; iOS 5 chỉ có macro trong <dirent.h> (đọc thẳng trường __dd_fd của DIR — cấu trúc DIR
// giống nhau trên iOS 5 / 6) → std::fs của Rust gọi hàm dirfd thì dyld iOS 5 không tìm thấy.
#undef dirfd
int dirfd(DIR *dirp) {
    if (!dirp) {
        errno = EINVAL;
        return -1;
    }
    return dirp->__dd_fd;
}

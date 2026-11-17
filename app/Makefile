# Roza cho iOS 5 / 6 (iPhone / iPad đã jailbreak) — Theos trên Linux, SDK 9.3, armv7 (chạy được A4 trở lên).
#   make package                    bản thử (-DDEBUG)
#   make package FINALPACKAGE=1     bản phát hành
# Cần lõi Rust đã dựng: tools/build-app.sh (hoặc cargo-ios6.sh build --release -p rz-ffi) → CORE_LIB_DIR/librz_ffi.a
TARGET := iphone:clang:9.3:5.0
ARCHS = armv7
INSTALL_TARGET_PROCESSES = Roza

# dpkg của iOS 5 / 6 chỉ đọc .deb nén gzip; nhân iOS 5 / 6 chỉ hiểu chữ ký SHA-1
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
# aps-environment: để đăng ký thông báo với iOS (registerForRemoteNotificationTypes) — iOS 5 / 6 chỉ hiện thông báo cục bộ
# của app đã đăng ký. Không dùng push của Apple.
TARGET_CODESIGN_FLAGS = -Sentitlements.plist -Hsha1

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Roza
Roza_FILES = main.m $(wildcard Core/*.m) Core/RZShims.c $(wildcard UI/*.m)
ifneq ($(FINALPACKAGE),1)
Roza_FILES += $(wildcard Debug/*.m)
endif
Roza_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore ImageIO CFNetwork Security AVFoundation CoreMedia CoreVideo MediaPlayer QuickLook AudioToolbox AssetsLibrary
# API mới hơn iOS 5.0 dùng thẳng là lỗi lúc dựng (TubeMini D24) — chỗ cần iOS 6 thì hỏi lúc chạy (NSClassFromString…)
Roza_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Werror=unguarded-availability -Werror=partial-availability -ICore -IUI -IDebug
# Lõi do tools/build-app.sh dựng ở <thư mục chứa repo>/target-ios (cạnh repo)
CORE_LIB_DIR ?= $(abspath $(CURDIR)/../../target-ios/armv7-apple-ios6/release)
Roza_LDFLAGS = -L$(CORE_LIB_DIR) -lrz_ffi -Wl,-dead_strip

include $(THEOS_MAKE_PATH)/application.mk

# postinst cần quyền chạy (tệp chép từ Windows không giữ bit x)
before-package::
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst

# Tweak SpringBoard đi kèm: cho Roza (app ở /Applications) có mục «Thông báo» của iOS 5 / 6 — như GramMini D18
SUBPROJECTS += ../tweak/RZNotify
include $(THEOS_MAKE_PATH)/aggregate.mk

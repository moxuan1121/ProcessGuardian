THEOS_PACKAGE_SCHEME ?= rootless
ARCHS = arm64
TARGET := iphone:clang:latest:15.0

# 探针装进 SpringBoard；Theos 据此自动生成 dylib 的 Filter plist。
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# ============================================================ 1. 前台切换探针
TWEAK_NAME = ProcessGuardian ProcessGuardianStay

ProcessGuardian_FILES = Sources/Tweak.x Sources/MCCPUGuard.m Sources/MCCommon.m
ProcessGuardian_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/Sources/libproc
ProcessGuardian_FRAMEWORKS = Foundation UIKit
ProcessGuardian_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

ProcessGuardianStay_FILES = Sources/stay/Tweak.x Sources/stay/SALiteConfig.m Sources/stay/SALiteStayAliveManager.m
ProcessGuardianStay_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
ProcessGuardianStay_FRAMEWORKS = UIKit Foundation SystemConfiguration
ProcessGuardianStay_LIBRARIES = substrate

# ====================================================== 2. root 守护进程（全部特权工作）
TOOL_NAME = processguardiand

processguardiand_FILES = Sources/daemon/main.m Sources/MCCommon.m
processguardiand_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/Sources/libproc
processguardiand_FRAMEWORKS = Foundation
# Theos 默认把 tool 装到 /usr/bin，LaunchDaemon 里的 Program 路径与此对应。
processguardiand_CODESIGN_FLAGS = -CSources/daemon/memorycontrold.entitlements

# ============================================================ 3. 偏好面板 bundle
BUNDLE_NAME = ProcessGuardianPrefs

ProcessGuardianPrefs_FILES = \
	Sources/prefs/MCPrefs.m \
	Sources/prefs/MCAppProcessCell.m \
	Sources/prefs/ProcessGuardianPrefsListController.m \
	Sources/prefs/MCProcessListViewController.m \
	Sources/prefs/MCAppListViewController.m \
	Sources/prefs/MCProcessEditViewController.m \
	Sources/prefs/MCLogViewController.m \
	Sources/MCCommon.m

ProcessGuardianPrefs_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/Sources/libproc -Wno-deprecated-declarations
ProcessGuardianPrefs_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
ProcessGuardianPrefs_INFO_PLIST = packaging/PrefsInfo.plist
ProcessGuardianPrefs_RESOURCE_FILES = Sources/prefs/Root.plist Sources/prefs/icon.png
ProcessGuardianPrefs_INSTALL_PATH = /Library/PreferenceBundles
# PSPrefCell / PSListController 等符号只存在于 Preferences.app 内，编译期拿不到
# 对应库，必须让链接器放过它们，运行时再由进程自身解析。
ProcessGuardianPrefs_LFLAGS = -undefined dynamic_lookup

include $(THEOS)/makefiles/tweak.mk
include $(THEOS)/makefiles/tool.mk
include $(THEOS)/makefiles/bundle.mk

# Theos 的 bundle 目标不会自动跑 respring；探针改了要重启 SpringBoard 才加载。
after-install::
	install.exec "killall -9 SpringBoard 2>/dev/null || true"

include $(THEOS)/makefiles/package.mk

# LaunchDaemon 的 Program / plist 路径要跟随越狱前缀：rootless 是 /var/jb，rootful 为空。
# 写死任何一边都会让另一种越狱起不来，所以留到打包时再展开。
before-package::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/LaunchDaemons
	@sed 's|@PREFIX@|$(THEOS_PACKAGE_INSTALL_PREFIX)|g' \
		packaging/com.replay.memorycontrold.plist.in \
		> $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.moxuan.processguardiand.plist
	@chmod 755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/prerm 2>/dev/null || true

#!/usr/bin/env python3
"""Generate RECLAIM.xcodeproj from the source tree.

Written as a generator rather than a hand-maintained pbxproj so the project file
stays reproducible: add a .swift file anywhere under RECLAIM/ and re-run this.

Produces three targets — the app, a unit-test bundle and a UI-test bundle — plus
one shared scheme so `xcodebuild -scheme RECLAIM` works without opening the IDE.

Usage:  python3 Scripts/generate_xcodeproj.py
"""

import hashlib
import os
import shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
PROJECT_NAME = "RECLAIM"
# Reverse-DNS on a name you control. A generic id like "com.reclaim.app" is
# likely already registered to someone else on Apple's servers, which fails
# automatic signing with a confusing error at install time rather than build
# time. The test bundles derive from this (".tests", ".uitests").
BUNDLE_ID = "com.ronitladkat.reclaim"
DEPLOYMENT_TARGET = "17.0"
SWIFT_VERSION = "5.0"

APP_DIR = "RECLAIM"
TEST_DIR = "RECLAIMTests"
UITEST_DIR = "RECLAIMUITests"

# --------------------------------------------------------------------------
# Deterministic 96-bit identifiers
# --------------------------------------------------------------------------

_by_key = {}     # key -> id   (memoised, so uid() is idempotent)
_used = set()    # id  -> taken (guards against distinct keys colliding)


def uid(*parts):
    """Stable 24-char uppercase hex id derived from the given key parts.

    Must be idempotent: the same key is looked up repeatedly (a build
    configuration is emitted once, then referenced again from its
    XCConfigurationList), and returning a fresh id on the second call would
    produce dangling references that stop Xcode opening the project.
    """
    key = "::".join(str(p) for p in parts)
    if key in _by_key:
        return _by_key[key]

    digest = hashlib.md5(key.encode("utf-8")).hexdigest().upper()[:24]
    # Collisions are vanishingly unlikely but would corrupt the project silently.
    salt = 0
    while digest in _used:
        salt += 1
        digest = hashlib.md5(("%s#%d" % (key, salt)).encode()).hexdigest().upper()[:24]
    _used.add(digest)
    _by_key[key] = digest
    return digest


# --------------------------------------------------------------------------
# Source discovery
# --------------------------------------------------------------------------

SKIP_DIRS = {".git", "build", "DerivedData", ".swiftpm", "xcuserdata"}


def collect(base):
    """Walk `base`, returning (swift_sources, resource_bundles, directory_tree)."""
    sources, resources = [], []
    tree = {}

    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, base)):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS
                             and not d.endswith(".xcassets"))
        rel_dir = os.path.relpath(dirpath, ROOT)

        for name in sorted(os.listdir(dirpath)):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT)
            if name.endswith(".xcassets"):
                resources.append(rel)
                tree.setdefault(rel_dir, []).append(rel)
            elif name.endswith(".swift"):
                sources.append(rel)
                tree.setdefault(rel_dir, []).append(rel)
    return sources, resources, tree


# --------------------------------------------------------------------------
# Group tree
# --------------------------------------------------------------------------

class Group:
    def __init__(self, name, path=None):
        self.name = name
        self.path = path
        self.children = []      # Group instances
        self.files = []         # relative file paths
        self.id = uid("group", name, path or "")


def build_group_tree(base):
    """Mirror the on-disk folder layout as Xcode groups."""
    root = Group(base, base)
    index = {base: root}

    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, base)):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS
                             and not d.endswith(".xcassets"))
        rel_dir = os.path.relpath(dirpath, ROOT)

        if rel_dir not in index:
            parent_rel = os.path.dirname(rel_dir)
            parent = index.get(parent_rel)
            if parent is None:
                continue
            group = Group(os.path.basename(rel_dir), os.path.basename(rel_dir))
            parent.children.append(group)
            index[rel_dir] = group

        group = index[rel_dir]
        for name in sorted(os.listdir(dirpath)):
            if name.endswith(".swift") or name.endswith(".xcassets"):
                group.files.append(os.path.join(rel_dir, name))
    return root


# --------------------------------------------------------------------------
# Emission
# --------------------------------------------------------------------------

class Project:
    def __init__(self):
        self.lines = []
        self.file_refs = {}     # rel path -> id
        self.build_files = {}   # (rel path, target) -> id

    def file_ref(self, rel):
        if rel not in self.file_refs:
            self.file_refs[rel] = uid("fileref", rel)
        return self.file_refs[rel]

    def build_file(self, rel, target):
        key = (rel, target)
        if key not in self.build_files:
            self.build_files[key] = uid("buildfile", rel, target)
        return self.build_files[key]


def file_type(rel):
    if rel.endswith(".swift"):
        return "sourcecode.swift"
    if rel.endswith(".xcassets"):
        return "folder.assetcatalog"
    return "text"


def emit_group(group, out, indent="\t\t\t"):
    children = [c.id for c in group.children]
    children += [proj.file_ref(f) for f in group.files]
    out.append("\t\t%s /* %s */ = {" % (group.id, group.name))
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    for child in children:
        out.append("\t\t\t\t%s," % child)
    out.append("\t\t\t);")
    if group.path:
        out.append("\t\t\tpath = %s;" % group.path)
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    for child in group.children:
        emit_group(child, out, indent)


def settings_block(pairs, indent="\t\t\t\t"):
    out = []
    for key, value in pairs:
        if isinstance(value, list):
            out.append("%s%s = (" % (indent, key))
            for item in value:
                out.append("%s\t%s," % (indent, item))
            out.append("%s);" % indent)
        else:
            out.append("%s%s = %s;" % (indent, key, value))
    return out


# --------------------------------------------------------------------------

proj = Project()


def main():
    app_sources, app_resources, _ = collect(APP_DIR)
    test_sources, _, _ = collect(TEST_DIR)
    uitest_sources, _, _ = collect(UITEST_DIR)

    app_group = build_group_tree(APP_DIR)
    test_group = build_group_tree(TEST_DIR)
    uitest_group = build_group_tree(UITEST_DIR)

    # --- Stable object ids ---
    project_id = uid("project")
    main_group_id = uid("maingroup")
    products_group_id = uid("products")

    app_target = uid("target", "app")
    test_target = uid("target", "tests")
    uitest_target = uid("target", "uitests")

    app_product = uid("product", "app")
    test_product = uid("product", "tests")
    uitest_product = uid("product", "uitests")

    out = []
    out.append("// !$*UTF8*$!")
    out.append("{")
    out.append("\tarchiveVersion = 1;")
    out.append("\tclasses = {")
    out.append("\t};")
    out.append("\tobjectVersion = 56;")
    out.append("\tobjects = {")

    # ---------------- PBXBuildFile ----------------
    out.append("\n/* Begin PBXBuildFile section */")
    for rel in app_sources:
        out.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (proj.build_file(rel, "app"), os.path.basename(rel),
                      proj.file_ref(rel), os.path.basename(rel)))
    for rel in app_resources:
        out.append("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (proj.build_file(rel, "app-res"), os.path.basename(rel),
                      proj.file_ref(rel), os.path.basename(rel)))
    for rel in test_sources:
        out.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (proj.build_file(rel, "tests"), os.path.basename(rel),
                      proj.file_ref(rel), os.path.basename(rel)))
    for rel in uitest_sources:
        out.append("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
                   % (proj.build_file(rel, "uitests"), os.path.basename(rel),
                      proj.file_ref(rel), os.path.basename(rel)))
    out.append("/* End PBXBuildFile section */")

    # ---------------- PBXContainerItemProxy ----------------
    test_proxy = uid("proxy", "tests")
    uitest_proxy = uid("proxy", "uitests")
    out.append("\n/* Begin PBXContainerItemProxy section */")
    for proxy_id, name in ((test_proxy, "tests"), (uitest_proxy, "uitests")):
        out.append("\t\t%s /* PBXContainerItemProxy */ = {" % proxy_id)
        out.append("\t\t\tisa = PBXContainerItemProxy;")
        out.append("\t\t\tcontainerPortal = %s /* Project object */;" % project_id)
        out.append("\t\t\tproxyType = 1;")
        out.append("\t\t\tremoteGlobalIDString = %s;" % app_target)
        out.append("\t\t\tremoteInfo = %s;" % PROJECT_NAME)
        out.append("\t\t};")
    out.append("/* End PBXContainerItemProxy section */")

    # ---------------- PBXFileReference ----------------
    out.append("\n/* Begin PBXFileReference section */")
    for rel in sorted(set(app_sources + app_resources + test_sources + uitest_sources)):
        out.append(
            "\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = \"<group>\"; };"
            % (proj.file_ref(rel), os.path.basename(rel), file_type(rel), os.path.basename(rel)))
    out.append("\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };"
               % (app_product, PROJECT_NAME, PROJECT_NAME))
    out.append("\t\t%s /* %sTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = %sTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };"
               % (test_product, PROJECT_NAME, PROJECT_NAME))
    out.append("\t\t%s /* %sUITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = %sUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };"
               % (uitest_product, PROJECT_NAME, PROJECT_NAME))
    out.append("/* End PBXFileReference section */")

    # ---------------- PBXFrameworksBuildPhase ----------------
    app_frameworks = uid("frameworks", "app")
    test_frameworks = uid("frameworks", "tests")
    uitest_frameworks = uid("frameworks", "uitests")
    out.append("\n/* Begin PBXFrameworksBuildPhase section */")
    for phase_id in (app_frameworks, test_frameworks, uitest_frameworks):
        out.append("\t\t%s /* Frameworks */ = {" % phase_id)
        out.append("\t\t\tisa = PBXFrameworksBuildPhase;")
        out.append("\t\t\tbuildActionMask = 2147483647;")
        out.append("\t\t\tfiles = (")
        out.append("\t\t\t);")
        out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        out.append("\t\t};")
    out.append("/* End PBXFrameworksBuildPhase section */")

    # ---------------- PBXGroup ----------------
    out.append("\n/* Begin PBXGroup section */")
    out.append("\t\t%s = {" % main_group_id)
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append("\t\t\t\t%s," % app_group.id)
    out.append("\t\t\t\t%s," % test_group.id)
    out.append("\t\t\t\t%s," % uitest_group.id)
    out.append("\t\t\t\t%s," % products_group_id)
    out.append("\t\t\t);")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    out.append("\t\t%s /* Products */ = {" % products_group_id)
    out.append("\t\t\tisa = PBXGroup;")
    out.append("\t\t\tchildren = (")
    out.append("\t\t\t\t%s," % app_product)
    out.append("\t\t\t\t%s," % test_product)
    out.append("\t\t\t\t%s," % uitest_product)
    out.append("\t\t\t);")
    out.append("\t\t\tname = Products;")
    out.append("\t\t\tsourceTree = \"<group>\";")
    out.append("\t\t};")
    for group in (app_group, test_group, uitest_group):
        emit_group(group, out)
    out.append("/* End PBXGroup section */")

    # ---------------- PBXNativeTarget ----------------
    app_sources_phase = uid("sourcesphase", "app")
    test_sources_phase = uid("sourcesphase", "tests")
    uitest_sources_phase = uid("sourcesphase", "uitests")
    app_resources_phase = uid("resourcesphase", "app")

    app_config_list = uid("configlist", "app")
    test_config_list = uid("configlist", "tests")
    uitest_config_list = uid("configlist", "uitests")
    project_config_list = uid("configlist", "project")

    test_dep = uid("dependency", "tests")
    uitest_dep = uid("dependency", "uitests")

    out.append("\n/* Begin PBXNativeTarget section */")

    def native_target(target_id, name, config_list, phases, deps, product_ref,
                      product_name, product_type):
        out.append("\t\t%s /* %s */ = {" % (target_id, name))
        out.append("\t\t\tisa = PBXNativeTarget;")
        out.append("\t\t\tbuildConfigurationList = %s;" % config_list)
        out.append("\t\t\tbuildPhases = (")
        for phase in phases:
            out.append("\t\t\t\t%s," % phase)
        out.append("\t\t\t);")
        out.append("\t\t\tbuildRules = (")
        out.append("\t\t\t);")
        out.append("\t\t\tdependencies = (")
        for dep in deps:
            out.append("\t\t\t\t%s," % dep)
        out.append("\t\t\t);")
        out.append("\t\t\tname = %s;" % name)
        out.append("\t\t\tproductName = %s;" % name)
        out.append("\t\t\tproductReference = %s;" % product_ref)
        out.append("\t\t\tproductType = \"%s\";" % product_type)
        out.append("\t\t};")

    native_target(app_target, PROJECT_NAME, app_config_list,
                  [app_sources_phase, app_frameworks, app_resources_phase], [],
                  app_product, PROJECT_NAME, "com.apple.product-type.application")
    native_target(test_target, PROJECT_NAME + "Tests", test_config_list,
                  [test_sources_phase, test_frameworks], [test_dep],
                  test_product, PROJECT_NAME + "Tests",
                  "com.apple.product-type.bundle.unit-test")
    native_target(uitest_target, PROJECT_NAME + "UITests", uitest_config_list,
                  [uitest_sources_phase, uitest_frameworks], [uitest_dep],
                  uitest_product, PROJECT_NAME + "UITests",
                  "com.apple.product-type.bundle.ui-testing")
    out.append("/* End PBXNativeTarget section */")

    # ---------------- PBXProject ----------------
    out.append("\n/* Begin PBXProject section */")
    out.append("\t\t%s /* Project object */ = {" % project_id)
    out.append("\t\t\tisa = PBXProject;")
    out.append("\t\t\tattributes = {")
    out.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    out.append("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    out.append("\t\t\t\tLastUpgradeCheck = 1600;")
    out.append("\t\t\t\tTargetAttributes = {")
    out.append("\t\t\t\t\t%s = {" % test_target)
    out.append("\t\t\t\t\t\tTestTargetID = %s;" % app_target)
    out.append("\t\t\t\t\t};")
    out.append("\t\t\t\t\t%s = {" % uitest_target)
    out.append("\t\t\t\t\t\tTestTargetID = %s;" % app_target)
    out.append("\t\t\t\t\t};")
    out.append("\t\t\t\t};")
    out.append("\t\t\t};")
    out.append("\t\t\tbuildConfigurationList = %s;" % project_config_list)
    out.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    out.append("\t\t\tdevelopmentRegion = en;")
    out.append("\t\t\thasScannedForEncodings = 0;")
    out.append("\t\t\tknownRegions = (")
    out.append("\t\t\t\ten,")
    out.append("\t\t\t\tBase,")
    out.append("\t\t\t);")
    out.append("\t\t\tmainGroup = %s;" % main_group_id)
    out.append("\t\t\tproductRefGroup = %s /* Products */;" % products_group_id)
    out.append("\t\t\tprojectDirPath = \"\";")
    out.append("\t\t\tprojectRoot = \"\";")
    out.append("\t\t\ttargets = (")
    out.append("\t\t\t\t%s," % app_target)
    out.append("\t\t\t\t%s," % test_target)
    out.append("\t\t\t\t%s," % uitest_target)
    out.append("\t\t\t);")
    out.append("\t\t};")
    out.append("/* End PBXProject section */")

    # ---------------- PBXResourcesBuildPhase ----------------
    out.append("\n/* Begin PBXResourcesBuildPhase section */")
    out.append("\t\t%s /* Resources */ = {" % app_resources_phase)
    out.append("\t\t\tisa = PBXResourcesBuildPhase;")
    out.append("\t\t\tbuildActionMask = 2147483647;")
    out.append("\t\t\tfiles = (")
    for rel in app_resources:
        out.append("\t\t\t\t%s /* %s in Resources */," %
                   (proj.build_file(rel, "app-res"), os.path.basename(rel)))
    out.append("\t\t\t);")
    out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    out.append("\t\t};")
    out.append("/* End PBXResourcesBuildPhase section */")

    # ---------------- PBXSourcesBuildPhase ----------------
    out.append("\n/* Begin PBXSourcesBuildPhase section */")
    for phase_id, files, tag in ((app_sources_phase, app_sources, "app"),
                                 (test_sources_phase, test_sources, "tests"),
                                 (uitest_sources_phase, uitest_sources, "uitests")):
        out.append("\t\t%s /* Sources */ = {" % phase_id)
        out.append("\t\t\tisa = PBXSourcesBuildPhase;")
        out.append("\t\t\tbuildActionMask = 2147483647;")
        out.append("\t\t\tfiles = (")
        for rel in files:
            out.append("\t\t\t\t%s /* %s in Sources */," %
                       (proj.build_file(rel, tag), os.path.basename(rel)))
        out.append("\t\t\t);")
        out.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        out.append("\t\t};")
    out.append("/* End PBXSourcesBuildPhase section */")

    # ---------------- PBXTargetDependency ----------------
    out.append("\n/* Begin PBXTargetDependency section */")
    for dep_id, proxy_id in ((test_dep, test_proxy), (uitest_dep, uitest_proxy)):
        out.append("\t\t%s /* PBXTargetDependency */ = {" % dep_id)
        out.append("\t\t\tisa = PBXTargetDependency;")
        out.append("\t\t\ttarget = %s /* %s */;" % (app_target, PROJECT_NAME))
        out.append("\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;" % proxy_id)
        out.append("\t\t};")
    out.append("/* End PBXTargetDependency section */")

    # ---------------- XCBuildConfiguration ----------------
    common_project = [
        ("ALWAYS_SEARCH_USER_PATHS", "NO"),
        ("ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS", "YES"),
        ("CLANG_ANALYZER_NONNULL", "YES"),
        ("CLANG_ENABLE_MODULES", "YES"),
        ("CLANG_ENABLE_OBJC_ARC", "YES"),
        ("CLANG_WARN_BOOL_CONVERSION", "YES"),
        ("CLANG_WARN_DOCUMENTATION_COMMENTS", "YES"),
        ("CLANG_WARN_EMPTY_BODY", "YES"),
        ("CLANG_WARN_UNREACHABLE_CODE", "YES"),
        ("COPY_PHASE_STRIP", "NO"),
        ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
        ("ENABLE_USER_SCRIPT_SANDBOXING", "YES"),
        ("GCC_NO_COMMON_BLOCKS", "YES"),
        ("GCC_WARN_UNDECLARED_SELECTOR", "YES"),
        ("GCC_WARN_UNUSED_FUNCTION", "YES"),
        ("GCC_WARN_UNUSED_VARIABLE", "YES"),
        ("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET),
        ("LOCALIZATION_PREFERS_STRING_CATALOGS", "YES"),
        ("SDKROOT", "iphoneos"),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        ("SWIFT_VERSION", SWIFT_VERSION),
    ]
    debug_project = common_project + [
        ("DEBUG_INFORMATION_FORMAT", "dwarf"),
        ("ENABLE_TESTABILITY", "YES"),
        ("GCC_DYNAMIC_NO_PIC", "NO"),
        ("GCC_OPTIMIZATION_LEVEL", "0"),
        ("GCC_PREPROCESSOR_DEFINITIONS", ["\"DEBUG=1\"", "\"$(inherited)\""]),
        ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
        ("ONLY_ACTIVE_ARCH", "YES"),
        ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "\"DEBUG $(inherited)\""),
        ("SWIFT_OPTIMIZATION_LEVEL", "\"-Onone\""),
    ]
    release_project = common_project + [
        ("DEBUG_INFORMATION_FORMAT", "\"dwarf-with-dsym\""),
        ("ENABLE_NS_ASSERTIONS", "NO"),
        ("MTL_ENABLE_DEBUG_INFO", "NO"),
        ("SWIFT_COMPILATION_MODE", "wholemodule"),
        ("VALIDATE_PRODUCT", "YES"),
    ]

    # Permission strings are declared here and generated into Info.plist at
    # build time. Only the three the app genuinely needs are requested.
    photo_usage = ("\"We scan the photos on this iPhone to find duplicates, "
                   "screenshots and large videos so you can free up space. Your "
                   "photos never leave your device.\"")
    contacts_usage = ("\"We scan the contacts on this iPhone to identify likely "
                      "duplicates so you can tidy them up. Your contacts never "
                      "leave your device.\"")

    app_common = [
        ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
        ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "Accent"),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("DEVELOPMENT_ASSET_PATHS", "\"\""),
        ("ENABLE_PREVIEWS", "YES"),
        ("GENERATE_INFOPLIST_FILE", "YES"),
        ("INFOPLIST_KEY_CFBundleDisplayName", "RECLAIM"),
        ("INFOPLIST_KEY_NSContactsUsageDescription", contacts_usage),
        ("INFOPLIST_KEY_NSPhotoLibraryUsageDescription", photo_usage),
        ("INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents", "YES"),
        ("INFOPLIST_KEY_UILaunchScreen_Generation", "YES"),
        ("INFOPLIST_KEY_UIStatusBarStyle", "UIStatusBarStyleDefault"),
        ("INFOPLIST_KEY_UISupportedInterfaceOrientations",
         "\"UIInterfaceOrientationPortrait\""),
        ("LD_RUNPATH_SEARCH_PATHS", ["\"$(inherited)\"", "\"@executable_path/Frameworks\""]),
        ("MARKETING_VERSION", "1.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID),
        ("PRODUCT_NAME", "\"$(TARGET_NAME)\""),
        ("SWIFT_EMIT_LOC_STRINGS", "YES"),
        # iPhone-only: iPad, Mac and Watch are out of scope.
        ("TARGETED_DEVICE_FAMILY", "1"),
    ]

    test_common = [
        ("BUNDLE_LOADER", "\"$(TEST_HOST)\""),
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("GENERATE_INFOPLIST_FILE", "YES"),
        ("MARKETING_VERSION", "1.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID + ".tests"),
        ("PRODUCT_NAME", "\"$(TARGET_NAME)\""),
        ("SWIFT_EMIT_LOC_STRINGS", "NO"),
        ("TARGETED_DEVICE_FAMILY", "1"),
        ("TEST_HOST",
         "\"$(BUILT_PRODUCTS_DIR)/%s.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/%s\""
         % (PROJECT_NAME, PROJECT_NAME)),
    ]

    uitest_common = [
        ("CODE_SIGN_STYLE", "Automatic"),
        ("CURRENT_PROJECT_VERSION", "1"),
        ("GENERATE_INFOPLIST_FILE", "YES"),
        ("MARKETING_VERSION", "1.0"),
        ("PRODUCT_BUNDLE_IDENTIFIER", BUNDLE_ID + ".uitests"),
        ("PRODUCT_NAME", "\"$(TARGET_NAME)\""),
        ("SWIFT_EMIT_LOC_STRINGS", "NO"),
        ("TARGETED_DEVICE_FAMILY", "1"),
        ("TEST_TARGET_NAME", PROJECT_NAME),
    ]

    configs = [
        (uid("config", "project", "Debug"), "Debug", debug_project),
        (uid("config", "project", "Release"), "Release", release_project),
        (uid("config", "app", "Debug"), "Debug", app_common),
        (uid("config", "app", "Release"), "Release", app_common),
        (uid("config", "tests", "Debug"), "Debug", test_common),
        (uid("config", "tests", "Release"), "Release", test_common),
        (uid("config", "uitests", "Debug"), "Debug", uitest_common),
        (uid("config", "uitests", "Release"), "Release", uitest_common),
    ]

    out.append("\n/* Begin XCBuildConfiguration section */")
    for config_id, name, pairs in configs:
        out.append("\t\t%s /* %s */ = {" % (config_id, name))
        out.append("\t\t\tisa = XCBuildConfiguration;")
        out.append("\t\t\tbuildSettings = {")
        out.extend(settings_block(sorted(pairs)))
        out.append("\t\t\t};")
        out.append("\t\t\tname = %s;" % name)
        out.append("\t\t};")
    out.append("/* End XCBuildConfiguration section */")

    # ---------------- XCConfigurationList ----------------
    out.append("\n/* Begin XCConfigurationList section */")
    for list_id, tag in ((project_config_list, "project"), (app_config_list, "app"),
                         (test_config_list, "tests"), (uitest_config_list, "uitests")):
        out.append("\t\t%s = {" % list_id)
        out.append("\t\t\tisa = XCConfigurationList;")
        out.append("\t\t\tbuildConfigurations = (")
        out.append("\t\t\t\t%s /* Debug */," % uid("config", tag, "Debug"))
        out.append("\t\t\t\t%s /* Release */," % uid("config", tag, "Release"))
        out.append("\t\t\t);")
        out.append("\t\t\tdefaultConfigurationIsVisible = 0;")
        out.append("\t\t\tdefaultConfigurationName = Release;")
        out.append("\t\t};")
    out.append("/* End XCConfigurationList section */")

    out.append("\t};")
    out.append("\trootObject = %s /* Project object */;" % project_id)
    out.append("}")

    # --- Write it out ---
    proj_dir = os.path.join(ROOT, "%s.xcodeproj" % PROJECT_NAME)
    if os.path.isdir(proj_dir):
        shutil.rmtree(proj_dir)
    os.makedirs(proj_dir)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as fh:
        fh.write("\n".join(out) + "\n")

    write_scheme(proj_dir, app_target, test_target, uitest_target,
                 app_product, test_product, uitest_product)

    print("Generated %s.xcodeproj" % PROJECT_NAME)
    print("  app target:      %d Swift files" % len(app_sources))
    print("  unit tests:      %d Swift files" % len(test_sources))
    print("  UI tests:        %d Swift files" % len(uitest_sources))
    print("  resources:       %s" % ", ".join(os.path.basename(r) for r in app_resources))


def write_scheme(proj_dir, app_target, test_target, uitest_target,
                 app_product, test_product, uitest_product):
    """A shared scheme so `xcodebuild -scheme RECLAIM` works out of the box."""
    scheme_dir = os.path.join(proj_dir, "xcshareddata", "xcschemes")
    os.makedirs(scheme_dir, exist_ok=True)

    def ref(blueprint, name, product):
        return (
            '<BuildableReference BuildableIdentifier="primary" '
            'BlueprintIdentifier="%s" BuildableName="%s" BlueprintName="%s" '
            'ReferencedContainer="container:%s.xcodeproj"></BuildableReference>'
            % (blueprint, product, name, PROJECT_NAME)
        )

    xml = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            {app_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
         <TestableReference skipped="NO">
            {test_ref}
         </TestableReference>
         <TestableReference skipped="NO">
            {uitest_ref}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         {app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         {app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>
""".format(
        app_ref=ref(app_target, PROJECT_NAME, PROJECT_NAME + ".app"),
        test_ref=ref(test_target, PROJECT_NAME + "Tests", PROJECT_NAME + "Tests.xctest"),
        uitest_ref=ref(uitest_target, PROJECT_NAME + "UITests", PROJECT_NAME + "UITests.xctest"),
    )
    with open(os.path.join(scheme_dir, "%s.xcscheme" % PROJECT_NAME), "w") as fh:
        fh.write(xml)


if __name__ == "__main__":
    main()
